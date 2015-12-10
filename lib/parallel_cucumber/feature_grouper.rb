require 'json'

module ParallelCucumber
  class FeatureGrouper
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
                  if examples_count > 0
                    {
                      line: "#{feature['uri']}:#{example['line']}",
                      weight: examples_count
                    }
                  end
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
        cucumber_options = options[:cucumber_options].gsub(/(--format|-f|--output|-o)\s+[^\s]+/, '')
        unless options[:profile_with_reporters].nil?
          profile_with_reporters = options[:profile_with_reporters]
          cucumber_options = cucumber_options.gsub(/(--profile|-p)\s+#{profile_with_reporters}(\s+|$)/, '')
        end

        cmd = "cucumber #{cucumber_options} --dry-run --format json #{options[:cucumber_args].join(' ')}"
        dry_run_report = `#{cmd} 2>/dev/null`
        exit_status = $?.exitstatus
        if exit_status != 0 || dry_run_report.empty?
          cmd = "bundle exec #{cmd}" if ENV['BUNDLE_BIN_PATH']
          fail("Can't generate dry run report, command exited with #{exit_status}:\n\t#{cmd}")
        end

        begin
          JSON.parse(dry_run_report)
        rescue JSON::ParserError
          dry_run_report = "#{dry_run_report[0..1020]}…" if dry_run_report.length > 1024
          raise("Can't parse JSON from dry run:\n#{dry_run_report}")
        end
      end

      def group_creator(groups_count, tasks)
        groups = Array.new(groups_count) { [] }

        sorted_tasks = tasks.sort { |t1, t2| t2[:weight] <=> t1[:weight] }
        sorted_tasks.each do |task|
          group = groups.min_by { |group| group.size }
          group.push(task[:line], *Array.new(task[:weight] - 1))
        end
        groups.reject(&:empty?).map(&:compact)
      end
    end # self
  end # FeatureGrouper
end # ParallelCucumber
