require 'English'
require 'timeout'

module ParallelCucumber
  class Tracker
    def initialize(queue)
      @queue = queue
    end

    def status
      queue_length = @queue.length
      now = Time.now
      @full ||= queue_length
      @start ||= now
      completed = @full - queue_length
      elapsed = now - @start
      estimate = (completed == 0) ? '' : " #{(elapsed * @full / completed).to_i}s est"
      "#{queue_length}/#{@full} left #{elapsed.to_i}s worker#{estimate}"
    end
  end

  class Worker
    include ParallelCucumber::Helper::Utils

    def initialize(options, index)
      @batch_size = options[:batch_size]
      @batch_timeout = options[:batch_timeout]
      @cucumber_options = options[:cucumber_options]
      @test_command = options[:test_command]
      @pre_check = options[:pre_check]
      @env_variables = options[:env_variables]
      @index = index
      @queue_connection_params = options[:queue_connection_params]
      @setup_worker = options[:setup_worker]
      @teardown_worker = options[:teardown_worker]
      @worker_delay = options[:worker_delay]
      @debug = options[:debug]
      @log_decoration = options[:log_decoration]
      @log_dir = options[:log_dir]
      @log_file = "#{@log_dir}/worker_#{index}.log"
    end

    def start(env)
      env = env.dup.merge!('WORKER_LOG' => @log_file)

      File.delete(@log_file) if File.exist?(@log_file)
      File.open(@log_file, 'a') do |file_handle|
        file_handle.sync = true
        @logger = ParallelCucumber::CustomLogger.new(MultiDelegator.delegate(:write, :close).to(STDOUT, file_handle))
        @logger.progname = "Worker-#{@index}"
        @logger.level = @debug ? ParallelCucumber::CustomLogger::DEBUG : ParallelCucumber::CustomLogger::INFO

        @logger.info("Starting, also logging to #{@log_file}")

        unless @worker_delay.zero?
          @logger.info("Waiting #{@worker_delay * @index} seconds before start")
          sleep(@worker_delay * @index)
        end

        @logger.debug(<<-LOG)
        Additional environment variables: #{env.map { |k, v| "#{k}=#{v}" }.join(' ')}
        LOG

        if @setup_worker
          mm, ss = time_it do
            @logger.info('Setup running')
            success = Helper::Command.exec_command(env, 'setup', @setup_worker, @log_file, @logger, @log_decoration)
            @logger.warn('Setup finished with error') unless success
          end
          @logger.debug("Setup took #{mm} minutes #{ss} seconds")
        end

        results = {}
        running_total = Hash.new(0)
        queue = ParallelCucumber::Helper::Queue.new(@queue_connection_params)
        queue_tracker = Tracker.new(queue)

        loop_mm, loop_ss = time_it do
          loop do
            break if queue.empty?
            tests = []
            if @pre_check
              continue = Helper::Command.exec_command(
                env, 'precheck', @pre_check, @log_file, @logger, @log_decoration, @batch_timeout
              )
              unless continue
                @logger.error('Pre-check failed: quitting immediately')
                exit 1
              end
            end
            @batch_size.times do
              # TODO: Handle recovery of dequeued tests, if a worker dies mid-processing.
              tests << queue.dequeue
            end
            tests.compact!
            tests.sort! # Workaround for https://github.com/cucumber/cucumber-ruby/issues/952
            break if tests.empty?

            batch_id = "#{Time.now.to_i}-#{@index}"
            @logger.debug("Batch ID is #{batch_id}")
            @logger.info("Took #{tests.count} from the queue (#{queue_tracker.status}): #{tests.join(' ')}")

            batch_mm, batch_ss = time_it do
              test_batch_dir = "/tmp/w-#{batch_id}"
              FileUtils.rm_rf(test_batch_dir)
              FileUtils.mkpath(test_batch_dir)
              f = "#{test_batch_dir}/test_state.json"
              cmd = "#{@test_command} --format json --out #{f} #{@cucumber_options} "
              batch_env = {
                :TEST_BATCH_ID.to_s => batch_id,
                :TEST_BATCH_DIR.to_s => test_batch_dir,
                :BATCH_NUMBER.to_s => running_total[:batches].to_s
              }.merge(env)
              mapped_batch_cmd, file_map = Helper::Cucumber.batch_mapped_files(cmd, test_batch_dir, batch_env)
              file_map.each { |_user, worker| FileUtils.mkpath(worker) if worker =~ %r{\/$} }
              mapped_batch_cmd += ' ' + tests.join(' ')
              res = ParallelCucumber::Helper::Command.exec_command(
                batch_env, 'batch', mapped_batch_cmd, @log_file, @logger, @log_decoration, @batch_timeout
              )
              batch_results = if res.nil?
                                {}
                              else
                                Helper::Command.wrap_block(@log_decoration, 'file copy', @logger) do
                                  # Use system cp -r because Ruby's has crap diagnostics in weird situations.
                                  # Copy files we might have renamed or moved
                                  file_map.each do |user, worker|
                                    unless worker == user
                                      cp_out = `cp -Rv #{worker} #{user} 2>&1`
                                      @logger.debug("Copy of #{worker} to #{user} said: #{cp_out}")
                                    end
                                  end
                                  # Copy everything else too, in case it's interesting.
                                  cp_out = `cp -Rv #{test_batch_dir}/*  #{@log_dir} 2>&1`
                                  @logger.debug("Copy of #{test_batch_dir}/* to #{@log_dir} said: #{cp_out}")
                                  parse_results(f)
                                end
                              end
              FileUtils.rm_rf(test_batch_dir)
              batch_keys = batch_results.keys
              test_syms = tests.map(&:to_sym)
              unrun = test_syms - batch_keys
              surfeit = batch_keys - test_syms
              unrun.each { |test| batch_results[test] = Status::UNKNOWN }
              surfeit.each { |test| batch_results.delete(test) }
              @logger.error("Did not run #{unrun.count}/#{tests.count}: #{unrun.join(' ')}") unless unrun.empty?
              @logger.error("Extraneous runs (#{surfeit.count}): #{surfeit.join(' ')}") unless surfeit.empty?
              # Don't see how this can happen, but...
              unless surfeit.empty?
                @logger.error("Tests/result mismatch: #{tests.count}!=#{batch_results.count}: #{tests}/#{batch_keys}")
              end

              batch_info = Status.constants.map do |status|
                status = Status.const_get(status)
                [status, batch_results.select { |_t, s| s == status }.keys]
              end.to_h
              batch_info.each do |s, tt|
                @logger.info("#{s.to_s.upcase} #{tt.count} tests: #{tt.join(' ')}") unless tt.empty?
                running_total[s] += tt.count unless tt.empty?
              end
              running_total[:batches] += 1
              @logger.info(running_total.sort.to_s)
              results.merge!(batch_results)
            end
            @logger.debug("Batch #{batch_id} took #{batch_mm} minutes #{batch_ss} seconds")
          end
        end
        @logger.debug("Loop took #{loop_mm} minutes #{loop_ss} seconds")

        if @teardown_worker
          mm, ss = time_it do
            @logger.info('Teardown running')
            success = Helper::Command.exec_command(
              env, 'teardown', @teardown_worker, @log_file, @logger, @log_decoration
            )
            @logger.warn('Teardown finished with error') unless success
          end
          @logger.debug("Teardown took #{mm} minutes #{ss} seconds")
        end
        results[":worker-#{@index}"] = running_total
        results
      end
    end

    def parse_results(f)
      unless File.file?(f)
        @logger.error("Results file does not exist: #{f}")
        return {}
      end
      json_report = File.read(f)
      if json_report.empty?
        @logger.error("Results file is empty: #{f}")
        return {}
      end
      Helper::Cucumber.parse_json_report(json_report)
    rescue => e
      trace = e.backtrace.join("\n\t").sub("\n\t", ": #{$ERROR_INFO}#{e.class ? " (#{e.class})" : ''}\n\t")
      @logger.error("Threw: JSON parse of results caused #{trace}")
      {}
    end
  end
end
