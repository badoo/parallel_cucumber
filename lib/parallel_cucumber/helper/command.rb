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
          begin
            completed = Timeout.timeout(timeout) do
              pin, pout, pstat = Open3.popen2e(env, full_script)
              logger.debug("Command has pid #{pstat[:pid]}")
              pin.close
              out = pout.readlines.join
              pout.close
              pstat.value # N.B. Await process termination
              "Command completed #{pstat.value}; output was:\n#{out}\n...output ends\n"
            end
            logger << completed
            logger.debug(%x(ps -axf | grep '#{pstat[:pid]}\\s'))
            return pstat.value.success?
          rescue Timeout::Error
            pout.close
            logger.debug("Timeout, so trying SIGINT #{pstat[:pid]}")
            wait_sigint = 15
            logger.error("Timeout #{timeout}s was reached. Sending SIGINT(2), then waiting up to #{wait_sigint}s")
            tree = Helper::Processes.ps_tree
            begin
              Helper::Processes.kill_tree('SIGINT', pstat[:pid].to_s, tree)
              timed_out = wait_sigint.times do |t|
                break if Helper::Processes.all_pids_dead?(pstat[:pid].to_s, nil, tree)
                logger.info("Wait dead #{t}")
                sleep 1
              end
              if timed_out
                logger.error("Process #{pstat[:pid]} lasted #{wait_sigint}s after SIGINT(2), so SIGKILL(9)! Fatality!")
                Helper::Processes.kill_tree('SIGKILL', pstat[:pid].to_s, nil, tree)
              end
              logger.debug("About to reap root #{pstat[:pid]}")
              pstat.value # reap root - everything else should be reaped by init.
              logger.debug("Reaped root #{pstat[:pid]}")
              logger.debug("Tried SIGKILL #{pstat[:pid]}!")
            end
          rescue => e
            logger.debug("Exception #{pstat ? pstat[:pid] : "pstat=#{pstat}=nil"}")
            trace = e.backtrace.join("\n\t").sub("\n\t", ": #{$ERROR_INFO}#{e.class ? " (#{e.class})" : ''}\n\t")
            logger.error("Threw: for #{full_script}, caused #{trace}")
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
