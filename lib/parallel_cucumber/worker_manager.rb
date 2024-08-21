module ParallelCucumber
  class WorkerManager
    def initialize(options, logger, redis, default_queue_name)
      @options = options
      @batch_size = options[:batch_size]
      @logger = logger
      @backlog = ParallelCucumber::Helper::Queue.new(redis, default_queue_name)
      @queue_tracker = Tracker.new(@backlog)
      @back_up_worker_size = options[:backup_worker_count]
      @directed_queues = Hash.new do |hash, key|
        hash[key] = ParallelCucumber::Helper::Queue.new(redis, "#{default_queue_name}_#{key}")
      end
      @workers = {}
      @unchecked_workers = ::Thread::Queue.new
      @healthy_workers = ::Thread::Queue.new
    end

    def start(number_of_workers)
      create_workers(number_of_workers)
      start_managing
      start_workers
    end

    def kill
      @current_thread.kill
    end

    def inform_healthy(worker)
      @healthy_workers.enq(worker)
    end

    def inform_idle(worker)
      @unchecked_workers.enq(worker)
    end

    private

    def create_workers(number_of_workers)
      number_of_workers.times do |index|
        @workers["W#{index}"] =
          ParallelCucumber::Worker.new(options: @options, index: index, stdout_logger: @logger, manager: self)
      end
    end

    def start_managing
      @current_thread = Thread.start do
        loop do
          if !@backlog.empty?
            pre_check_unchecked_workers
            give_job_to_healthy_worker
          elsif any_worker_busy?
            kill_surplus_workers
          else
            break
          end
          sleep 0.5
        end
      rescue StandardError => e
        puts "There was a FATAL ERROR with worker manager. #{e}"
        raise e
      ensure
        kill_all_workers
      end
    end

    def start_workers
      indices = (0...@workers.size).to_a
      @results = Parallel.map(indices.dup, in_threads: @workers.size,
                              finish: ->(_, ix, _) { @logger.synch { |l| l.info("Finished: #{ix} remaining: #{indices -= [ix]}") } }) do |index|
        puts "Starting W#{index}"
        @workers["W#{index}"].start(env_for_worker(@options[:env_variables], index))
      end
      @results.inject do |seed, result|
        seed.merge(result) do |_key, oldval, newval|
          if oldval[:finish_time].nil? && newval[:finish_time].nil?
            @logger.warn('Both oldval finish_time and newval finish_time are empty')
          else
            @logger.info("Picking most recent time of two, newval: #{newval[:finish_time]}, oldval: #{oldval[:finish_time]}")
          end

          new_finish_time = newval.fetch(:finish_time, -1)
          old_finish_time = oldval.fetch(:finish_time, -1)

          if new_finish_time > old_finish_time
            newval
          else
            oldval
          end
        end
      end
    end

    def kill_all_workers
      @logger.info('=== Killing All Workers')
      @workers.values.each { |w| w.assign_job(Job.new(Job::DIE)) }
    end

    def kill_surplus_workers
      until (@unchecked_workers.size + @healthy_workers.size) <= @back_up_worker_size
        queue = !@unchecked_workers.empty? ? @unchecked_workers : @healthy_workers
        worker = queue.pop(true)
        @logger.info("Backup workers more than #{@back_up_worker_size}, killing #{worker}")
        @workers[worker].assign_job(Job.new(Job::DIE))
      end
    end

    def pre_check_unchecked_workers
      while !@unchecked_workers.empty? && worker = @unchecked_workers.pop(false)
        @logger.info("=== #{worker} was asked precheck")
        @workers[worker].assign_job(Job.new(Job::PRECHECK))
      end
    end

    def give_job_to_healthy_worker
      return if @healthy_workers.empty?

      worker_name = @healthy_workers.pop(true)
      worker = @workers[worker_name]
      batch = []
      directed_queue = @directed_queues[worker.index]
      @batch_size.times do
        batch << (directed_queue.empty? ? @backlog : directed_queue).dequeue
      end
      batch.compact!
      @logger.info("=== #{worker_name} was assigned #{batch.count} from the queue (#{@queue_tracker.status}): #{batch.join(' ')}")
      worker.assign_job(Job.new(Job::RUN_TESTS, batch))
    end

    def any_worker_busy?
      @workers.values.any?(&:busy_running_test?)
    end

    def env_for_worker(env_variables, worker_number)
      env = env_variables.map do |k, v|
        case v
        when String, Numeric, TrueClass, FalseClass
          [k, v]
        when Array
          [k, v[worker_number]]
        when Hash
          value = v[worker_number.to_s]
          [k, value] unless value.nil?
        when NilClass
        else
          raise("Don't know how to set '#{v}'<#{v.class}> to the environment variable '#{k}'")
        end
      end.compact.to_h

      # Defaults, if absent in env. Shame 'merge' isn't something non-commutative like 'adopts/defaults'.
      env = { TEST: 1, TEST_PROCESS_NUMBER: worker_number, WORKER_INDEX: worker_number }.merge(env)

      # Overwrite this if it exists in env.
      env.merge(PARALLEL_CUCUMBER_EXPORTS: env.keys.join(',')).map { |k, v| [k.to_s, v.to_s] }.to_h
    end
  end

  class Tracker
    def initialize(queue)
      @backlog = queue
    end

    def status
      queue_length = @backlog.length
      now = Time.now
      @full ||= queue_length
      @start ||= now
      completed = @full - queue_length
      elapsed = now - @start
      estimate = (completed == 0) ? '' : " #{(elapsed * @full / completed).to_i}s est"
      "#{queue_length}/#{@full} left #{elapsed.to_i}s worker#{estimate}"
    end
  end
end
