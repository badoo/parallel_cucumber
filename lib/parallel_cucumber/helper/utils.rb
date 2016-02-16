module ParallelCucumber
  module Helper
    module Utils
      def time_it
        t1 = Time.now
        yield
        t2 = Time.now
        mm, ss = (t2 - t1).divmod(60)
        [mm, ss.round(1)]
      end
    end
  end
end
