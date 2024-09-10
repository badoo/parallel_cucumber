require 'logger'

module ParallelCucumber
  class CustomLogger < Logger
    ruby2_keywords def initialize(*)
      super
      @mark = 0
      # Don't want to log half-lines.
      @incomplete_line = nil
      self.level = ::Logger::Severity.coerce(ENV.fetch('LOG_LEVEL', 'INFO'))
      self.formatter = proc do |severity, datetime, progname, msg|
        "#{datetime} #{progname} #{severity} [ParallelCucumber] #{msg}\n"
      end
    end

    def synch
      mutex.synchronize { yield self }
    end

    def update_into(other_logger)
      # TODO: This should write the #teamcity block wrapper: update(other_logger, 'qa-w12> precheck') etc.
      @logdev.dev.fsync # Helpful, but inadequate: a child process might still have buffered stuff.
      other_logger.synch do |l|
        l << File.open(@logdev.filename || @logdev.dev.path) do |f|
          begin
            f.seek(@mark)
            lines = f.readlines
            if @incomplete_line && lines.count > 0
              lines[0] = @incomplete_line + lines[0]
              @incomplete_line = nil
            end
            unless lines.last && lines.last.end_with?("\n", "\r")
              @incomplete_line = lines.pop
            end
            lines.join
          ensure
            @mark = f.tell
          end
        end
      end
    end

    private

    def mutex
      @mutex ||= Mutex.new
    end

    def format_message(severity, datetime, progname, msg)
      "#{datetime}\t#{progname}\t#{severity} [ParallelCucumber] #{msg.gsub(/\s+/, ' ').strip}\n"
    end
  end
end
