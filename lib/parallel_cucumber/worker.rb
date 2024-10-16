require 'English'
require 'timeout'
require 'tmpdir'
require_relative 'helper/cucumber/cucumber_config_provider'

module ParallelCucumber
  class Worker
    include ParallelCucumber::Helper::Utils

    def initialize(options:, index:, stdout_logger:, manager:)
      @group_by             = options[:group_by]
      @batch_timeout        = options[:batch_timeout]
      @batch_error_timeout  = options[:batch_error_timeout]
      @setup_timeout        = options[:setup_timeout]
      @cucumber_options     = options[:cucumber_options]
      @test_command         = options[:test_command]
      @index                = index
      @name                 = "W#{@index}"
      @setup_worker         = options[:setup_worker]
      @teardown_worker      = options[:teardown_worker]
      @worker_delay         = options[:worker_delay]
      @debug                = options[:debug]
      @log_decoration       = options[:log_decoration]
      @log_dir              = options[:log_dir]
      @log_file             = "#{@log_dir}/worker_#{index}.log"
      @stdout_logger        = stdout_logger # .sync writes only.
      @is_busy_running_test = false
      @jobs_queue           = ::Thread::Queue.new
      @manager              = manager
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

      @logger          = ParallelCucumber::CustomLogger.new(autoshutting_file)
      @logger.progname = "Worker-#{@index}"
      @logger.level    = @debug ? ParallelCucumber::CustomLogger::DEBUG : ParallelCucumber::CustomLogger::INFO

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
        running_total         = Hash.new(0) # Default new keys to 0
        running_total[:group] = env[@group_by] if @group_by
        begin
          setup(env)

          loop_mm, loop_ss = time_it do
            loop do
              job = @jobs_queue.pop(false)
              case job.type
              when Job::PRECHECK
                Hooks.fire_worker_health_check(env)
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

    # @return String for example: "W-123456"
    def generate_batch_id
      "#{@name}-#{Time.now.to_i}"
    end

    def run_batch(env, results, running_total, tests)
      @is_busy_running_test = true
      batch_id              = generate_batch_id
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

    def running_totals(batch_results, running_total)
      batch_info = batch_results.group_by { |_test, result| result[:status] }.transform_values(&:count)

      batch_info.each do |status, test_count|
        if running_total[status].nil?
          running_total[status] = test_count
        else
          running_total[status] += test_count
        end
      end

      running_total[:batches] += 1
      @logger.info("Running totals: #{running_total.sort} at time #{Time.now}")
    end

    # @param [Hash] batch_results dictionary of tests with results. keys are symbols
    # @param [Array] tests_to_execute list of tests to execute, strings
    def process_results(batch_results, tests_to_execute)
      tests_to_execute     = tests_to_execute.map(&:to_sym)
      tests_with_result    = batch_results.keys
      tests_without_result = tests_to_execute - tests_with_result

      unless tests_without_result.empty?
        @logger.error("Don't have test result for #{tests_without_result.count} out of #{tests_to_execute.count}: #{tests_without_result.join(' ')}") # rubocop:disable Layout/LineLength

        # add result 'UNKNOWN' for each test that does not have a result
        tests_without_result.each do |test|
          batch_results[test] = { status: :unknown }
        end
      end

      extraneous_tests_with_result = tests_with_result - tests_to_execute

      unless extraneous_tests_with_result.empty?
        # for some unknown reason extraneous_tests_with_result may be not empty
        @logger.error("Extraneous runs (#{extraneous_tests_with_result.count}): #{extraneous_tests_with_result.join(' ')}") # rubocop:disable Layout/LineLength
      end

      # delete extraneous_tests_with_result from results dictionary batch_results
      extraneous_tests_with_result.each do |test|
        unless batch_results[test].nil?
          batch_results.delete(test)
        end
      end
    end

    # @param [String] batch_id for example: W-123456
    # @param [Hash] env environment for the test batch
    # @param [Hash] running_total
    # @param [Array] tests tests to run
    def test_batch(batch_id, env, running_total, tests)
      @logger.info("Starting tests for #{batch_id} #{tests.join(',')}")
      test_batch_dir = "#{@log_dir}/#{@name}/#{batch_id}" # convention with cucumber.yml
      FileUtils.rm_rf(test_batch_dir)
      FileUtils.mkpath(test_batch_dir)

      batch_env = {
        'TEST_BATCH_ID'  => batch_id,
        'TEST_BATCH_DIR' => test_batch_dir,
        'BATCH_NUMBER'   => running_total[:batches].to_s
      }.merge(env)

      cucumber_config = ::ParallelCucumber::Helper::CucumberConfigProvider.config_from_options(@cucumber_options, batch_env)
      cli_helper      = ::ParallelCucumber::Helper::CucumberCliHelper.new(cucumber_config)

      batch_env.merge!(cli_helper.env_vars)

      test_result_file = File.join(test_batch_dir, 'test_state.json')
      formats          = cli_helper.formats + [
        "--format ParallelCucumber::Helper::Cucumber::JsonStatusFormatter --out #{test_result_file}"
      ]

      command = [
        @test_command,
        cli_helper.additional_args.join(' '),
        cli_helper.excludes.join(' '),
        cli_helper.requires.join(' '),
        formats.join(' '),
        cli_helper.tags.join(' '),
        tests.join(' ')
      ].join(' ')

      begin
        ParallelCucumber::Helper::Command.exec_command(
          batch_env, 'batch', command, @logger, @log_decoration,
          timeout:           @batch_timeout, capture: true, return_script_error: true,
          return_on_timeout: true, collect_stacktrace: true
        )
      rescue => e
        @logger.error("ERROR #{e} #{e.backtrace.first(5)}")

        begin
          Hooks.fire_on_batch_error(tests: tests, batch_id: batch_id, env: batch_env, exception: e)
        rescue StandardError => exc
          trace = exc.backtrace.join("\n\t")
          @logger.warn("There was exception in on_batch_error hook #{exc.message} \n #{trace}")
        end

        return Helper::Cucumber.unknown_result(tests)
      end

      @logger.info("Did finish execution of tests for #{batch_id} #{tests.join(',')}")
      results = parse_results(test_result_file, tests)
      @logger.info("Did finish parsing results of tests for #{batch_id}")
      @logger.debug("Parsed test results for #{batch_id}\n#{YAML.dump(results)}")
      results
    ensure
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
      @logger.info("Start parsing result for tests: #{tests.join(',')}")
      unless File.file?(f)
        @logger.error("Results file does not exist: #{f}")
        return Helper::Cucumber.unknown_result(tests)
      end
      json_report   = File.read(f)
      if json_report.empty?
        @logger.error("Results file is empty: #{f}")
        return Helper::Cucumber.unknown_result(tests)
      end
      tests_results = Helper::Cucumber.parse_json_report(json_report)
      @logger.info("Did parse result for tests: #{tests_results}")

      tests_results
    rescue => e
      trace = e.backtrace.join("\n\t").sub("\n\t", ": #{$ERROR_INFO}#{e.class ? " (#{e.class})" : ''}\n\t")
      @logger.error("Threw: JSON parse of results caused #{trace}")
      Helper::Cucumber.unknown_result(tests)
    end
  end
end
