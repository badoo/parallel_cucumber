require_relative 'hooks'

module ParallelCucumber
  module DSL
    class << self

      # Registers a callback hook which will be called at the end of every batch
      # There can be more than one after_batch, they will be invoked sequentially
      # If one hook fails, rest all will be skipped
      # @yieldparam [optional, Hash] batch_results results of all tests in a batch
      # @yieldparam [optional, String] batch_id batch id
      # @yieldparam [optional, Hash] batch_env env of batch
      def after_batch(&proc)
        Hooks.register_after_batch(proc)
      end
    end
  end
end