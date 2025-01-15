# frozen_string_literal: true

require 'English'
require 'erb'
require 'json'
require 'open3'
require 'tempfile'
require 'yaml'

require_relative '../../helper/cucumber/cucumber_config_provider'

module ParallelCucumber
  module Helper
    module Cucumber
      class << self
        def selected_tests(options, args_string, env)
          puts "ParallelCucumber::Helper::Cucumber selected_tests (#{options.inspect} #{args_string.inspect})"
          dry_run_report = dry_run_report(options, args_string, env)
          puts 'ParallelCucumber::Helper::Cucumber dry_run_report generated'
          scenarios = extract_scenarios(dry_run_report)
          puts("##teamcity[blockOpened name='SelectedScenarios' description='Selected Scenarios']")
          puts "ParallelCucumber::Helper::Cucumber selected scenarios:\n\t\t#{scenarios.join("\n\t\t")}"
          puts("##teamcity[blockClosed name='SelectedScenarios']")

          scenarios
        end

        def extract_scenarios(json_report)
          json = JSON.parse(json_report, symbolize_names: true)

          json.map do |feature|
            scenarios = feature[:elements]
            file      = feature[:uri]
            scenarios.map { |scenario| "#{file}:#{scenario[:line]}" }
          end.flatten
        end

        def parse_json_report(json_report)
          test_results  = JSON.parse(json_report, symbolize_names: true)

          # just conversion of status from string to symbol
          test_results.map do |test_case, test_status|
            test_status[:status] = test_status[:status].to_sym
            [test_case, test_status]
          end.to_h
        end

        def unknown_result(tests)
          res = tests.map do |test|
            [test, { status: :unknown }]
          end
          res.to_h
        end

        private

        def dry_run_report(options, _args_string, env)
          dry_run_env     = env.dup.map { |k, v| [k.to_s, v.to_s] }.to_h # stringify values
          cucumber_config = ::ParallelCucumber::Helper::CucumberConfigProvider.config_from_options(options, dry_run_env)
          cli_helper      = ::ParallelCucumber::Helper::CucumberCliHelper.new(cucumber_config)

          # @type [File] dry_run_report
          dry_run_report = Tempfile.create(%w[dry-run .json])

          command = [
            'bundle exec cucumber',
            '--no-color',
            '--publish-quiet',
            '--dry-run',
            "--format json --out #{dry_run_report.path}",
            cli_helper.excludes.join(' '),
            cli_helper.requires.join(' '),
            cli_helper.tags.join(' '),
            cli_helper.paths.join(' ')
          ].join(' ')

          dry_run_env.merge!(cli_helper.env_vars)

          puts("ParallelCucumber::Helper::Cucumber dry_run_report => #{command}")

          dry_run_contents = nil

          begin
            stdout, stderr, status = Open3.capture3(dry_run_env, command)
            raise(StandardError, "Failed to generate dry-run report: #{stdout} #{stderr}") unless status.success?

            dry_run_contents = File.read(dry_run_report.path)
          ensure
            dry_run_report.close
            File.delete(dry_run_report)
          end

          dry_run_contents
        end
      end
    end
  end
end
