require 'json'
require 'optparse'
require 'date'

module ParallelCucumber
  class Cli
    DEFAULTS = {
      batch_size: 1,
      batch_timeout: 600,
      setup_timeout: 30,
      precheck_timeout: 30,
      batch_error_timeout: 30,
      cucumber_options: '',
      debug: false,
      directed_tests: {},
      log_dir: '.',
      log_decoration: {},
      env_variables: {},
      n: 0, # Default: computed from longest list in json parameters, minimum 1.
      queue_connection_params: ['redis://127.0.0.1:6379', DateTime.now.strftime('queue-%Y%m%d%H%M%S')],
      worker_delay: 0,
      test_command: 'cucumber'
    }.freeze

    def initialize(argv)
      @argv = argv
      @logger = ParallelCucumber::CustomLogger.new(STDOUT)
      @logger.progname = 'CLI'
      @logger.level = if @argv.include?('--debug')
                        ParallelCucumber::CustomLogger::DEBUG
                      else
                        ParallelCucumber::CustomLogger::INFO
                      end
    end

    def run
      options = parse_options!(@argv)
      message = <<-LOG
          Running parallel_cucumber with options: #{options.map { |k, v| "#{k}=#{v}" }.join(', ')}
      LOG
      @logger.debug(message)
      ParallelCucumber::Main.new(options).run
    end

    private

    def parse_options!(argv)
      options = DEFAULTS.dup

      option_parser = OptionParser.new do |opts|
        opts.banner = [
          'Usage: parallel_cucumber [options] [ [FILE|DIR|URL][:LINE[:LINE]*] ]',
          'Example: parallel_cucumber -n 4 -o "-f pretty -f html -o report.html" examples/i18n/en/features'
        ].join("\n")

        opts.on('-n WORKERS', Integer, 'How many workers to use. Default is 1 or longest list in -e') do |n|
          if n < 1
            puts "The minimum number of processes is 1 but given: '#{n}'"
            exit 1
          end
          options[:n] = n
        end

        opts.on('-o', '--cucumber-options "OPTIONS"', 'Run cucumber with these options') do |cucumber_options|
          options[:cucumber_options] = cucumber_options
        end

        opts.on('-r', '--require "file_path"', 'Load files for parallel_cucumber') do |load_file|
          raise(ArgumentError, "No such file to load: #{load_file}") unless File.exist?(load_file)
          options[:load_files] ||= []
          options[:load_files] << load_file
        end

        opts.on('--directed-tests JSON', 'Direct tests to specific workers, e.g. {"0": "-t @head"}') do |json|
          options[:directed_tests] = begin
            JSON.parse(json)
          rescue JSON::ParserError
            puts 'Log block quoting not in JSON format. Did you forget to escape the quotes?'
            raise
          end
        end

        opts.on('--test-command COMMAND',
                "Command to run for test phase, default #{DEFAULTS[:test_command]}") do |test_command|
          options[:test_command] = test_command
        end

        opts.on('--pre-batch-check COMMAND', 'Command causing worker to quit on exit failure') do |pre_check|
          options[:pre_check] = pre_check
        end

        opts.on('--log-dir DIR', 'Directory for worker logfiles') do |log_dir|
          options[:log_dir] = log_dir
        end

        opts.on('--log-decoration JSON', 'Block quoting for logs, e.g. {start: "#start %s", end: "#end %s"}') do |json|
          options[:log_decoration] = begin
            JSON.parse(json)
          rescue JSON::ParserError
            puts 'Log block quoting not in JSON format. Did you forget to escape the quotes?'
            raise
          end
        end

        opts.on('--summary JSON', 'Summary files, e.g. {failed: "./failed.txt", unknown: "./unknown.txt"}') do |json|
          options[:summary] = begin
            JSON.parse(json)
          rescue JSON::ParserError
            puts 'Log block quoting not in JSON format. Did you forget to escape the quotes?'
            raise
          end
        end

        opts.on('-e', '--env-variables JSON', 'Set additional environment variables to processes') do |env_vars|
          options[:env_variables] = begin
            JSON.parse(env_vars)
          rescue JSON::ParserError
            puts 'Additional environment variables not in JSON format. Did you forget to escape the quotes?'
            raise
          end
        end

        help_message = "How many tests each worker takes from queue at once. Default is #{DEFAULTS[:batch_size]}"
        opts.on('--batch-size SIZE', Integer, help_message) do |batch_size|
          if batch_size < 1
            puts "The minimum batch size is 1 but given: '#{batch_size}'"
            exit 1
          end
          options[:batch_size] = batch_size
        end

        opts.on('--group-by ENV_VAR', 'Key for cumulative report') do |group_by|
          options[:group_by] = group_by
        end

        help_message = <<-TEXT.gsub(/\s+/, ' ').strip
         `url,name`
          Url for TCP connection:
          `redis://[password]@[hostname]:[port]/[db]` (password, port and database are optional),
          for unix socket connection: `unix://[path to Redis socket]`.
          Default is redis://127.0.0.1:6379 and name is `queue`
        TEXT
        opts.on('-q', '--queue-connection-params ARRAY', Array, help_message) do |params|
          options[:queue_connection_params] = params
        end

        opts.on('--setup-worker SCRIPT', 'Execute SCRIPT before each worker') do |script|
          options[:setup_worker] = script
        end

        opts.on('--teardown-worker SCRIPT', 'Execute SCRIPT after each worker') do |script|
          options[:teardown_worker] = script
        end

        help_message = <<-TEXT.gsub(/\s+/, ' ').strip
          Delay before next worker starting.
          Could be used for avoiding 'spikes' in CPU and RAM usage
          Default is #{DEFAULTS[:worker_delay]}
        TEXT
        opts.on('--worker-delay SECONDS', Float, help_message) do |worker_delay|
          options[:worker_delay] = worker_delay
        end

        help_message = <<-TEXT.gsub(/\s+/, ' ').strip
          Timeout for each batch of tests. Default is #{DEFAULTS[:batch_timeout]}
        TEXT
        opts.on('--batch-timeout SECONDS', Float, help_message) do |batch_timeout|
          options[:batch_timeout] = batch_timeout
        end

        help_message = <<-TEXT.gsub(/\s+/, ' ').strip
          Timeout for each test precheck. Default is #{DEFAULTS[:batch_timeout]}
        TEXT
        opts.on('--precheck-timeout SECONDS', Float, help_message) do |timeout|
          options[:precheck_timeout] = timeout
        end

        help_message = <<-TEXT.gsub(/\s+/, ' ').strip
          Timeout for each batch_error script. Default is #{DEFAULTS[:batch_error_timeout]}
        TEXT
        opts.on('--batch-error-timeout SECONDS', Float, help_message) do |timeout|
          options[:batch_error_timeout] = timeout
        end

        help_message = <<-TEXT.gsub(/\s+/, ' ').strip
          Timeout for each worker's set-up phase. Default is #{DEFAULTS[:setup_timeout]}
        TEXT
        opts.on('--setup-timeout SECONDS', Float, help_message) do |setup_timeout|
          options[:setup_timeout] = setup_timeout
        end

        opts.on('--debug', 'Print more debug information') do |debug|
          options[:debug] = debug
        end

        help_message = 'Cucumber arguments for long-running-tests'
        opts.on('--long-running-tests STRING', String, help_message) do |cucumber_long_run_args|
          options[:long_running_tests] = cucumber_long_run_args
        end

        opts.on('-v', '--version', 'Show version') do
          puts ParallelCucumber::VERSION
          exit 0
        end

        opts.on('-h', '--help', 'Show this') do
          puts opts
          exit 0
        end
      end

      option_parser.parse!(argv)
      options[:cucumber_args] = argv.join(' ')

      options
    rescue OptionParser::InvalidOption => e
      puts "Unknown option #{e}"
      puts option_parser.help
      exit 1
    end
  end
end
