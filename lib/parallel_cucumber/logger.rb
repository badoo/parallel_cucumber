require 'logger'

module ParallelCucumber
  class CustomLogger < Logger
    private

    def format_message(severity, datetime, progname, msg)
      if @level == DEBUG
        "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}]\t#{progname}\t#{severity}\t#{msg.gsub(/\s+/, ' ').strip}\n"
      else
        "#{progname}\t#{msg.gsub(/\s+/, ' ').strip}\n"
      end
    end
  end
end
