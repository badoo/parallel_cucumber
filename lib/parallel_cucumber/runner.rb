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
        puts("#{process_number}>> Command: #{cmd}")

        output = IO.popen("#{cmd} 2>&1") do |io|
          puts("#{process_number}>> Pid: #{io.pid}")
          show_output(io, process_number)
          puts("#{process_number}>> Output shown")
        end
        puts("#{process_number}>> Getting status...")
        exit_status = $?.exitstatus

        puts("#{process_number}>> PROCESS COMPLETED")
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
          $stdout.print "#{process_number}>> EOF"
          $stdout.flush
        end
        $stdout.print "#{process_number}>> Returning result"
        result
      end
    end # self
  end # Runner
end # ParallelCucumber
