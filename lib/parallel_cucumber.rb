require 'parallel'

require 'parallel_cucumber/cli'
require 'parallel_cucumber/feature_grouper'
require 'parallel_cucumber/result_formatter'
require 'parallel_cucumber/runner'
require 'parallel_cucumber/version'

module ParallelCucumber
  class << self
    def run_tests_in_parallel(options)
      number_of_processes = options[:n]
      test_results = nil

      report_time_taken do
        groups = FeatureGrouper.feature_groups(options, number_of_processes)
        threads = groups.size
        completed = []

        on_finish = lambda do |_item, index, _result|
          completed.push(index)
          remaining_threads = ((0..threads - 1).to_a - completed).sort
          puts "Thread #{index} has finished. Remaining(#{remaining_threads.count}): #{remaining_threads.join(', ')}"
        end

        test_results = Parallel.map_with_index(
          groups,
          in_threads: threads,
          finish: on_finish
        ) do |group, index|
          Runner.run_tests(group, index, options)
        end
        puts 'All threads are complete'
        ResultFormatter.report_results(test_results)
      end
      exit(1) if any_test_failed?(test_results)
    end

    def any_test_failed?(test_results)
      test_results.any? { |result| result[:exit_status] != 0 }
    end

    def report_time_taken
      start = Time.now
      yield
      time_in_sec = Time.now - start
      mm, ss = time_in_sec.divmod(60)
      puts "\nTook #{mm} Minutes, #{ss.round(2)} Seconds"
    end
  end # self
end # ParallelCucumber
