# http://stackoverflow.com/questions/6407141/how-can-i-have-ruby-logger-log-output-to-stdout-as-well-as-file
# answered Jun 20 '11 at 11:03 jonas054

class MultiDelegator
  def initialize(*targets)
    @targets = targets
  end

  def self.delegate(*methods)
    methods.each do |m|
      define_method(m) do |*args|
        @targets.map { |t| t.send(m, *args) }
      end
    end
    self
  end

  class <<self
    alias to new
  end
end

# log_file = File.open("debug.log", "a")
# log = Logger.new MultiDelegator.delegate(:write, :close).to(STDOUT, log_file)
