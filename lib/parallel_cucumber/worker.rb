require 'English'
require 'tempfile'
require 'timeout'

module ParallelCucumber
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
      @log_file = "#{options[:log_dir]}/worker_#{index}.log"
    end

    def start(env)
      env = env.dup.merge!('WORKER_LOG' => @log_file)

      File.delete(@log_file) if File.exist?(@log_file)
      file_handle = File.open(@log_file, 'a')
      file_handle.sync = true
      @logger = ParallelCucumber::CustomLogger.new(MultiDelegator.delegate(:write, :close).to(STDOUT, file_handle))
      @logger.progname = "Worker #{@index}"
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
          success = Helper::Command.exec_command(env, @setup_worker, @log_file, @logger, @log_decoration)
          @logger.warn('Setup finished with error') unless success
        end
        @logger.debug("Setup took #{mm} minutes #{ss} seconds")
      end

      results = {}
      queue = ParallelCucumber::Helper::Queue.new(@queue_connection_params)

      loop_mm, loop_ss = time_it do
        loop do
          tests = []
          if @pre_check
            continue = Helper::Command.exec_command(
              env, @pre_check, @log_file, @logger, @log_decoration, @batch_timeout)
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
          tests.sort!
          break if tests.empty?

          batch_id = "#{Time.now.to_i}-#{@index}"
          @logger.debug("Batch ID is #{batch_id}")
          @logger.info("Took #{tests.count} from the queue (#{queue.length} left): #{tests.join(' ')}")

          batch_mm, batch_ss = time_it do
            test_batch_dir = "/tmp/w-#{batch_id}"
            FileUtils.rm_rf(test_batch_dir)
            FileUtils.mkpath(test_batch_dir)
            f = "#{test_batch_dir}/test_state.json"
            cmd = "#{@test_command} --format pretty --format json --out #{f} #{@cucumber_options} "
            batch_env = { :TEST_BATCH_ID.to_s => batch_id, :TEST_BATCH_DIR.to_s => test_batch_dir }.merge(env)
            mapped_batch_cmd, file_map = Helper::Cucumber.batch_mapped_files(cmd, test_batch_dir, batch_env)
            file_map.each { |_user, worker| FileUtils.mkpath(worker) if worker =~ %r{\/$} }
            mapped_batch_cmd += ' ' + tests.join(' ')
            res = ParallelCucumber::Helper::Command.exec_command(
              batch_env, mapped_batch_cmd, @log_file, @logger, @log_decoration, @batch_timeout)
            batch_results = if res.nil?
                              Hash[tests.map { |t| [t, Status::UNKNOWN] }]
                            else
                              # Use system cp -r because Ruby's has crap diagnostics in weird situations.
                              file_map.each do |user, worker|
                                unless worker == user
                                  fail = `cp -r #{worker} #{user} 2>&1`
                                  @logger.error("Copy of #{worker} to #{user} said: #{fail}") unless fail.empty?
                                end
                              end
                              parse_results(f)
                            end
            FileUtils.rm_rf(test_batch_dir)

            batch_info = Status.constants.map do |status|
              status = Status.const_get(status)
              [status, batch_results.select { |_t, s| s == status }.keys]
            end.to_h
            batch_info.each do |s, tt|
              @logger.info("#{s.to_s.upcase} tests (#{tt.count}): #{tt.join(' ')}") unless tt.empty?
            end

            unless tests.count == batch_results.count
              @logger.error(<<-LOG)
                #{tests.count} tests were taken from Queue, but #{batch_results.count} ran:
                #{((tests - batch_results.keys) + (batch_results.keys - tests)).join(', ')}.
              LOG
            end
            results.merge!(batch_results)
          end
          @logger.debug("Batch #{batch_id} took #{batch_mm} minutes #{batch_ss} seconds")
        end
      end
      @logger.debug("Loop took #{loop_mm} minutes #{loop_ss} seconds")

      if @teardown_worker
        mm, ss = time_it do
          @logger.info('Teardown running')
          success = Helper::Command.exec_command(env, @teardown_worker, @log_file, @logger, @log_decoration)
          @logger.warn('Teardown finished with error') unless success
        end
        @logger.debug("Teardown took #{mm} minutes #{ss} seconds")
      end

      results
    end

    def parse_results(f)
      json_report = File.read(f)
      raise 'Results file was empty' if json_report.empty?
      Helper::Cucumber.parse_json_report(json_report)
    rescue => e
      trace = e.backtrace.join("\n\t").sub("\n\t", ": #{$ERROR_INFO}#{e.class ? " (#{e.class})" : ''}\n\t")
      @logger.error("Threw: JSON parse of results caused #{trace}")
      {}
    end
  end
end
