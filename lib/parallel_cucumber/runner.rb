require 'fileutils'
require 'find'

module ParallelCucumber
  module Runner
    class << self
      def run_tests(cucumber_args, process_number, options)
        cmd = command_for_test(process_number, options[:cucumber_options], cucumber_args)
        execute_command_for_process(process_number, cmd)
      end

      private

      def command_for_test(process_number, cucumber_options, cucumber_args)
        cmd = ['cucumber', cucumber_options, *cucumber_args].compact * ' '
        env = {
          AUTOTEST: 1,
          TEST_PROCESS_NUMBER: process_number
        }
        separator = (WINDOWS ? ' & ' : ';')
        exports = env.map { |k, v| WINDOWS ? "(SET \"#{k}=#{v}\")" : "#{k}=#{v};export #{k}" }.join(separator)
        "#{exports}#{separator} #{cmd}"
      end

      def execute_command_for_process(process_number, cmd)
        $stdout.print(chevron_msg(process_number, "Command: #{cmd}"))
        $stdout.flush

        output = IO.popen("#{cmd} 2>&1") do |io|
          $stdout.print(chevron_msg(process_number, "Pid: #{io.pid}"))
          $stdout.flush
          show_output(io, process_number)
        end
        exit_status = $?.exitstatus

        { stdout: output, exit_status: exit_status }
      end

      def chevron_msg(chevron, line)
        "#{Time.new.strftime('%H:%M:%S')} #{chevron}> #{line}\n"
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
              $stdout.print(chevron_msg(process_number, line))
              $stdout.flush
            end
          end
        rescue IO::WaitReadable
          timeout = probable_finish ? 10 : 300
          result = IO.select([io], [], [], timeout)
          if result.nil?
            if probable_finish
              message = chevron_msg(process_number, "Timeout reached in #{timeout}s, but process has probably finished")
              warn(message)
            else
              raise("#{Time.new.strftime('%H:%M:%S')} Read timeout has reached for process #{process_number}. There is no output in #{timeout}s\nRemaining part is: `#{remaining_part}`")
            end
          else
            retry
          end
        rescue EOFError
        ensure
          $stdout.print(chevron_msg(process_number, remaining_part))
          $stdout.flush
        end
      end

      def last_cucumber_line?(line)
        !(line =~ /\d+m[\d\.]+s/).nil?
      end
    end # self
  end # Runner
end # ParallelCucumber
