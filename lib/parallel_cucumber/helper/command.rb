module ParallelCucumber
  module Helper
    module Command
      class << self
        def wrap_block(log_decoration, block_name, logger)
          logger << format(log_decoration['start'] + "\n", block_name) if log_decoration['start']
          yield
        ensure
          logger << format(log_decoration['end'] + "\n", block_name) if log_decoration['end']
        end

        def exec_command(env, desc, script, _log_file, logger, log_decoration = {}, timeout = 30) # rubocop:disable Metrics/ParameterLists, Metrics/LineLength
          block_name = ''
          if log_decoration['worker_block']
            if log_decoration['start'] || log_decoration['end']
              block_name = "#{"#{env['TEST_USER']}-w#{env['WORKER_INDEX']}>"} #{desc}"
            end
          end
          logger << format(log_decoration['start'] + "\n", block_name) if log_decoration['start']
          full_script = "#{script} 2>&1"
          env_string = env.map { |k, v| "#{k}=#{v}" }.sort.join(' ')
          message = <<-LOG
        Running command `#{full_script}` with environment variables: #{env_string}
          LOG
          logger.debug(message)
          pstat = nil
          pout = nil
          out = nil
          begin
            completed = Timeout.timeout(timeout) do
              pin, pout, pstat = Open3.popen2e(env, full_script)
              logger.debug("Command has pid #{pstat[:pid]}")
              pin.close
              out = []
              pout.each_line { |l| out << l } # incremental version of out = pout.readlines.join
              pout.close
              pstat.value # reap already-terminated child.
              ["Command completed #{pstat.value}; output was (lines=#{out.count}):",
               out.join,
               "...output #{pstat.value} ends\n"].join("\n")
            end
            logger << completed
            return pstat.value.success?
          rescue Timeout::Error
            tree = Helper::Processes.ps_tree
            unless Helper::Processes.ms_windows?
              logger.debug("Timeout, so trying SIGUSR1 to trigger watchdog stacktrace #{pstat[:pid]}")
              Helper::Processes.kill_tree('SIGUSR1', pid, tree)
              logger << %x(ps -ax)
              sleep 2
            end
            pout.close
            logger.debug("Timeout, so trying SIGINT #{pstat[:pid]}")
            wait_sigint = 15
            output = out ? "\nBut output so far: ≤#{out}≥\n" : 'but no output so far'
            logger.error("Timeout #{timeout}s was reached. Sending SIGINT(2), SIGKILL after #{wait_sigint}s.#{output}")
            begin
              pid = pstat[:pid].to_s
              Helper::Processes.kill_tree('SIGINT', pid, tree)
              timed_out = wait_sigint.times do |t|
                break if Helper::Processes.all_pids_dead?(pid, nil, tree)
                logger.error("Wait dead #{t} pid #{pid}")
                sleep 1
              end
              if timed_out
                logger.error("Process #{pid} lasted #{wait_sigint}s after SIGINT(2), so SIGKILL(9)! Fatality!")
                Helper::Processes.kill_tree('SIGKILL', pid, nil, tree)
              end
              logger.debug("About to reap root #{pid}")
              pstat.value # reap root - everything else should be reaped by init.
              logger.debug("Reaped root #{pid}")
              logger.debug("Tried SIGKILL #{pid}!")
            end
          rescue => e
            logger.debug("Exception #{pstat ? pstat[:pid] : "pstat=#{pstat}=nil"}")
            trace = e.backtrace.join("\n\t").sub("\n\t", ": #{$ERROR_INFO}#{e.class ? " (#{e.class})" : ''}\n\t")
            output = out ? "\nOutput: ≤#{out}≥\n" : 'but no output caught'
            logger.error("Threw for #{full_script}, caused #{trace}#{output}")
          ensure
            logger << format(log_decoration['end'] + "\n", block_name) if log_decoration['end']
          end
          logger.debug("Unusual termination for command: #{script}")
          nil
        end
      end
    end
  end
end
