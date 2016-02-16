require 'English'
require 'tempfile'

module ParallelCucumber
  class Worker
    include ParallelCucumber::Helper::Utils

    def initialize(options, index)
      @batch_size = options[:batch_size]
      @cucumber_options = options[:cucumber_options]
      @env_variables = options[:env_variables]
      @index = index
      @queue_connection_params = options[:queue_connection_params]
      @setup_worker = options[:setup_worker]
      @teardown_worker = options[:teardown_worker]
      @worker_delay = options[:worker_delay]

      @logger = ParallelCucumber::CustomLogger.new(STDOUT)
      @logger.progname = "Worker #{@index}"
      @logger.level = options[:debug] ? ParallelCucumber::CustomLogger::DEBUG : ParallelCucumber::CustomLogger::INFO
    end

    def start(env)
      @logger.info('Starting')
      log_file = "worker_#{@index}.log"
      File.delete(log_file) if File.exist?(log_file)

      unless @worker_delay.zero?
        @logger.info("Waiting #{@worker_delay * @index} seconds before start")
        sleep(@worker_delay * @index)
      end

      @logger.debug(<<-LOG)
        Additional environment variables: #{env.map { |k, v| "#{k}=#{v}" }.join(' ')}
      LOG

      unless @setup_worker.nil?
        mm, ss = time_it do
          @logger.info('Setup running')
          success = exec_command(env, @setup_worker, log_file)
          @logger.warn('Setup finished with error') unless success
        end
        @logger.debug("Setup took #{mm} minutes #{ss} seconds")
      end

      results = {}
      queue = ParallelCucumber::Helper::Queue.new(@queue_connection_params)

      loop_mm, loop_ss = time_it do
        loop do
          tests = []
          batch_results = {}
          @batch_size.times do
            tests << queue.dequeue
          end
          tests.compact!
          break if tests.empty?

          batch_id = "#{Time.now.to_i}-#{@index}"
          @logger.debug("Batch ID is #{batch_id}")
          @logger.info("Taking #{tests.count} tests from the Queue: #{tests.join(' ')}")

          batch_mm, batch_ss = time_it do
            Tempfile.open(["w-#{@index}", '.json']) do |f|
              cmd = "cucumber --format pretty --format json --out #{f.path} #{@cucumber_options} #{tests.join(' ')}"
              exec_command({ :TEST_BATCH_ID.to_s => batch_id }.merge(env), cmd, log_file)
              f.close

              json_report = File.read(f.path)
              batch_results = Helper::Cucumber.parse_json_report(json_report)
            end

            batch_info = Status.constants.map do |status|
              status = Status.const_get(status)
              [status, batch_results.select { |_t, s| s == status }.keys]
            end.to_h
            batch_info.each do |s, tt|
              @logger.info("#{s.to_s.upcase} tests (#{tt.count}): #{tt.join(' ')}") unless tt.empty?
            end

            unless tests.count == batch_results.count
              @logger.error(<<-LOG)
#{tests.count} tests were taken from Queue, but #{batch_results.count} were run:
                #{((tests - batch_results.keys) + (batch_results.keys - tests)).join(' ')}
              LOG
            end
            results.merge!(batch_results)
          end
          @logger.debug("Batch #{batch_id} took #{batch_mm} minutes #{batch_ss} seconds")
        end
      end
      @logger.debug("Loop took #{loop_mm} minutes #{loop_ss} seconds")

      unless @teardown_worker.nil?
        mm, ss = time_it do
          @logger.info('Teardown running')
          success = exec_command(env, @teardown_worker, log_file)
          @logger.warn('Teardown finished with error') unless success
        end
        @logger.debug("Teardown took #{mm} minutes #{ss} seconds")
      end

      results
    end

    private

    def exec_command(env, script, log_file)
      full_script = "#{script} 2>&1 >> #{log_file}"
      message = <<-LOG
        Running command `#{full_script}` with environment variables: #{env.map { |k, v| "#{k}=#{v}" }.join(' ')}
      LOG
      @logger.debug(message)
      Process.wait(IO.popen(env, full_script).pid)
      $CHILD_STATUS.success?
    end
  end
end
