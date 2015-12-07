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

      def show_output(io, process_number)
        remaining_part = ''
        probable_finish = false
        begin
          loop do
            probable_finish = false
            text_block = remaining_part + io.read_nonblock(32 * 1024)
            lines = text_block.split("\n")
            remaining_part = lines.pop
            lines.each do |line|
              probable_finish = true unless (line =~ /\d+m[\d\.]+s/).nil?
              $stdout.print("#{process_number}>#{line}\n")
              $stdout.flush
            end
          end
        rescue IO::WaitReadable
          timeout = probable_finish ? 10 : 300
          IO.select([io], [], [], timeout)
          retry
        rescue EOFError
        ensure
          $stdout.print("#{process_number}>#{remaining_part}\n")
          $stdout.flush
        end

      end
    end # self
  end # Runner
end # ParallelCucumber
