require 'fluent/plugin/out_forward'

class Fluent::HashForwardOutput < Fluent::ForwardOutput
  Fluent::Plugin.register_output('hash_forward', self)

  # To support log_level option implemented by Fluentd v0.10.43
  unless method_defined?(:log)
    define_method("log") { $log }
  end

  config_param :hash_key_slice, :string, :default => nil
  config_param :keepalive, :bool, :default => false
  config_param :keepalive_time, :time, :default => nil # infinite

  def configure(conf)
    super
    if @hash_key_slice
      lindex, rindex = @hash_key_slice.split('..', 2)
      if lindex.nil? or rindex.nil? or lindex !~ /^-?\d+$/ or rindex !~ /^-?\d+$/
        raise Fluent::ConfigError, "out_hash_forard: hash_key_slice must be formatted like [num]..[num]"
      else
        @hash_key_slice_lindex = lindex.to_i
        @hash_key_slice_rindex = rindex.to_i
      end
    end

    @standby_nodes, @regular_nodes = @nodes.partition {|n| n.standby? }
    @regular_weight_array = build_weight_array(@regular_nodes)
    @standby_weight_array = build_weight_array(@standby_nodes)

    @cache_nodes = {}
    @sock = {}
    @sock_expired_at = {}
    @mutex = {}
    @watcher_interval = 1
  end

  # for test
  attr_reader :regular_nodes
  attr_reader :standby_nodes
  attr_reader :regular_weight_array
  attr_reader :standby_weight_array
  attr_accessor :hash_key_slice_lindex
  attr_accessor :hash_key_slice_rindex
  attr_accessor :watcher_interval

  def start
    super
    start_watcher
  end

  def shutdown
    super
    stop_watcher
  end

  def start_watcher
    if @keepalive and @keepalive_time
      @watcher = Thread.new(&method(:watch_keepalive_time))
    end
  end

  def stop_watcher
    if @watcher
      @watcher.terminate
      @watcher.join
    end
  end

  # Override
  def write_objects(tag, chunk)
    return if chunk.empty?
    error = nil
    nodes = nodes(tag)

    # below is just copy from out_forward
    nodes.each do |node|
      if node.available?
        begin
          send_data(node, tag, chunk)
          return
        rescue
          # for load balancing during detecting crashed servers
          error = $!  # use the latest error
        end
      end
    end

    if error
      raise error
    else
      raise "no nodes are available"  # TODO message
    end
  end

  # Override: I change weight algorithm
  def rebuild_weight_array
  end

  # This is just a partial copy from ForwardOuput#rebuild_weight_array
  def build_weight_array(nodes)
    weight_array = []
    gcd = nodes.map {|n| n.weight }.inject(0) {|r,w| r.gcd(w) }
    nodes.each {|n|
      (n.weight / gcd).times {
        weight_array << n
      }
    }
    weight_array
  end

  # Get nodes (a regular_node and a standby_node if available) using hash algorithm
  def nodes(tag)
    if nodes = @cache_nodes[tag]
      return nodes
    end
    hash_key = @hash_key_slice ? perform_hash_key_slice(tag) : tag
    regular_index = @regular_weight_array.size > 0 ? get_index(hash_key, @regular_weight_array.size) : 0
    standby_index = @standby_weight_array.size > 0 ? get_index(hash_key, @standby_weight_array.size) : 0
    nodes = [@regular_weight_array[regular_index], @standby_weight_array[standby_index]].compact
    @cache_nodes[tag] = nodes
  end

  # hashing(key) mod N
  def get_index(key, size)
    str_hash(key) % size
  end

  # the simplest hashing ever
  # https://gist.github.com/sonots/7263495
  def str_hash(key)
    key.bytes.inject(&:+)
  end

  def perform_hash_key_slice(tag)
    tags = tag.split('.')
    sliced = tags[@hash_key_slice_lindex..@hash_key_slice_rindex]
    return sliced.nil? ? "" : sliced.join('.')
  end

  # Override for keepalive
  def send_data(node, tag, chunk)
    get_mutex(node).synchronize do
      sock = get_sock[node]
      unless sock
        sock = reconnect(node)
      end

      begin
        sock_write(sock, tag, chunk)
        node.heartbeat(false)
      rescue Errno::EPIPE, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::ETIMEDOUT => e
        log.warn "out_hash_forward: #{e.class} #{e.message}"
        sock = reconnect(node)
        retry
      end
    end
  end

  def reconnect(node)
    sock = connect(node)
    opt = [1, @send_timeout.to_i].pack('I!I!')  # { int l_onoff; int l_linger; }
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, opt)

    opt = [@send_timeout.to_i, 0].pack('L!L!')  # struct timeval
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, opt)

    if @keepalive
      get_sock[node] = sock
      get_sock_expired_at[node] = Time.now + @keepalive_time if @keepalive_time
    end

    sock
  end

  def sock_write(sock, tag, chunk)
    # beginArray(2)
    sock.write FORWARD_HEADER

    # writeRaw(tag)
    sock.write tag.to_msgpack  # tag

    # beginRaw(size)
    sz = chunk.size
    #if sz < 32
    #  # FixRaw
    #  sock.write [0xa0 | sz].pack('C')
    #elsif sz < 65536
    #  # raw 16
    #  sock.write [0xda, sz].pack('Cn')
    #else
    # raw 32
    sock.write [0xdb, sz].pack('CN')
    #end

    # writeRawBody(packed_es)
    chunk.write_to(sock)
  end

  # watcher thread callback
  def watch_keepalive_time
    while true
      sleep @watcher_interval
      thread_ids = @sock.keys
      thread_ids.each do |thread_id|
        @sock[thread_id].each do |node, sock|
          @mutex[thread_id][node].synchronize do
            next unless sock_expired_at = @sock_expired_at[thread_id][node]
            next unless Time.now >= sock_expired_at
            sock.close rescue IOError if sock
            @sock[thread_id][node] = nil
            @sock_expired_at[thread_id][node] = nil
          end
        end
      end
    end
  end

  def get_mutex(node)
    thread_id = Thread.current.object_id
    @mutex[thread_id] ||= {}
    @mutex[thread_id][node] ||= Mutex.new
  end

  def get_sock
    @sock[Thread.current.object_id] ||= {}
  end

  def get_sock_expired_at
    @sock_expired_at[Thread.current.object_id] ||= {}
  end
end
