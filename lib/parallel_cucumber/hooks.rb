module ParallelCucumber
  class Hooks

    @@after_batch_hooks ||= []

    class << self

      def after_batch(&proc)
        @@after_batch_hooks << proc
      end

      def fire_after_batch_hooks(*args)
        @@after_batch_hooks.each do |hook|
          hook.call(*args)
        end
      end

    end
  end
end