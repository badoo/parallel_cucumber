require 'English'
require 'timeout'
require 'tmpdir' # I loathe Ruby.

module ParallelCucumber
  class Worker
    include ParallelCucumber::Helper::Utils

    def initialize(options:, index:, stdout_logger:, manager:)
      @group_by = options[:group_by]
      @batch_timeout = options[:batch_timeout]
      @batch_error_timeout = options[:batch_error_timeout]
      @precheck_timeout = options[:precheck_timeout]
      @setup_timeout = options[:setup_timeout]
      @cucumber_options = options[:cucumber_options]
      @test_command = options[:test_command]
      @pre_check = options[:pre_check]
      @index = index
      @name = "W#{@index}"
      @setup_worker = options[:setup_worker]
      @teardown_worker = options[:teardown_worker]
      @worker_delay = options[:worker_delay]
      @debug = options[:debug]
      @log_decoration = options[:log_decoration]
      @log_dir = options[:log_dir]
      @log_file = "#{@log_dir}/worker_#{index}.log"
      @stdout_logger = stdout_logger # .sync writes only.
      @is_busy_running_test = false
      @jobs_queue = Queue.new
      @manager = manager
    end

    attr_reader :index

    def assign_job(instruction)
      @jobs_queue.enq(instruction)
    end

    def busy_running_test?
      @is_busy_running_test && @current_thread.alive?
    end

    def autoshutting_file
      file_handle = { log_file: @log_file }

      def file_handle.write(message)
        File.open(self[:log_file], 'a') { |f| f << message }
      rescue => e
        STDERR.puts "Log failure: #{e} writing '#{message.to_s.chomp}' to #{self[:log_file]}"
      end

      def file_handle.close
      end

      def file_handle.fsync
      end

      def file_handle.path
        self[:log_file]
      end

      file_handle
    end

    def start(env)
      @current_thread = Thread.current
      @manager.inform_idle(@name)

      env = env.dup.merge!('WORKER_LOG' => @log_file)

      File.delete(@log_file) if File.exist?(@log_file)

      @logger = ParallelCucumber::CustomLogger.new(autoshutting_file)
      @logger.progname = "Worker-#{@index}"
      @logger.level = @debug ? ParallelCucumber::CustomLogger::DEBUG : ParallelCucumber::CustomLogger::INFO

      results = {}
      begin
        @logger.info("Logging to #{@log_file}")

        unless @worker_delay.zero?
          @logger.info("Waiting #{@worker_delay * @index} seconds before start")
          sleep(@worker_delay * @index)
        end

        @logger.debug(<<-LOG)
        Additional environment variables: #{env.map { |k, v| "#{k}=#{v}" }.join(' ')}
        LOG
        @logger.update_into(@stdout_logger)

        # TODO: Replace running total with queues for passed, failed, unknown, skipped.
        running_total = Hash.new(0) # Default new keys to 0
        running_total[:group] = env[@group_by] if @group_by
        begin
          setup(env)

          loop_mm, loop_ss = time_it do
            loop do
              job = @jobs_queue.pop(false)
              case job.type
              when Job::PRECHECK
                precmd = precheck(env)
                if (m = precmd.match(/precmd:retry-after-(\d+)-seconds/))
                  @manager.inform_idle(@name)
                  sleep(1 + m[1].to_i)
                  next
                end
                @manager.inform_healthy(@name)
              when Job::RUN_TESTS
                run_batch(env, results, running_total, job.details)
                @manager.inform_idle(@name)
              when Job::DIE
                break
              else
                raise("Invalid job #{job.inspect}")
              end
            end
          end
          @logger.debug("Loop took #{loop_mm} minutes #{loop_ss} seconds")
          @logger.update_into(@stdout_logger)
        rescue StandardError => e
          trace = e.backtrace.join("\n\t").sub("\n\t", ": #{$ERROR_INFO}#{e.class ? " (#{e.class})" : ''}\n\t")
          @logger.error("Threw: #{e.inspect} #{trace}")
        ensure
          results[":worker-#{@index}"] = running_total
          teardown(env)
        end
      ensure
        @logger.update_into(@stdout_logger)
      end
      results
    end

    def run_batch(env, results, running_total, tests)
      @is_busy_running_test = true
      batch_id = "#{Time.now.to_i}-#{@index}"
      @logger.debug("Batch ID is #{batch_id}")

      batch_mm, batch_ss = time_it do
        begin
          Hooks.fire_before_batch_hooks(tests, batch_id, env)
        rescue StandardError => e
          trace = e.backtrace.join("\n\t")
          @logger.warn("There was exception in before_batch hook #{e.message} \n #{trace}")
        end

        batch_results = test_batch(batch_id, env, running_total, tests)
        begin
          Hooks.fire_after_batch_hooks(batch_results, batch_id, env)
        rescue StandardError => e
          trace = e.backtrace.join("\n\t")
          @logger.warn("There was exception in after_batch hook #{e.message} \n #{trace}")
        end
        process_results(batch_results, tests)
        running_totals(batch_results, running_total)
        results.merge!(batch_results)
        @is_busy_running_test = false
      end
    ensure
      @logger.debug("Batch #{batch_id} took #{batch_mm} minutes #{batch_ss} seconds")
      @logger.update_into(@stdout_logger)
    end

    def precheck(env)
      return 'default no-op pre_check' unless @pre_check
      begin
        return Helper::Command.exec_command(
          env, 'precheck', @pre_check, @logger, @log_decoration, timeout: @precheck_timeout, capture: true
        )
      rescue
        @logger.error('Pre-check failed: quitting immediately')
        raise 'Pre-check failed: quitting immediately'
      end
    end

    def running_totals(batch_results, running_total)
      batch_info = Status.constants.map do |status|
        status = Status.const_get(status)
        [status, batch_results.select { |_t, s| s[:status] == status }.keys]
      end.to_h
      batch_info.each do |s, tt|
        @logger.info("#{s.to_s.upcase} #{tt.count} tests: #{tt.join(' ')}") unless tt.empty?
        running_total[s] += tt.count unless tt.empty?
      end
      running_total[:batches] += 1
      @logger.info(running_total.sort.to_s + ' t=' + Time.now.to_s)
    end

    def process_results(batch_results, tests)
      batch_keys = batch_results.keys
      test_syms = tests.map(&:to_sym)
      unrun = test_syms - batch_keys
      surfeit = batch_keys - test_syms
      unrun.each { |test| batch_results[test][:status] = Status::UNKNOWN }
      surfeit.each { |test| batch_results.delete(test) }
      @logger.error("Did not run #{unrun.count}/#{tests.count}: #{unrun.join(' ')}") unless unrun.empty?
      @logger.error("Extraneous runs (#{surfeit.count}): #{surfeit.join(' ')}") unless surfeit.empty?
      return if surfeit.empty?
      # Don't see how this can happen, but...
      @logger.error("Tests/result mismatch: #{tests.count}!=#{batch_results.count}: #{tests}/#{batch_keys}")
    end

    def test_batch(batch_id, env, running_total, tests)
      # Prefer /tmp to Mac's brain-dead /var/folders/y8/8kqjszcs2slchjx2z5lrw2t80000gp/T/w-1497514590-0 nonsense
      prefer_tmp = ENV.fetch('PREFER_TMP', Dir.tmpdir)
      test_batch_dir = "#{Dir.exist?(prefer_tmp) ? prefer_tmp : Dir.tmpdir}/w-#{batch_id}"
      FileUtils.rm_rf(test_batch_dir)
      FileUtils.mkpath(test_batch_dir)

      test_state = "#{test_batch_dir}/test_state.json"
      cmd = "#{@test_command} --format ParallelCucumber::Helper::Cucumber::JsonStatusFormatter --out #{test_state} #{@cucumber_options} "
      batch_env = {
        :TEST_BATCH_ID.to_s => batch_id,
        :TEST_BATCH_DIR.to_s => test_batch_dir,
        :BATCH_NUMBER.to_s => running_total[:batches].to_s
      }.merge(env)
      mapped_batch_cmd, file_map = Helper::Cucumber.batch_mapped_files(cmd, test_batch_dir, batch_env)
      file_map.each { |_user, worker| FileUtils.mkpath(worker) if worker =~ %r{\/$} }
      mapped_batch_cmd += ' ' + tests.join(' ')
      begin
        ParallelCucumber::Helper::Command.exec_command(
          batch_env, 'batch', mapped_batch_cmd, @logger, @log_decoration,
          timeout: @batch_timeout, return_script_error: true
        )
      rescue => e
        @logger << "ERROR #{e} #{e.backtrace.first(5)}"

        begin
          Hooks.fire_on_batch_error(tests: tests, batch_id: batch_id, env: batch_env, exception: e)
        rescue StandardError => exc
          trace = exc.backtrace.join("\n\t")
          @logger.warn("There was exception in on_batch_error hook #{exc.message} \n #{trace}")
        end

        return Helper::Cucumber.unknown_result(tests)
      end
      parse_results(test_state, tests)
    ensure
      Helper::Command.wrap_block(@log_decoration, "file copy #{Time.now}", @logger) do
        # Copy files we might have renamed or moved
        file_map.each do |user, worker|
          next if worker == user
          Helper::Processes.cp_rv(worker, user, @logger)
        end
        @logger << "\nCopied files in map: #{file_map.first(5)}...#{file_map.count}  #{Time.now}\n"
        # Copy everything else too, in case it's interesting.
        Helper::Processes.cp_rv("#{test_batch_dir}/*", @log_dir, @logger)
        @logger << "\nCopied everything else #{Time.now}  #{Time.now}\n"
      end
      @logger.update_into(@stdout_logger)
      FileUtils.rm_rf(test_batch_dir)
      @logger << "\nRemoved all files  #{Time.now}\n" # Tracking down 30 minute pause!
      @logger.update_into(@stdout_logger)
    end

    def teardown(env)
      return unless @teardown_worker
      mm, ss = time_it do
        @logger.info("\nTeardown running at #{Time.now}\n")

        begin
          Helper::Command.exec_command(
            env, 'teardown', @teardown_worker, @logger, @log_decoration, timeout: @setup_timeout
          )
        rescue
          @logger.warn('Teardown finished with error')
        end
      end
    ensure
      @logger.debug("Teardown took #{mm} minutes #{ss} seconds")
      @logger.update_into(@stdout_logger)
    end

    def setup(env)
      return unless @setup_worker
      mm, ss = time_it do
        @logger.info('Setup running')

        begin
          Helper::Command.exec_command(env, 'setup', @setup_worker, @logger, @log_decoration, timeout: @setup_timeout)
        rescue
          @logger.warn("Setup failed: #{@index} quitting immediately")
          raise 'Setup failed: quitting immediately'
        end
      end
    ensure
      @logger.debug("Setup took #{mm} minutes #{ss} seconds")
      @logger.update_into(@stdout_logger)
    end

    def parse_results(f, tests)
      unless File.file?(f)
        @logger.error("Results file does not exist: #{f}")
        return Helper::Cucumber.unknown_result(tests)
      end
      json_report = File.read(f)
      if json_report.empty?
        @logger.error("Results file is empty: #{f}")
        return Helper::Cucumber.unknown_result(tests)
      end
      Helper::Cucumber.parse_json_report(json_report)
    rescue => e
      trace = e.backtrace.join("\n\t").sub("\n\t", ": #{$ERROR_INFO}#{e.class ? " (#{e.class})" : ''}\n\t")
      @logger.error("Threw: JSON parse of results caused #{trace}")
      Helper::Cucumber.unknown_result(tests)
    end
  end
end
