module ParallelCucumber
  class Hooks
    @before_batch_hooks ||= []
    @after_batch_hooks  ||= []
    @before_workers     ||= []
    @after_workers      ||= []
    @on_batch_error     ||= []

    class << self
      def register_before_batch(proc)
        raise(ArgumentError, 'Please provide a valid callback') unless proc.respond_to?(:call)
        @before_batch_hooks << proc
      end

      def register_after_batch(proc)
        raise(ArgumentError, 'Please provide a valid callback') unless proc.respond_to?(:call)
        @after_batch_hooks << proc
      end

      def register_before_workers(proc)
        raise(ArgumentError, 'Please provide a valid callback') unless proc.respond_to?(:call)
        @before_workers << proc
      end

      def register_after_workers(proc)
        raise(ArgumentError, 'Please provide a valid callback') unless proc.respond_to?(:call)
        @after_workers << proc
      end

      def register_on_batch_error(proc)
        raise(ArgumentError, 'Please provide a valid callback') unless proc.respond_to?(:call)
        @on_batch_error << proc
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

      def fire_before_workers(*args)
        @before_workers.each do |hook|
          hook.call(*args)
        end
      end

      def fire_after_workers(*args)
        @after_workers.each do |hook|
          hook.call(*args)
        end
      end

      def fire_on_batch_error(*args)
        @on_batch_error.each do |hook|
          hook.call(*args)
        end
      end
    end
  end
end
