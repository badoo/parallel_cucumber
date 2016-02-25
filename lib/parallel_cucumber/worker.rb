require 'English'
require 'tempfile'

module ParallelCucumber
  class Worker
    include ParallelCucumber::Helper::Utils

    def initialize(options, index)
      @batch_size = options[:batch_size]
      @cucumber_options = options[:cucumber_options]
      @test_command = options[:test_command]
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
            # TODO: Handle recovery of dequeued tests, if a worker dies mid-processing.
            # For example: use MULTI/EXEC to move the end of the queue into a hash keyed by the worker, with enough
            # TCP information to allow someone else to check whether such a worker is still live.
            # If a worker sees the queue is empty, it should check that all workers mentioned in the hash are still
            # live, and atomically shift an unresponsive worker's tasks back to the queue.
            # A worker deletes its keyed information from the hash once the task is complete, unless it sees that
            # someone decided that it was dead, whereupon it should report failure.
            tests << queue.dequeue
          end
          tests.compact!
          break if tests.empty?

          batch_id = "#{Time.now.to_i}-#{@index}"
          @logger.debug("Batch ID is #{batch_id}")
          @logger.info("Taking #{tests.count} tests from the Queue: #{tests.join(' ')}")

          batch_mm, batch_ss = time_it do
            Tempfile.open(["w-#{@index}", '.json'], tmpdir='/tmp') do |f|
              cmd = "#{@test_command} --format pretty --format json --out #{f.path} #{@cucumber_options} #{tests.join(' ')}"
              exec_command({ :TEST_BATCH_ID.to_s => batch_id, :TEST_JSON_FILE.to_s => f.path }.merge(env), cmd, log_file)
              f.close

              json_report = File.read(f.path)

              begin
                raise 'Results file was empty' if json_report.empty?
                batch_results = Helper::Cucumber.parse_json_report(json_report)
              rescue => e
                trace = e.backtrace.join("\n\t").sub("\n\t", ": #{$!}#{e.class ? " (#{e.class})" : ''}\n\t")
                @logger.error("Threw: JSON parse of results caused #{trace}")
              ensure
                batch_results ||= {}
              end
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

    def file_append(filename, message)
      File.open(filename, 'a') { |f| f << "\n#{message}\n\n"}
    end

    def dual_log(log_file, message)
      @logger.debug(message)
      file_append(log_file, message)
    end

    def exec_command(env, script, log_file)
      full_script = "#{script} >>#{log_file} 2>&1"
      message = <<-LOG
        Running command `#{full_script}` with environment variables: #{env.map { |k, v| "#{k}=#{v}" }.join(' ')}
      LOG
      dual_log(log_file, message)
      begin
        out, status = Open3.capture2e(env, full_script)
        completed = "Command completed with exit #{status} and output '#{out}'"
        dual_log(log_file, completed)
        unless status.success?
          puts "TAIL OF #{log_file}\n\n#{%x(tail -20 #{log_file})}\n\nENDS\n"
        end
        return status.success?
      rescue StandardError => e
        trace = e.backtrace.join("\n\t").sub("\n\t", ": #{$!}#{e.class ? " (#{e.class})" : ''}\n\t")
        @logger.error("Threw: for #{full_script}, caused #{trace}")
        return false
      end
    end
  end
end
