require 'parallel'

module ParallelCucumber
  class Main
    include ParallelCucumber::Helper::Utils

    def initialize(options)
      @options = options

      @logger = ParallelCucumber::CustomLogger.new(STDOUT)
      load_external_files
      @logger.progname = 'Primary' # Longer than 'Main', to make the log file pretty.
      @logger.level = options[:debug] ? ParallelCucumber::CustomLogger::DEBUG : ParallelCucumber::CustomLogger::INFO
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
      queue = Helper::Queue.new(@options[:queue_connection_params])

      unless queue.empty?
        @logger.error("Queue '#{queue.name}' is not empty")
        exit(1)
      end

      all_tests = Helper::Cucumber.selected_tests(@options[:cucumber_options], @options[:cucumber_args])

      if all_tests.empty?
        @logger.info('There is no tests to run, exiting...')
        exit(0)
      end

      count = all_tests.count

      long_running_tests = if @options[:long_running_tests]
                             narrowed_long_running_tests = [
                               @options[:cucumber_args],
                               @options[:long_running_tests]
                             ].join(' ')
                             Helper::Cucumber.selected_tests(@options[:cucumber_options], narrowed_long_running_tests)
                           else
                             []
                           end
      first_tests = long_running_tests & all_tests
      if !long_running_tests.empty? && first_tests.empty?
        @logger.info("No long running tests found in common with main options: #{long_running_tests}")
      end
      tests = first_tests + (all_tests - first_tests).shuffle

      @options[:directed_tests].each do |k, v|
        directed_tests = Helper::Cucumber.selected_tests(@options[:cucumber_options], v)
        if directed_tests.empty?
          @logger.warn("Queue for #{k} is empty - nothing selected by #{v}")
        else
          directed_tests = (directed_tests & long_running_tests) + (directed_tests - long_running_tests).shuffle
          @logger.debug("Connecting to Queue: _#{k}")
          directed_queue = Helper::Queue.new(@options[:queue_connection_params], "_#{k}")
          @logger.info("Adding #{directed_tests.count} tests to queue _#{k}")
          directed_queue.enqueue(directed_tests)
          tests -= directed_tests
        end
      end

      @logger.info("Adding #{tests.count} tests to Queue")
      queue.enqueue(tests) unless tests.empty?

      number_of_workers = determine_work_and_batch_size(count)

      status_totals = {}
      total_mm, total_ss = time_it do
        results = run_parallel_workers(number_of_workers) || {}

        begin
          Hooks.fire_after_workers(results: results, queue: queue)
        rescue StandardError => e
          trace = e.backtrace.join("\n\t")
          @logger.warn("There was exception in after_workers hook #{e.message} \n #{trace}")
        end

        unrun = tests - results.keys
        @logger.error("Tests #{unrun.join(' ')} were not run") unless unrun.empty?
        @logger.error("Queue #{queue.name} is not empty") unless queue.empty?

        status_totals = Status.constants.map do |status|
          status = Status.const_get(status)
          tests_with_status = results.select { |_t, s| s == status }.keys
          [status, tests_with_status]
        end.to_h

        Helper::Command.wrap_block(@options[:log_decoration], 'Worker summary', @logger) do
          results.find_all { |w| w.first =~ /^:worker-/ }.each { |w| @logger.info("#{w.first} #{w.last.sort}") }
        end

        report_by_group(results)
      end

      @logger.debug("SUMMARY=#{@options[:summary]}") if @options[:summary]
      status_totals.each do |s, tt|
        next if tt.empty?
        @logger.info("Total: #{s.to_s.upcase} tests (#{tt.count}): #{tt.join(' ')}")
        filename = @options[:summary] && @options[:summary][s.to_s.downcase]
        open(filename, 'w') { |f| f << tt.join("\n") } if filename
      end

      @logger.info("\nTook #{total_mm} minutes #{total_ss} seconds")

      exit((tests - status_totals[Status::PASSED] - status_totals[Status::SKIPPED]).empty? ? 0 : 1)
    end

    def report_by_group(results)
      group = Hash.new { |h, k| h[k] = Hash.new(0) } # Default new keys to 0

      Helper::Command.wrap_block(@options[:log_decoration], 'Worker summary', @logger) do
        results.find_all { |w| w.first =~ /^:worker-/ }.each do |w|
          # w = [:worker-0, [[:batches, 7], [:group, "localhost2"], [:skipped, 7]]]
          gp = w.last[:group]
          next unless gp
          w.last.each { |(k, v)| group[gp][k] += w.last[k] if v && k != :group }
          group[gp][:group] = {} unless group[gp].key?(:group)
          group[gp][:group][w.first] = 1
        end
      end

      @logger.info "== Groups key count #{group.keys.count}"

      return unless group.keys.count > 1

      Helper::Command.wrap_block(@options[:log_decoration], 'Group summary', @logger) do
        group.each { |(k, v)| @logger.info("#{k} #{v.sort}") }
      end
    end

    def run_parallel_workers(number_of_workers)
      Helper::Command.wrap_block(@options[:log_decoration],
                                 @options[:log_decoration]['worker_block'] || 'workers',
                                 @logger) do
        remaining = (0...number_of_workers).to_a
        map = Parallel.map(
          remaining.dup,
          in_threads: number_of_workers,
          finish: -> (_, ix, _) { @logger.synch { |l| l.info("Finished: #{ix} remaining: #{remaining -= [ix]}") } }
        ) do |index|
          ParallelCucumber::Worker
            .new(@options, index, @logger)
            .start(env_for_worker(@options[:env_variables], index))
        end
        map.inject(:merge) # Returns hash of file:line to statuses + :worker-index to summary.
      end
    end

    def determine_work_and_batch_size(count)
      if @options[:n] == 0
        @options[:n] = [1, @options[:env_variables].map { |_k, v| v.is_a?(Array) ? v.count : 0 }].flatten.max
        @logger.info("Inferred worker count #{@options[:n]} from env_variables option")
      end

      number_of_workers = [@options[:n], count].min
      unless number_of_workers == @options[:n]
        @logger.info(<<-LOG)
          Number of workers was overridden to #{number_of_workers}.
          More workers (#{@options[:n]}) requested than tests (#{count})".
        LOG
      end

      @logger.info(<<-LOG)
        Number of workers is #{number_of_workers}.
      LOG

      if (@options[:batch_size] - 1) * number_of_workers >= count
        original_batch_size = @options[:batch_size]
        @options[:batch_size] = [(count.to_f / number_of_workers).floor, 1].max
        @logger.info(<<-LOG)
          Batch size was overridden to #{@options[:batch_size]}.
          Presumably it will be more optimal for #{count} tests and #{number_of_workers} workers
          than #{original_batch_size}
        LOG
      end
      number_of_workers
    end

    private

    def env_for_worker(env_variables, worker_number)
      env = env_variables.map do |k, v|
        case v
        when String, Numeric, TrueClass, FalseClass
          [k, v]
        when Array
          [k, v[worker_number]]
        when Hash
          value = v[worker_number.to_s]
          [k, value] unless value.nil?
        when NilClass
        else
          raise("Don't know how to set '#{v}'<#{v.class}> to the environment variable '#{k}'")
        end
      end.compact.to_h

      # Defaults, if absent in env. Shame 'merge' isn't something non-commutative like 'adopts/defaults'.
      env = { TEST: 1, TEST_PROCESS_NUMBER: worker_number, WORKER_INDEX: worker_number }.merge(env)

      # Overwrite this if it exists in env.
      env.merge(PARALLEL_CUCUMBER_EXPORTS: env.keys.join(',')).map { |k, v| [k.to_s, v.to_s] }.to_h
    end
  end
end
