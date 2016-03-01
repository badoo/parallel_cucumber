module ParallelCucumber
  module Helper
    module Command
      class << self
        class Dual
          def initialize(logger, log_file)
            @logger = logger
            @log_file = log_file
          end

          def log(message)
            @logger.debug(message)
            File.open(@log_file, 'a') { |f| f << "\n#{Time.now} #{message}\n\n" }
          end
        end

        def exec_command(env, script, log_file, logger, timeout = 30)
          dual = Dual.new(logger, log_file)
          full_script = "#{script} >>#{log_file} 2>&1"
          message = <<-LOG
        Running command `#{full_script}` with environment variables: #{env.map { |k, v| "#{k}=#{v}" }.join(' ')}
          LOG
          dual.log(message)
          pstat = nil
          pout = nil
          begin
            completed = Timeout.timeout(timeout) do
              pin, pout, pstat = Open3.popen2e(env, full_script)
              dual.log("PID #{pstat[:pid]} for #{full_script[0..25]} ")
              pin.close
              out = pout.readlines.join("\n") # Not expecting anything in 'out' due to redirection, but...
              pout.close
              pstat.value # N.B. Await process termination
              "Command completed with exit #{pstat.value} and output '#{out}'"
            end
            dual.log(completed)
            system("lsof #{log_file} >> #{log_file}")
            system("ps -axf | grep '#{pstat[:pid]}\\s' >> #{log_file}")
            return true if pstat.value.success?

            puts "TAIL OF #{log_file}\n\n#{`tail -20 #{log_file}`}\n\nENDS\n"
            return false
          rescue Timeout::Error
            pout.close
            dual.log("Timeout, so trying SIGINT #{pstat[:pid]}")
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
                dual.log("Survived SIGINT, so trying SIGKILL #{pstat[:pid]}")
                logger.error("Process survived #{wait_sigint}s after SIGINT(2). Trying SIGKILL(9). Fatality!")
                Helper::Processes.kill_tree('SIGKILL', pstat[:pid].to_s, nil, tree)
              end
              logger.debug("About to reap root #{pstat[:pid]}")
              pstat.value # reap root - everything else should be reaped by init.
              logger.debug("Reaped root #{pstat[:pid]}")
              system("lsof #{log_file} >> #{log_file}")
              dual.log("Tried SIGKILL #{pstat[:pid]} - hopefully no processes still have #{log_file}!")
            end
          rescue => e
            dual.log("Exception #{pstat[:pid]}")
            trace = e.backtrace.join("\n\t").sub("\n\t", ": #{$ERROR_INFO}#{e.class ? " (#{e.class})" : ''}\n\t")
            logger.error("Threw: for #{full_script}, caused #{trace}")
          end
          dual.log("Unusual termination for command: #{full_script[0..25]}")
          nil
        end
      end
    end
  end
end
