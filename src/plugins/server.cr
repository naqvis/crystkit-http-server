require "../features/server"

module CrystKit
  module Plugins
    # Builtin plugin that runs an in-process localhost HTTP server the frontend
    # can use to expose local APIs or serve assets.
    #
    # The server is bound to the loopback interface and is single-instance
    # per plugin: calling `server.start` while it is running stops the current
    # instance and rebinds. This is intended for development helpers and local
    # IPC bridges, *not* as a production web server. `server.start` accepts
    # only loopback hosts and rejects public interfaces such as `0.0.0.0`.
    #
    # Registers IPC commands:
    #   server.start — Start (or rebind) the localhost server
    #   server.stop — Stop the localhost server
    #   server.status — Get running status, bound port, and host
    #
    # Required capability: `server:manage`
    #
    # `server.start` accepts a JSON object or `null` with optional `port`
    # (`0` requests an OS-assigned ephemeral port, omitted/`null` selects a
    # free port from the ephemeral range) and `host` (defaults to
    # `127.0.0.1`; only loopback hosts are allowed, and `localhost` is
    # normalised to `127.0.0.1`). It returns the actual bound port and host so
    # the caller can connect to an ephemeral binding.
    #
    # ```
    # app.plugin(CrystKit::Plugins::Server.new)
    # ```
    class Server < Plugin::Base
      # Hosts the IPC surface is allowed to bind. Public interfaces are
      # intentionally excluded; applications that need them can construct a
      # `Features::LocalhostServer` directly.
      LOOPBACK_HOSTS = %w(127.0.0.1 localhost ::1)

      # The localhost server, lazily initialized during `#initialize_plugin`.
      # The server is started and stopped on demand via the IPC commands; it
      # is *not* running immediately after initialization.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! server : Features::LocalhostServer

      # Host recorded from the most recent successful `server.start`.
      @last_host : String = "127.0.0.1"

      # Returns the unique plugin identifier `"server"`.
      def identifier : String
        "server"
      end

      # Returns the metadata contract gating every server command behind the
      # `server:manage` capability. Applications that want the frontend to
      # manage the server must explicitly grant `server:manage`.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(server.start server.stop server.status), "server:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(server:manage),
          commands: %w(server.start server.stop server.status),
          ipc: ipc,
        )
      end

      # Registers the IPC commands.
      #
      # The server is constructed but *not* started; the frontend must call
      # `server.start` to bind. `server.status` reports the current running
      # state and bound port without mutating anything, so it is safe to poll.
      def initialize_plugin(context : Plugin::Context) : Nil
        @server = srv = Features::LocalhostServer.new

        context.command "server.start", JSON::Any do |opts|
          options = parse_start_options(opts)
          srv.stop if srv.running?
          srv.start(options)
          @last_host = options.host
          {"port" => srv.port, "host" => @last_host}
        end

        context.command "server.stop" do
          srv.stop
        end

        context.command "server.status" do
          {"running" => srv.running?, "port" => srv.port, "host" => @last_host}
        end
      end

      # :nodoc:
      private def parse_start_options(payload : JSON::Any) : Features::ServerOptions
        object = payload.as_h?
        if object.nil?
          unless payload.raw.nil?
            raise Core::Error.new(
              "server.start expects an object or null",
              code: "BAD_REQUEST"
            )
          end
          object = {} of String => JSON::Any
        end

        port = if port_value = object["port"]?
                 if port_value.raw.nil?
                   nil
                 else
                   value = port_value.as_i?
                   unless value
                     raise Core::Error.new(
                       "server.start port must be an integer",
                       code: "BAD_REQUEST"
                     )
                   end
                   unless 0 <= value <= 65535
                     raise Core::Error.new(
                       "server.start port must be between 0 and 65535",
                       code: "BAD_REQUEST"
                     )
                   end
                   value
                 end
               end

        host = "127.0.0.1"
        if host_value = object["host"]?
          unless host_value.raw.nil?
            parsed = host_value.as_s?
            unless parsed
              raise Core::Error.new(
                "server.start host must be a string",
                code: "BAD_REQUEST"
              )
            end
            host = parsed
          end
        end

        unless LOOPBACK_HOSTS.includes?(host.downcase)
          raise Core::Error.new(
            "server.start only binds loopback hosts",
            code: "HOST_NOT_ALLOWED"
          )
        end
        host = "127.0.0.1" if host.downcase == "localhost"

        Features::ServerOptions.new(port: port, host: host)
      end

      # Stops the server if it was ever started. No-op when the server was
      # never started or already stopped.
      def cleanup_plugin : Nil
        @server.try(&.stop)
      end
    end
  end
end
