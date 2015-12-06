module ParallelCucumber
  class ResultFormatter
    class << self
      def report_results(test_results)
        results = find_results(test_results.map { |result| result[:stdout] }.join(''))
        puts ''
        puts summarize_results(results)
      end

      def find_results(test_output)
        test_output.split("\n").map do |line|
          line.gsub!(/\e\[\d+m/, '')
          next unless line_is_result?(line)
          line
        end.compact
      end

      def line_is_result?(line)
        line =~ scenario_or_step_result_regex || line =~ failing_scenario_regex
      end

      def summarize_results(results)
        output = ["\n\n************ FINAL SUMMARY ************"]

        failing_scenarios = results.grep(failing_scenario_regex)
        if failing_scenarios.any?
          failing_scenarios.unshift('Failing Scenarios:')
          output << failing_scenarios.join("\n")
        end

        output << summary(results)

        output.join("\n\n")
      end

      def summary(results)
        sort_order = %w(scenario step failed undefined skipped pending passed)

        %w(scenario step).map do |group|
          group_results = results.grep(/^\d+ #{group}/)
          next if group_results.empty?

          sums = sum_up_results(group_results)
          sums = sums.sort_by { |word, _| sort_order.index(word) || 999 }
          sums.map! do |word, number|
            plural = 's' if word == group && number != 1
            "#{number} #{word}#{plural}"
          end
          "#{sums[0]} (#{sums[1..-1].join(', ')})"
        end.compact.join("\n")
      end

      def sum_up_results(results)
        results = results.join(' ').gsub(/s\b/, '') # combine and singularize results
        counts = results.scan(/(\d+) (\w+)/)
        counts.each_with_object(Hash.new(0)) do |(number, word), sum|
          sum[word] += number.to_i
        end
      end

      private

      def scenario_or_step_result_regex
        /^\d+ (steps?|scenarios?)/
      end

      def failing_scenario_regex
        /^cucumber .*features\/.+:\d+/
      end
    end # self
  end # ResultFormatter
end # ParallelCucumber
