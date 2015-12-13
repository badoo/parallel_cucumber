require 'English'
require 'erb'
require 'json'
require 'yaml'

module ParallelCucumber
  class Grouper
    class << self
      def feature_groups(options, group_size)
        scenario_groups(group_size, options)
      end

      private

      def scenario_groups(group_size, options)
        distribution_data = generate_dry_run_report(options)
        all_runnable_scenarios = distribution_data.map do |feature|
          next if feature['elements'].nil?
          feature['elements'].map do |scenario|
            if scenario['keyword'] == 'Scenario'
              {
                line: "#{feature['uri']}:#{scenario['line']}",
                weight: 1
              }
            elsif scenario['keyword'] == 'Scenario Outline'
              if scenario['examples']
                scenario['examples'].map do |example|
                  examples_count = example['rows'].count - 1 # Do not count the first row with column names
                  next unless examples_count > 0
                  {
                    line: "#{feature['uri']}:#{example['line']}",
                    weight: examples_count
                  }
                end
              else # Cucumber 1.3 with -x/--expand or Cucumber > 2.0
                {
                  line: "#{feature['uri']}:#{scenario['line']}",
                  weight: 1
                }
              end
            end
          end
        end.flatten.compact
        group_creator(group_size, all_runnable_scenarios)
      end

      def generate_dry_run_report(options)
        cucumber_options = options[:cucumber_options]
        cucumber_options = expand_profiles(cucumber_options) unless cucumber_config_file.nil?
        cucumber_options = cucumber_options.gsub(/(--format|-f|--out|-o)\s+[^\s]+/, '')

        cmd = "cucumber #{cucumber_options} --dry-run --format json #{options[:cucumber_args].join(' ')}"
        dry_run_report = `#{cmd} 2>/dev/null`
        exit_status = $CHILD_STATUS.exitstatus
        if exit_status != 0 || dry_run_report.empty?
          cmd = "bundle exec #{cmd}" if ENV['BUNDLE_BIN_PATH']
          fail("Can't generate dry run report, command exited with #{exit_status}:\n\t#{cmd}")
        end

        begin
          JSON.parse(dry_run_report)
        rescue JSON::ParserError
          stdout = dry_run_report.length > 1024 ? "#{dry_run_report[0...1000]} ...[TRUNCATED]..." : dry_run_report
          raise("Can't parse JSON from dry run:\n#{stdout}")
        end
      end

      def cucumber_config_file
        Dir.glob('{,.config/,config/}cucumber{.yml,.yaml}').first
      end

      def expand_profiles(cucumber_options)
        config = YAML.load(ERB.new(File.read(cucumber_config_file)).result)
        _expand_profiles(cucumber_options, config)
      end

      def _expand_profiles(options, config)
        expand_next = false
        options.split.map do |option|
          case
          when %w(-p --profile).include?(option)
            expand_next = true
            next
          when expand_next
            expand_next = false
            _expand_profiles(config[option], config)
          else
            option
          end
        end.compact.join(' ')
      end

      def group_creator(groups_count, tasks)
        groups = Array.new(groups_count) { [] }

        sorted_tasks = tasks.sort { |t1, t2| t2[:weight] <=> t1[:weight] }
        sorted_tasks.each do |task|
          group = groups.min_by(&:size)
          group.push(task[:line], *Array.new(task[:weight] - 1))
        end
        groups.reject(&:empty?).map(&:compact)
      end
    end # class
  end # Grouper
end # ParallelCucumber
