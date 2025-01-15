require 'parallel'
require 'connection_pool'

module ParallelCucumber
  class Main
    include ParallelCucumber::Helper::Utils

    def initialize(options)
      @options = options

      @logger = ParallelCucumber::CustomLogger.new(STDOUT)
      load_external_files
      @logger.progname                = 'ParallelCucumber'
      @logger.level                   = ParallelCucumber::CustomLogger::DEBUG
      @redis_url, @default_queue_name = @options[:queue_connection_params]
      queue_timeout                   = @options[:queue_connection_timeout]
      @redis_pool                     = ConnectionPool::Wrapper.new(size: 10, timeout: queue_timeout) {
        Redis.new(
          url:                @redis_url,
          timeout:            queue_timeout,
          connect_timeout:    queue_timeout,
          reconnect_attempts: @options[:queue_reconnect_attempts],
        )
      }
    end

    def load_external_files
      return if @options[:load_files].nil?
      @options[:load_files].each do |file|
        @logger.debug("Loading File: #{file}")
        load file
      end
    end

    def run
      @logger.debug("Connecting to Queue: #{@options[:queue_connection_params]}")
      queue = Helper::Queue.new(@redis_pool, @default_queue_name)

      unless queue.empty?
        @logger.error("Queue '#{queue.name}' is not empty")
        exit(1)
      end

      begin
        all_tests = Helper::Cucumber.selected_tests(@options[:cucumber_options], @options[:cucumber_args], @options[:env_variables])
      rescue StandardError => error
        Hooks.fire_on_dry_run_error(error)
        raise error
      end

      if all_tests.empty?
        @logger.info('There is no tests to run, exiting...')
        exit(0)
      end

      tests = all_tests.shuffle

      @logger.info("Adding #{tests.count} tests to Queue")
      queue.enqueue(tests)

      begin
        Hooks.fire_before_workers(queue: queue)
      rescue StandardError => e
        trace = e.backtrace.join("\n\t")
        @logger.warn("There was exception in before_workers hook #{e.message} \n #{trace}")
      end

      number_of_workers = determine_work_and_batch_size(queue.length)

      status_totals      = {}
      total_mm, total_ss = time_it do
        workers_results = run_parallel_workers(number_of_workers) || {}

        worker_stats_regexp = /^:worker-\d+$/
        executed_tests      = []
        worker_stats        = []

        # @type [Hash] worker_results
        workers_results.each do |workers_result|
          begin
            if workers_result.first.to_s.match?(worker_stats_regexp)
              worker_stats.push(workers_result)
            else
              executed_tests.push(workers_result)
            end
          rescue StandardError => e
            @logger.error("Failed with error while parsing workers_result: #{workers_result}")
            @logger.error("Error: #{e.message} #{e.backtrace}")
          end
        end

        executed_tests = executed_tests.to_h
        worker_stats   = worker_stats.to_h

        begin
          Hooks.fire_after_workers(results: executed_tests.dup, queue: queue)
        rescue StandardError => e
          trace = e.backtrace.join("\n\t")
          @logger.warn("There was exception in after_workers hook #{e.message} \n #{trace}")
        end

        unrun = tests - executed_tests.keys.map(&:to_s)
        @logger.error("Tests #{unrun.join(' ')} were not run") unless unrun.empty?
        @logger.error("Queue #{queue.name} is not empty") unless queue.empty?

        status_totals = Status.constants.map do |status|
          status_symbol     = Status.const_get(status)
          tests_with_status = executed_tests.select { |_t, s| s[:status] == status_symbol }.keys.map(&:to_s)
          [status_symbol, tests_with_status]
        end.to_h

        Helper::Command.wrap_block(@options[:log_decoration], 'Worker summary', @logger) do
          worker_stats.each { |w| @logger.info("Stats for worker: #{w.first} #{w.last.sort}") }
        end
      end

      @logger.info("[#{self.class}]: SUMMARY=#{@options[:summary]}") unless @options[:summary].nil?

      @logger.info("[#{self.class}]: Total tests stats:")

      Status.constants.each do |status|
        status_symbol         = Status.const_get(status)
        test_paths_for_status = status_totals[status_symbol] || [] # possible nil here if there were no occasions of such status
        test_count_for_status = test_paths_for_status.count
        @logger.info("[#{self.class}]: Total amount of tests with status: #{status_symbol.to_s.upcase} is (#{test_count_for_status})")

        filename = @options.fetch(:summary, nil)&.fetch(test_result_keyword.to_s.downcase, nil)

        unless filename.nil?
          File.open(filename, 'w') { |f| f.write(test_paths.join("\n")) }
        end
      end

      @logger.info("\nTook #{total_mm} minutes #{total_ss} seconds")

      result_failed_tests    = status_totals.fetch(Status::FAILED, [])
      result_passed_tests    = status_totals.fetch(Status::PASSED, [])
      result_pending_tests   = status_totals.fetch(Status::PENDING, [])
      result_skipped_tests   = status_totals.fetch(Status::SKIPPED, [])
      result_undefined_tests = status_totals.fetch(Status::UNDEFINED, [])
      result_unknown_tests   = status_totals.fetch(Status::UNKNOWN, [])

      successful_test_run = true

      [
        Status::FAILED,
        Status::PENDING,
        Status::UNKNOWN,
        Status::UNDEFINED,
      ].each do |status|
        tests_for_status = status_totals.fetch(status, [])

        unless tests_for_status.empty?
          successful_test_run = false
          @logger.error("[#{self.class}]: Will exit with non-zero code due to tests with result \"#{status}\": #{tests_for_status.count}")
        end
      end

      executed_tests     = (result_failed_tests + result_passed_tests + result_pending_tests + result_skipped_tests + result_undefined_tests + result_unknown_tests).flatten.sort.uniq
      not_executed_tests = tests.sort.uniq - executed_tests

      unless not_executed_tests.empty?
        @logger.error("\n[#{self.class}]: Some tests were not executed: #{not_executed_tests.join(', ')}")
      end

      exit_code = if successful_test_run && not_executed_tests.empty?
                    0
                  else
                    1
                  end

      @logger.info("\n[#{self.class}]: Finished test runs and will exit with exit code: #{exit_code}")
      exit(exit_code)
    end

    def run_parallel_workers(number_of_workers)
      Helper::Command.wrap_block(@options[:log_decoration],
                                 @options[:log_decoration]['worker_block'] || 'workers',
                                 @logger) do

        worker_manager = ParallelCucumber::WorkerManager.new(@options, @logger, @redis_pool, @default_queue_name)
        worker_manager.start(number_of_workers)
      ensure
        worker_manager.kill
      end
    end

    def determine_work_and_batch_size(count)
      if @options[:n] == 0
        @options[:n] = [1, @options[:env_variables].map { |_k, v| v.is_a?(Array) ? v.count : 0 }].flatten.max
        @logger.info("Inferred worker count #{@options[:n]} from env_variables option")
      end

      number_of_workers = [@options[:n], [@options[:backup_worker_count], count].max].min
      unless number_of_workers == @options[:n]
        @logger.info(<<-LOG)
          Number of workers was overridden to #{number_of_workers}.
          More workers (#{@options[:n]}) requested than tests (#{count}). BackupWorkerCount: #{@options[:backup_worker_count]}".
        LOG
      end

      @logger.info(<<-LOG)
        Number of workers is #{number_of_workers}.
      LOG

      if (@options[:batch_size] - 1) * number_of_workers >= count
        original_batch_size   = @options[:batch_size]
        @options[:batch_size] = [(count.to_f / number_of_workers).floor, 1].max
        @logger.info(<<-LOG)
          Batch size was overridden to #{@options[:batch_size]}.
          Presumably it will be more optimal for #{count} tests and #{number_of_workers} workers
          than #{original_batch_size}
        LOG
      end
      number_of_workers
    end
  end
end
