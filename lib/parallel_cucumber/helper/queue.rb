require 'redis'

module ParallelCucumber
  module Helper
    class Queue
      attr_reader :name

      def initialize(redis, queue_name)
        @redis = redis
        @name = queue_name
      end

      def enqueue(elements)
        @redis.lpush(@name, elements) unless elements.empty?
      end

      def dequeue
        @redis.rpop(@name)
      end

      def length
        @redis.llen(@name)
      end

      def empty?
        length.zero?
      end
    end
  end
end
