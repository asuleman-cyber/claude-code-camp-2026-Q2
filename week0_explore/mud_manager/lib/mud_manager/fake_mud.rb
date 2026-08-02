require "socket"
require "thread"

module MudManager
  # In-process CircleMUD stand-in: walks the same login dance
  # MudManager::Session#login expects, then echoes whatever it's sent as
  # "You do: <command>" followed by a prompt ending in "> ". It exists so the
  # daemon, its clients, and boukensha's MCP layer can be tested offline, with
  # no live MUD and no credentials. Never used in a real run.
  class FakeMud
    attr_reader :port

    def initialize(password: "secret", host: "127.0.0.1")
      @password = password
      @server   = TCPServer.new(host, 0)
      @port     = @server.addr[1]
      @known    = {}
      @known_mu = Mutex.new
      @closed   = false
      @accept_thread = Thread.new { accept_loop }
      @accept_thread.report_on_exception = false
    end

    def stop
      return if @closed
      @closed = true
      begin
        @server.close
      rescue StandardError
        # already closed — fine
      end
      @accept_thread.join(1)
    end

    private

    def accept_loop
      loop do
        client = @server.accept
        Thread.new(client) { |sock| handle(sock) }
      end
    rescue IOError, Errno::EBADF
      # server closed — normal shutdown
    end

    def handle(sock)
      sock.write("By what name do you wish to be known? ")
      name = sock.gets&.strip
      return sock.close if name.nil?

      sock.write("Password: ")
      password = sock.gets&.strip

      if password != @password
        sock.write("Wrong password.\r\n")
        return sock.close
      end

      first_time = false
      @known_mu.synchronize do
        first_time = !@known[name]
        @known[name] = true
      end

      if first_time
        sock.write("Welcome, #{name}!\r\n")
        sock.gets # the blank "return" that dismisses the login menu
        sock.gets # "1" to enter the game
        sock.write("Entering the game...\r\n<100hp 100m 100v> ")
      else
        sock.write("Reconnecting. Welcome back, #{name}.\r\n<100hp 100m 100v> ")
      end

      loop do
        line = sock.gets
        break if line.nil?
        cmd = line.strip
        break if cmd.casecmp("quit").zero?
        sock.write("You do: #{cmd}\r\n<100hp 100m 100v> ")
      end
    rescue IOError, Errno::ECONNRESET, Errno::EPIPE
      # client disconnected — fine
    ensure
      begin
        sock&.close
      rescue StandardError
        # already closed — fine
      end
    end
  end
end
