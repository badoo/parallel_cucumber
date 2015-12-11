require 'fileutils'
require 'find'

module ParallelCucumber
  module Runner
    class << self
      def run_tests(cucumber_args, process_number, options)
        cmd = command_for_test(process_number, options[:cucumber_options], cucumber_args, options[:thread_delay])
        execute_command_for_process(process_number, cmd)
      end

      private

      def command_for_test(process_number, cucumber_options, cucumber_args, thread_delay)
        cmd = ['cucumber', cucumber_options, *cucumber_args].compact * ' '
        env = {
          AUTOTEST: 1,
          TEST_PROCESS_NUMBER: process_number
        }
        exports = env.map { |k, v| "#{k}=#{v}" }.join(' ')

        sleep = thread_delay > 0 ? "sleep #{thread_delay * process_number}; " : ''

        "#{sleep}#{exports} #{cmd}"
      end

      def execute_command_for_process(process_number, cmd)
        print_chevron_msg(process_number, "Command: #{cmd}")

        begin
          output = IO.popen("#{cmd} 2>&1 | tee thread_#{process_number}.log") do |io|
            print_chevron_msg(process_number, "Pid: #{io.pid}")
            show_output(io, process_number)
          end
        ensure
          exit_status = $?.exitstatus
          print_chevron_msg(process_number, "Exited with status #{exit_status}")
        end

        { stdout: output, exit_status: exit_status }
      end

      def print_chevron_msg(chevron, line, io=$stdout)
        msg = "#{chevron}> #{line}\n"
        io.print(msg)
        io.flush
      end

      def show_output(io, process_number)
        remaining_part = ''
        probable_finish = false
        begin
          loop do
            text_block = remaining_part + io.read_nonblock(32 * 1024)
            lines = text_block.split("\n")
            remaining_part = lines.pop
            probable_finish = last_cucumber_line?(remaining_part)
            lines.each do |line|
              probable_finish = true if last_cucumber_line?(line)
              print_chevron_msg(process_number, line)
            end
          end
        rescue IO::WaitReadable
          timeout = probable_finish ? 10 : 1800
          result = IO.select([io], [], [], timeout)
          if result.nil?
            if probable_finish
              print_chevron_msg(process_number, "Timeout reached in #{timeout}s, but process has probably finished", $stderr)
            else
              raise("Read timeout has reached for process #{process_number}. There is no output in #{timeout}s")
            end
          else
            retry
          end
        rescue EOFError
        ensure
          print_chevron_msg(process_number, remaining_part)
        end
      end

      def last_cucumber_line?(line)
        !(line =~ /\d+m[\d\.]+s/).nil?
      end
    end # self
  end # Runner
end # ParallelCucumber
