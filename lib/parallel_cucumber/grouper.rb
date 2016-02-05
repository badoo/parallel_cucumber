require 'English'
require 'erb'
require 'json'
require 'open3'
require 'tempfile'
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
            "#{feature['uri']}:#{scenario['line']}" if ['Scenario', 'Scenario Outline'].include?(scenario['keyword'])
          end
        end.flatten.compact

        group_creator(group_size, all_runnable_scenarios)
      end

      def generate_dry_run_report(options)
        cucumber_options = options[:cucumber_options]
        cucumber_options = expand_profiles(cucumber_options) unless cucumber_config_file.nil?
        cucumber_options = cucumber_options.gsub(/(--format|-f|--out|-o)\s+[^\s]+/, '')
        result = nil

        Tempfile.open(%w(dry-run .json)) do |f|
          dry_run_options = "--dry-run --format json --out #{f.path}"

          cmd = "cucumber #{cucumber_options} #{dry_run_options} #{options[:cucumber_args].join(' ')}"
          _stdout, stderr, status = Open3.capture3(cmd)
          f.close

          if status != 0
            cmd = "bundle exec #{cmd}" if ENV['BUNDLE_BIN_PATH']
            raise("Can't generate dry run report, command exited with #{status}:\n\t#{cmd}\n\t#{stderr}")
          end

          content = File.read(f.path)

          result = begin
            JSON.parse(content)
          rescue JSON::ParserError
            content = content.length > 1024 ? "#{content[0...1000]} ...[TRUNCATED]..." : content
            raise("Can't parse JSON from dry run:\n#{content}")
          end
        end
        result
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

        tasks.each do |task|
          group = groups.min_by(&:size)
          group.push(task)
        end
        groups.reject(&:empty?).map(&:compact)
      end
    end # class
  end # Grouper
end # ParallelCucumber
