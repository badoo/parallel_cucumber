require 'json'

module ParallelCucumber
  class FeatureGrouper
    class << self
      def feature_groups(options, group_size)
        scenario_groups(group_size, options)
      end

      private

      def scenario_groups(group_size, options)
        dry_run_report = generate_dry_run_report(options)
        distribution_data = begin
          JSON.parse(dry_run_report)
        rescue JSON::ParserError
          dry_run_report = "#{dry_run_report[0..1020]}…" if dry_run_report.length > 1024
          raise("Can't parse JSON from dry run:\n#{dry_run_report}")
        end
        all_runnable_scenarios = distribution_data.map do |feature|
          next if feature['elements'].nil?
          feature['elements'].map do |scenario|
            if scenario['keyword'] == 'Scenario'
              "#{feature['uri']}:#{scenario['line']}"
            elsif scenario['keyword'] == 'Scenario Outline'
              if scenario['examples']
                scenario['examples'].map do |example|
                  example['rows'].drop(1).map do |row| # Drop the first row with column names
                    "#{feature['uri']}:#{row['line']}"
                  end
                end
              else
                "#{feature['uri']}:#{scenario['line']}" # Cope with --expand
              end
            end
          end
        end.flatten.compact
        group_creator(group_size, all_runnable_scenarios)
      end

      def generate_dry_run_report(options)
        cucumber_options = options[:cucumber_options].gsub(/(--format|-f|--output|-o)\s+[^\s]+/, '')

        cmd = "cucumber #{cucumber_options} --dry-run --format json #{options[:cucumber_args].join(' ')}"
        result = `#{cmd} 2>/dev/null`
        exit_status = $?.exitstatus
        if exit_status != 0 || result.empty?
          cmd = "bundle exec #{cmd}" if ENV['BUNDLE_BIN_PATH']
          fail("Can't generate dry run report, command exited with #{exit_status}:\n\t#{cmd}")
        end
        result
      end

      def group_creator(group_size, items)
        items_per_group = items.size / group_size
        groups = Array.new(group_size) { [] }
        if items_per_group > 0
          groups.each do |group|
            group.push(*items[0..items_per_group - 1])
            items = items.drop(items_per_group)
          end
        end
        unless items.empty?
          items.each_with_index do |item, index|
            groups[index] << item
          end
        end
        groups.reject(&:empty?)
      end
    end # self
  end # FeatureGrouper
end # ParallelCucumber
