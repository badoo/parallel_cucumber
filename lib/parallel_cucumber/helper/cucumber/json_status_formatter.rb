# frozen_string_literal: true

require 'cucumber/formatter/io'
require 'cucumber/formatter/ast_lookup'

module ParallelCucumber
  module Helper
    module Cucumber
      class JsonStatusFormatter
        include ::Cucumber::Formatter::Io

        def initialize(config)
          config.on_event :test_case_finished, &method(:on_test_case_finished)
          config.on_event :test_run_finished, &method(:on_test_run_finished)

          @io     = ensure_io(config.out_stream, nil)
          @result = {}
        end

        def on_test_case_finished(event)
          details = { status: event.result.to_sym }

          if event.result.respond_to?(:exception)
            details[:exception_classname] = event.result.exception.class.to_s
            details[:exception_message]   = event.result.exception.message
          end

          feature_name = read_feature_name(event.test_case.location.file)

          details[:name]        = "#{feature_name}: #{event.test_case.name}"
          details[:finish_time] = Time.now.to_i
          location              = "#{event.test_case.location.file}:#{event.test_case.location.line}"
          @result[location]     = details
        end

        def on_test_run_finished(*)
          @io.write(@result.to_json)
        end

        private

        def read_feature_name(file_path)
          File.readlines(file_path)
              .grep(/Feature:/)
              .first
              .split('Feature:')
              .last
              .strip
        rescue StandardError => e
          puts("Failed to get feature name from file #{file_path}. #{e.class} #{e.message} #{e.backtrace.join("\n")}")

          'unknown_feature_name'
        end
      end
    end
  end
end
