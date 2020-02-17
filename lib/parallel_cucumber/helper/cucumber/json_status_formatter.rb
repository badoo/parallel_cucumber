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
          details = {status: event.result.to_sym}
          if event.result.respond_to?(:exception)
            details[:exception_classname] = event.result.exception.class
            details[:exception_message] = event.result.exception.message
          end
          details[:finish_time] = Time.now.to_i
          @result[event.test_case.location.to_s] = details
        end

        def on_finished_testing(*)
          @io.write(@result.to_json)
        end
      end
    end
  end
end

