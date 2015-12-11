require 'optparse'

module ParallelCucumber
  module Cli
    class << self
      DEFAULTS = {
        n: 1,
        thread_delay: 0,
      }

      def run(argv)
        options = parse_options!(argv)

        ParallelCucumber.run_tests_in_parallel(options)
      end

      private

      def parse_options!(argv)
        options = DEFAULTS.dup

        option_parser = OptionParser.new do |opts|
          opts.banner = [
            'Usage: parallel_cucumber [options] [ [FILE|DIR|URL][:LINE[:LINE]*] ]',
            'Example: parallel_cucumber ... '
          ].join("\n")
          opts.on('-h', '--help', 'Show this') do
            puts opts
            exit 0
          end
          opts.on('-v', '--version', 'Show version') do
            puts ParallelCucumber::VERSION
            exit 0
          end
          opts.on('-o', '--cucumber-options "[OPTIONS]"', 'Run cucumber with these options') do |cucumber_options|
            options[:cucumber_options] = cucumber_options
          end
          opts.on('--thread-delay "[SECONDS]"', Integer, 'Delay before next thread starting') do |thread_delay|
            options[:thread_delay] = thread_delay
          end
          opts.on('-n [PROCESSES]', Integer, 'How many processes to use') { |n| options[:n] = n }

          opts.on('--workaround-for-profile-with-reporters "[OPTIONS]"') do |profile_with_reporters|
            options[:profile_with_reporters] = profile_with_reporters
          end
        end

        option_parser.parse!(argv)
        options[:cucumber_args] = argv

        options
      rescue OptionParser::InvalidOption => e
        puts "Unknown option #{e}"
        puts option_parser.help
        exit 1
      end
    end # self
  end # Cli
end # ParallelCucumber
