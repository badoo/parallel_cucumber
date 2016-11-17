require 'redis'

module ParallelCucumber
  module Helper
    class Queue
      attr_reader :name

      def initialize(queue_connection_params)
        # queue_connection_params:
        #   `url--[name]`
        # url:
        #   TCP connection: `redis://[password]@[hostname]:[port]/[db]` (password, port and database are optional),
        #   unix socket connection: `unix://[path to Redis socket]`.
        # name:
        #   queue name, default is `queue`
        url, name = queue_connection_params
        @redis = Redis.new(url: url)
        @name = name
      end

      def enqueue(elements)
        @redis.lpush(@name, elements)
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
