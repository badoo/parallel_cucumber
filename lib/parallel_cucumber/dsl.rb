require_relative 'hooks'

module ParallelCucumber
  module DSL
    class << self
      # Registers a callback hook which will be called before every batch
      # There can be more than one after_batch, they will be invoked sequentially
      # If one hook fails, the rest hooks will be skipped
      # @yieldparam [optional, Array] tests list of tests to run
      # @yieldparam [optional, String] batch_id batch id
      # @yieldparam [optional, Hash] batch_env env of batch
      def before_batch(&proc)
        Hooks.register_before_batch(proc)
      end

      # Registers a callback hook which will be called at the end of every batch
      # There can be more than one after_batch, they will be invoked sequentially
      # If one hook fails, the rest hooks will be skipped
      # @yieldparam [optional, Hash] batch_results results of all tests in a batch
      # @yieldparam [optional, String] batch_id batch id
      # @yieldparam [optional, Hash] batch_env env of batch
      def after_batch(&proc)
        Hooks.register_after_batch(proc)
      end

      def before_workers(&proc)
        Hooks.register_before_workers(proc)
      end

      def after_workers(&proc)
        Hooks.register_after_workers(proc)
      end

      def on_batch_error(&proc)
        Hooks.register_on_batch_error(proc)
      end
    end
  end
end
