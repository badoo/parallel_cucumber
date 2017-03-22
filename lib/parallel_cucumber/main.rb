require 'parallel'

module ParallelCucumber
  class Main
    include ParallelCucumber::Helper::Utils

    def initialize(options)
      @options = options

      @logger = ParallelCucumber::CustomLogger.new(STDOUT)
      @logger.progname = 'Primary' # Longer than 'Main', to make the log file pretty.
      @logger.level = options[:debug] ? ParallelCucumber::CustomLogger::DEBUG : ParallelCucumber::CustomLogger::INFO
    end

    def run
      queue = Helper::Queue.new(@options[:queue_connection_params])
      @logger.debug("Connecting to Queue: #{@options[:queue_connection_params]}")

      unless queue.empty?
        @logger.error("Queue '#{queue.name}' is not empty")
        exit(1)
      end

      all_tests = Helper::Cucumber.suitable_tests(@options[:cucumber_options], @options[:cucumber_args].join(' '))

      if all_tests.empty?
        @logger.error('There are no tests to run')
        exit(1)
      end

      long_running_tests = Helper::Cucumber.suitable_tests(@options[:cucumber_options], @options[:long_running_tests])
      firsts_tests = long_running_tests & all_tests
      if !long_running_tests.empty? && firsts_tests.empty?
        @logger.info("No long running tests found: #{long_running_tests}")
      end
      remaining_tests = (all_tests - firsts_tests).shuffle
      tests = firsts_tests + remaining_tests

      @logger.info("Adding #{tests.count} tests to Queue")
      queue.enqueue(tests)

      if @options[:n] == 0
        @options[:n] = [1, @options[:env_variables].map { |_k, v| v.is_a?(Array) ? v.count : 0 }].flatten.max
        @logger.info("Inferred worker count #{@options[:n]} from env_variables option")
      end

      number_of_workers = [@options[:n], tests.count].min
      unless number_of_workers == @options[:n]
        @logger.info(<<-LOG)
          Number of workers was overridden to #{number_of_workers}.
          Was requested more workers (#{@options[:n]}) than tests (#{tests.count})".
        LOG
      end

      if (@options[:batch_size] - 1) * number_of_workers >= tests.count
        original_batch_size = @options[:batch_size]
        @options[:batch_size] = [(tests.count.to_f / number_of_workers).floor, 1].max
        @logger.info(<<-LOG)
          Batch size was overridden to #{@options[:batch_size]}.
          Presumably it will be more optimal for #{tests.count} tests and #{number_of_workers} workers
          than #{original_batch_size}
        LOG
      end

      diff = []
      info = {}
      total_mm, total_ss = time_it do
        results = Helper::Command.wrap_block(@options[:log_decoration],
                                             @options[:log_decoration]['worker_block'] || 'workers',
                                             @logger) do
          finished = []
          Parallel.map(
            0...number_of_workers,
            in_processes: number_of_workers,
            finish: -> (_, index, _) { @logger.info("Finished: #{finished[index] = index} #{finished - [nil]}") }
          ) do |index|
            Worker.new(@options, index).start(env_for_worker(@options[:env_variables], index))
          end.inject(:merge) # Returns hash of file:line to statuses + :worker-index to summary.
        end
        results ||= {}
        unrun = tests - results.keys
        @logger.error("Tests #{unrun.join(' ')} were not run") unless diff.empty?
        @logger.error("Queue #{queue.name} is not empty") unless queue.empty?

        Helper::Command.wrap_block(
          @options[:log_decoration],
          'Worker summary',
          @logger
        ) { results.find_all { |w| @logger.info("#{w.first} #{w.last.sort}") if w.first =~ /^:worker-/ } }

        info = Status.constants.map do |status|
          status = Status.const_get(status)
          tests_with_status = results.select { |_t, s| s == status }.keys
          [status, tests_with_status]
        end.to_h
      end

      @logger.debug("SUMMARY=#{@options[:summary]}") if @options[:summary]
      info.each do |s, tt|
        next if tt.empty?
        @logger.info("Total: #{s.to_s.upcase} tests (#{tt.count}): #{tt.join(' ')}")
        filename = @options[:summary] && @options[:summary][s.to_s.downcase]
        open(filename, 'w') { |f| f << tt.join("\n") } if filename
      end

      @logger.info("\nTook #{total_mm} minutes #{total_ss} seconds")

      exit((diff + info[Status::FAILED] + info[Status::UNKNOWN]).empty? ? 0 : 1)
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
