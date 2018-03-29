module ParallelCucumber
  class Hooks
    @before_batch_hooks ||= []
    @after_batch_hooks ||= []

    class << self
      def register_before_batch(proc)
        raise(ArgumentError, 'Please provide a valid callback') unless proc.respond_to?(:call)
        @before_batch_hooks << proc
      end

      def register_after_batch(proc)
        raise(ArgumentError, 'Please provide a valid callback') unless proc.respond_to?(:call)
        @after_batch_hooks << proc
      end

      def fire_before_batch_hooks(*args)
        @before_batch_hooks.each do |hook|
          hook.call(*args)
        end
      end

      def fire_after_batch_hooks(*args)
        @after_batch_hooks.each do |hook|
          hook.call(*args)
        end
      end
    end
  end
end
