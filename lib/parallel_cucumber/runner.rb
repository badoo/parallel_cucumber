require 'fileutils'
require 'find'

module ParallelCucumber
  module Runner
    class << self
      def execute_command_for_process(process_number, cmd)
        output = open("|#{cmd} 2>&1", 'r') { |stdout| show_output(stdout, process_number) }
        exit_status = $?.exitstatus

        puts "\n****** PROCESS #{process_number} COMPLETED ******\n\n"
        { stdout: output, exit_status: exit_status }
      end

      def show_output(stream, process_number)
        result = ''
        begin
          loop do
            begin
              read = stream.readline
              $stdout.print "#{process_number}> #{read}"
              $stdout.flush
              result << read
            end
          end
        rescue EOFError
        end
        result
      end

      def run_tests(test_files, process_number, options)
        cmd = command_for_test(process_number, "#{options[:cucumber_options]}", test_files)
        $stdout.print("#{process_number}> Command: #{cmd}\n")
        $stdout.flush
        execute_command_for_process(process_number, cmd)
      end

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
    end # self
  end # Runner
end # ParallelCucumber
