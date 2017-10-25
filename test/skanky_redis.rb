require 'socket'

# Crappy REDIS for the Linux agents, to avoid having to install redis everywhere.
# Would have been better had I realised the manual mode wasn't the standard.

# ADD TO YOUR TC BUILD:
#
#        build.sdk = iphonesimulator --queue-connection-params redis://localhost:6379,skanky
#  -- or --
#        --obfuscate --queue_connection=redis://localhost:6379,skanky
#  == AND ==
#        env.LC_ALL	en_US.UTF-8

class SkankyRedis
  def initialize
    @db = {}
    @db_mutex = Mutex.new
    @server = nil
  end

  def stop
    @server.close if @server
    @server = nil
  end

  # rubocop:disable Style/PerlBackrefs
  def start(port = 0)
    @server = TCPServer.new('127.0.0.1', port) # Default is normally 6379
    @port = @server.addr[1]
    Thread.start do
      puts "Starting hacky redis server on #{@port}"
      loop do
        Thread.start(@server.accept) do |client|
          begin
            # puts "new #{client}"
            while client && (line = client.gets)
              line.chomp!
              if line =~ /^\*(\d+)$/
                array = []
                array_len = $1.to_i
                # puts "Array[#{$1} = #{array_len}]"
                array_len.times do
                  line = client.gets.chomp
                  length = line[1..-1].to_i
                  # puts "A[#{array.size}]=#{line}=#{line[1..-1]} = #{length}"
                  data = ''
                  while data.size < length
                    line = client.gets
                    data += line
                  end
                  array << data.chomp
                end
                line = array.join(' ')
                # puts array, line
              end

              begin
                # puts "Respond to #{line}"
                response =
                  case line.chomp
                  when /^(?i)llen\s+(\S+)$/
                    llen($1)
                  when /^(?i)rpop\s+(\S+)$/
                    rpop($1)
                  when /^(?i)lpush\s+(\S+)\s+(.*)$/
                    lpush($1, $2)
                  when /^quit/
                    client.close
                    client = nil
                    break
                  else
                    "-Don't know #{line.chomp}"
                  end
              rescue => e
                response = "Threw: #{e}"
              end
              # puts "Skanky : #{response}"
              client.puts("#{response}\r") unless response.empty?
              client.flush if client
            end
            client.close if client
          rescue StandardError => e
            puts e, caller
          end
        end
        # puts "lost #{client}"
      end
    end
    "redis://127.0.0.1:#{@port},skanky"
  end

  def lpush(k, vv)
    @db_mutex.synchronize do
      vv.split(' ').each do |v|
        (@db[k] ||= []).push(v =~ /^("?)(.*)\1$/ ? "$#{$2.length}\r\n#{$2}" : v)
      end
      ":#{@db.fetch(k, []).size}"
    end
  end

  def rpop(k)
    @db_mutex.synchronize do
      l = @db.fetch(k, [])
      l.empty? ? '$-1' : l.shift
    end
  end

  def llen(k)
    @db_mutex.synchronize do
      ":#{@db.fetch(k, []).size}"
    end
  end
end

# SkankyRedis.new.start
# ruby -e 'require_relative "rake/skanky_redis"; SkankyRedis.new.start; sleep 60*60' &
# parallel_cucumber ... --queue-connection-params redis://127.0.0.1:poooort,skanky
