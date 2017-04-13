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

        def exec_command(env, desc, script, log_file, logger, log_decoration = {}, timeout = 30) # rubocop:disable Metrics/ParameterLists, Metrics/LineLength
          begin
            file = File.open(log_file)
            file.seek(0, File::SEEK_END)
          rescue => e
            trace = e.backtrace.join("\n\t").sub("\n\t", ": #{$ERROR_INFO}#{e.class ? " (#{e.class})" : ''}\n\t")
            logger.error("Threw: for #{file}, #{log_file}, caused #{trace}")
          end
          full_script = "#{script}>>#{log_file} 2>&1"
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
              out = pout.readlines.join("\n") # Not expecting anything in 'out' due to redirection, but...
              pout.close
              pstat.value # N.B. Await process termination
              "Command completed #{pstat.value} and expecting '#{out}' to be empty due to redirects"
            end
            logger.debug(completed)
            # system("lsof #{log_file} >> #{log_file} 2>&1")
            # system("ps -axf | grep '#{pstat[:pid]}\\s' >> #{log_file}")
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
              # system("lsof #{log_file} >> #{log_file}")
              logger.debug("Tried SIGKILL #{pstat[:pid]} - hopefully no processes still have #{log_file}!")
            end
          rescue => e
            logger.debug("Exception #{pstat ? pstat[:pid] : "pstat=#{pstat}=nil"}")
            trace = e.backtrace.join("\n\t").sub("\n\t", ": #{$ERROR_INFO}#{e.class ? " (#{e.class})" : ''}\n\t")
            logger.error("Threw: for #{full_script}, caused #{trace}")
          ensure
            # It's only logging - don't really care if we lose some, though it would be nice if we didn't.
            if log_decoration['worker_block']
              prefix = "#{env['TEST_USER']}-w#{env['WORKER_INDEX']}>"
              block_name = ''
              if log_decoration['start'] || log_decoration['end']
                block_name = "#{prefix} #{desc}"
                prefix = ''
              end
              message = ''
              message << format(log_decoration['start'] + "\n", block_name) if log_decoration['start']
              message << "#{prefix}#{file.readline}" until file.eof
              message << format(log_decoration['end'] + "\n", block_name) if log_decoration['end']
              logger << message
              file.close
            end
          end
          logger.debug("Unusual termination for command: #{script}")
          nil
        end
      end
    end
  end
end
