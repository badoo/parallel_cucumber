module ParallelCucumber
  module Helper
    module Command
      class << self
        def exec_command(env, script, log_file, logger, log_decoration = {}, timeout = 30) # rubocop:disable Metrics/ParameterLists, Metrics/LineLength
          full_script = "#{script} >>#{log_file} 2>&1"
          message = <<-LOG
        Running command `#{full_script}` with environment variables: #{env.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}
          LOG
          logger.debug(message)
          pstat = nil
          pout = nil
          file = File.open(log_file)
          file.seek(0, File::SEEK_END)
          begin
            completed = Timeout.timeout(timeout) do
              pin, pout, pstat = Open3.popen2e(env, full_script)
              logger.debug("Command has pid #{pstat[:pid]}")
              pin.close
              out = pout.readlines.join("\n") # Not expecting anything in 'out' due to redirection, but...
              pout.close
              pstat.value # N.B. Await process termination
              "Command completed #{pstat.value} and output '#{out}'"
            end
            logger.debug(completed)
            system("lsof #{log_file} >> #{log_file}")
            system("ps -axf | grep '#{pstat[:pid]}\\s' >> #{log_file}")
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
              system("lsof #{log_file} >> #{log_file}")
              logger.debug("Tried SIGKILL #{pstat[:pid]} - hopefully no processes still have #{log_file}!")
            end
          rescue => e
            logger.debug("Exception #{pstat[:pid]}")
            trace = e.backtrace.join("\n\t").sub("\n\t", ": #{$ERROR_INFO}#{e.class ? " (#{e.class})" : ''}\n\t")
            logger.error("Threw: for #{full_script}, caused #{trace}")
          ensure
            # It's only logging - don`t really care if we lose some, though it would be nice if we didn't.
            prefix = "#{env['TEST_USER']}-w#{env['WORKER_INDEX']}>"
            if log_decoration['worker_block']
              printf(log_decoration['start'] + "\n", prefix) if log_decoration['start']
              puts "#{prefix} #{file.readline}" until file.eof
              printf(log_decoration['end'] + "\n", prefix) if log_decoration['end']
            end
          end
          logger.debug("Unusual termination for command: #{script}")
          nil
        end
      end
    end
  end
end
