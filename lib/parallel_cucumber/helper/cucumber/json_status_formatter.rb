require 'cucumber/formatter/io'

module ParallelCucumber
  module Helper
    module Cucumber
      class JsonStatusFormatter
        include ::Cucumber::Formatter::Io

        def initialize(config)
          config.on_event :after_test_case, &method(:on_after_test_case)
          config.on_event :finished_testing, &method(:on_finished_testing)

          @io     = ensure_io(config.out_stream)
          @result = {}
        end

        def on_after_test_case(event)
          @result[event.test_case.location.to_s] = event.result.to_sym
        end

        def on_finished_testing(*)
          @io.write(@result.to_json)
        end
      end
    end
  end
end

