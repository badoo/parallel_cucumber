module ParallelCucumber
  module Helper
    module Command
      class TimedOutError < RuntimeError; end
      class << self
        def wrap_block(log_decoration, block_name, logger)
          [$stdout, $stderr].each(&:flush)
          logger << format(log_decoration['start'] + "\n", block_name) if log_decoration['start']
          [$stdout, $stderr].each(&:flush)
          yield
        ensure
          [$stdout, $stderr].each(&:flush)
          logger << format(log_decoration['end'] + "\n", block_name) if log_decoration['end']
          [$stdout, $stderr].each(&:flush)
        end

        ONE_SECOND = 1

        def exec_command(env, desc, script, logger, log_decoration = {}, timeout: 30, capture: false, return_script_error: false) # rubocop:disable Metrics/ParameterLists, Metrics/LineLength
          block_name = ''
          if log_decoration['worker_block']
            if log_decoration['start'] || log_decoration['end']
              block_name = "#{"#{env['TEST_USER']}-w#{env['WORKER_INDEX']}>"} #{desc}"
            end
          end

          logger << format(log_decoration['start'] + "\n", block_name) if log_decoration['start']
          full_script = "#{script} 2>&1"
          env_string = env.map { |k, v| "#{k}=#{v}" }.sort.join(' ')
          logger << "== Running command `#{full_script}` at #{Time.now}\n== with environment variables: #{env_string}\n"
          wait_thread = nil
          pout = nil
          capture &&= [''] # Pass by reference
          exception = nil

          begin
            completed = begin
              pin, pout, wait_thread = Open3.popen2e(env, full_script)
              logger << "Command has pid #{wait_thread[:pid]}\n"
              pin.close
              out_reader = Thread.new do
                output_reader(pout, wait_thread, logger, capture)
              end

              unless out_reader.join(timeout)
                raise TimedOutError
              end

              graceful_process_shutdown(out_reader, wait_thread, pout, logger)

              wait_thread.value # reap already-terminated child.
              "Command completed #{wait_thread.value} at #{Time.now}"
            end

            logger << "#{completed}\n"

            raise "Script returned #{wait_thread.value.exitstatus}" unless wait_thread.value.success? || return_script_error

            capture_or_empty = capture ? capture.first : '' # Even '' is truthy
            return wait_thread.value.success? ? capture_or_empty : nil
          rescue TimedOutError => e
            force_kill_process_with_tree(out_reader, wait_thread, pout, full_script, logger, timeout)

            exception = e
          rescue => e
            logger.debug("Exception #{wait_thread ? wait_thread[:pid] : "wait_thread=#{wait_thread}=nil"}")
            trace = e.backtrace.join("\n\t").sub("\n\t", ": #{$ERROR_INFO}#{e.class ? " (#{e.class})" : ''}\n\t")
            logger.error("Threw for #{full_script}, caused #{trace}")

            exception = e
          ensure
            logger << format(log_decoration['end'] + "\n", block_name) if log_decoration['end']
          end
          logger.error("*** UNUSUAL TERMINATION FOR: #{script}")

          raise exception
        end

        def log_until_incomplete_line(logger, out_string)
          loop do
            line, out_string = out_string.split(/\n/, 2)
            return line || '' unless out_string
            logger << line
            logger << "\n"
          end
        end

        private

        def output_reader(pout, wait_thread, logger, capture)
          out_string = ''

          loop do
            io_select = IO.select([pout], [], [], ONE_SECOND)
            unless io_select || wait_thread.alive?
              logger << "\n== Terminating because io_select=#{io_select} when wait_thread.alive?=#{wait_thread.alive?}\n"
              break
            end
            next unless io_select
            # Windows doesn't support read_nonblock!
            partial = pout.readpartial(8192)
            capture[0] += partial if capture
            out_string = log_until_incomplete_line(logger, out_string + partial)
          end
        rescue EOFError
          logger << "\n== EOF is normal exit, #{wait_thread.inspect}\n"
        rescue => e
          logger << "\n== Exception in out_reader due to #{e.inspect} #{e.backtrace}\n"
        ensure
          logger << out_string
          logger << ["\n== Left out_reader at #{Time.now}; ",
                     "pipe=#{wait_thread.status}+#{wait_thread.status ? '≤no value≥' : wait_thread.value}\n"].join
        end

        def graceful_process_shutdown(out_reader, wait_thread, pout, logger)
          out_reader.value # Should terminate with wait_thread
          pout.close
          if wait_thread.status
            logger << "== Thread #{wait_thread.inspect} is not dead"

            if wait_thread.join(3)
              logger << "== Thread #{wait_thread.inspect} joined late"
            else
              wait_thread.terminate # Just in case
              logger << "== Thread #{wait_thread.inspect} terminated"
            end # Make an effort to reap
          end

          wait_thread.value # reap already-terminated child.
          "Command completed #{wait_thread.value} at #{Time.now}"
        end

        def force_kill_process_with_tree(out_reader, wait_thread, pout, full_script, logger, timeout) # rubocop:disable Metrics/ParameterLists, Metrics/LineLength
          out_reader.exit
          tree = Helper::Processes.ps_tree
          pid = wait_thread[:pid].to_s
          unless Helper::Processes.ms_windows?
            logger << "Timeout, so trying SIGUSR1 to trigger watchdog stacktrace #{wait_thread[:pid]}=#{full_script}"
            Helper::Processes.kill_tree('SIGUSR1', pid, logger, tree)
            sleep 2
          end

          logger << "Timeout, so trying SIGINT at #{wait_thread[:pid]}=#{full_script}"

          log_copy = Thread.new do
            pout.each_line { |l| logger << l }
          end
          log_copy.exit unless log_copy.join(2)

          pout.close

          wait_sigint = 15
          logger << "Timeout #{timeout}s was reached. Sending SIGINT(2), SIGKILL after #{wait_sigint}s."
          begin
            Helper::Processes.kill_tree('SIGINT', pid, logger, tree)

            timed_out = wait_sigint.times do |t|
              break if Helper::Processes.all_pids_dead?(pid, logger, nil, tree)
              logger << "Wait dead #{t} pid #{pid}"
              sleep 1
            end

            if timed_out
              logger << "Process #{pid} lasted #{wait_sigint}s after SIGINT(2), so SIGKILL(9)! Fatality!"
              Helper::Processes.kill_tree('SIGKILL', pid, logger, nil, tree)
              logger << "Tried SIGKILL #{pid}!"
            end

            logger << "About to reap root #{pid}"
            wait_thread.value # reap root - everything else should be reaped by init.
            logger << "Reaped root #{pid}"
          end
        end
      end
    end
  end
end
