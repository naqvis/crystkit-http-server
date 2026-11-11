require "http/server"
require "log"
require "mime"
require "openssl_ext"
require "uri"

module CrystKit
  module Features
    # Represents an incoming HTTP request, emitted to `on_request` callbacks.
    struct ServerRequest
      # HTTP verb used by the client (e.g. `"GET"`, `"POST"`).
      getter method : String

      # Request path including the leading `/`, URL-decoded, without query
      # string.
      getter path : String

      # Headers as received from the client.
      getter headers : HTTP::Headers

      # Full decoded request body as a string; empty when no body was sent.
      getter body : String

      # Build a `ServerRequest` from raw request components.
      def initialize(@method : String, @path : String, @headers : HTTP::Headers, @body : String)
      end
    end

    # CORS configuration for the localhost HTTP server.
    #
    # When attached to a `ServerOptions` via `cors=`, the server emits the
    # appropriate `Access-Control-Allow-*` headers on every response and
    # short-circuits `OPTIONS` preflights with a 204. The default preset allows
    # all origins, the common REST verbs, and the `Content-Type` /
    # `Authorization` request headers.
    #
    # Note that `allow_origins = ["*"]` cannot be combined with
    # `allow_credentials = true` per the CORS spec; `LocalhostServer#start`
    # rejects that combination with code `"INVALID_CORS_CONFIG"`.
    struct CorsOptions
      # Origins allowed to make cross-origin requests. Use `["*"]` for a
      # public API, or an explicit list of `https://...` origins when
      # `allow_credentials` is true.
      property allow_origins : Array(String)

      # HTTP methods the server advertises as allowed via
      # `Access-Control-Allow-Methods`.
      property allow_methods : Array(String)

      # Request headers clients may send, advertised via
      # `Access-Control-Allow-Headers`.
      property allow_headers : Array(String)

      # Response headers exposed to JavaScript via
      # `Access-Control-Expose-Headers`. Empty by default.
      property expose_headers : Array(String)

      # When `true`, sets `Access-Control-Allow-Credentials: true`. Requires
      # `allow_origins` to be a specific list, not `["*"]`.
      property? allow_credentials : Bool

      # Optional preflight cache lifetime in seconds, advertised via
      # `Access-Control-Max-Age`. `nil` omits the header, leaving the browser
      # default in effect.
      property max_age : Int32?

      # Build CORS options with defaults for a REST API.
      def initialize(
        @allow_origins : Array(String) = ["*"],
        @allow_methods : Array(String) = ["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"],
        @allow_headers : Array(String) = ["Content-Type", "Authorization"],
        @expose_headers : Array(String) = [] of String,
        @allow_credentials = false,
        @max_age = nil,
      )
      end
    end

    # Options for configuring the localhost HTTP server.
    #
    # All properties default to development-friendly values.
    struct ServerOptions
      # Default request body cap (16 MiB). Set `max_request_body` to `nil`
      # to disable the limit.
      DEFAULT_MAX_REQUEST_BODY = 16 * 1024 * 1024

      # Explicit port to bind. When `nil` (default) the server auto-selects an
      # available port from the ephemeral range. Use `0` to ask the OS for an
      # OS-assigned ephemeral port.
      property port : Int32?

      # When `true`, fall back to the next available port if `port` is busy.
      # When `false`, a busy requested port raises `Core::NetworkError` with
      # code `"PORT_IN_USE"`.
      property? auto_port : Bool

      # When `true`, log every request line via `Log.info`.
      property? log_requests : Bool

      # Maximum request body size in bytes. Requests with a larger
      # `Content-Length`, or chunked bodies that cross the limit while being
      # read, receive `413 Payload Too Large`. Set to `nil` to disable.
      property max_request_body : Int32?

      # Optional CORS configuration; when `nil` no CORS headers are emitted.
      property cors : CorsOptions?

      # Headers added to every response, regardless of route. Useful for
      # `X-Frame-Options`, CSP, or `Server:` banners.
      property custom_headers : Hash(String, String)

      # When `true`, the server binds with TLS (HTTPS). Requires either
      # `tls_cert_path` / `tls_key_path` or auto-generated self-signed certs.
      property? tls_enabled : Bool

      # Path to the PEM certificate chain used when `tls_enabled` is `true`.
      # When `nil`, a self-signed cert is generated for local development use.
      property tls_cert_path : Path?

      # Path to the PEM private key matching `tls_cert_path`.
      property tls_key_path : Path?

      # Directory used for auto-generated TLS certificate/key files. When
      # `nil`, the system temporary directory is used. Generated files are
      # removed when the server stops.
      property tls_temp_dir : Path?

      # Build options with development-friendly defaults.
      def initialize(
        @port = nil,
        @auto_port = true,
        @log_requests = false,
        @max_request_body : Int32? = DEFAULT_MAX_REQUEST_BODY,
        @cors : CorsOptions? = nil,
        @custom_headers : Hash(String, String) = {} of String => String,
        @tls_enabled = false,
        @tls_cert_path = nil,
        @tls_key_path = nil,
        @tls_temp_dir : Path? = nil,
        @host : String = "127.0.0.1",
      )
      end

      # Host/interface to bind. Defaults to `127.0.0.1` (loopback only).
      # Pass `0.0.0.0` to listen on all interfaces — only do this if you
      # understand the security implications.
      property host : String
    end

    # :nodoc:
    # A route handler entry
    private struct Route
      getter method : String
      getter path : String
      getter handler : Proc(HTTP::Server::Context, Nil)

      def initialize(@method : String, @path : String, @handler : Proc(HTTP::Server::Context, Nil))
      end

      # Returns true if this route matches the given method and path.
      # Supports exact matches and simple wildcard suffix (e.g. "/api/*").
      def matches?(req_method : String, req_path : String) : Bool
        return false unless @method == "*" || @method.upcase == req_method.upcase

        if @path.ends_with?("/*")
          prefix = @path[0..-3] # strip "/*"
          req_path == prefix || req_path.starts_with?("#{prefix}/")
        else
          @path == req_path
        end
      end
    end

    # Embedded localhost HTTP server with static file serving, custom routes,
    # middleware support, CORS, custom headers, and request event emission.
    class LocalhostServer
      # Inclusive lower bound of the ephemeral port range for auto-allocated
      # ports.
      PORT_RANGE_START = 49152

      # Inclusive upper bound of the ephemeral port range for auto-allocated
      # ports.
      PORT_RANGE_END = 65535

      # How long a listening socket waits for a connection before yielding
      # back to the event loop. Keeps `#stop` from deadlocking against a
      # blocked `accept`.
      ACCEPT_POLL_INTERVAL = 100.milliseconds

      @server : HTTP::Server?
      @port : Int32?
      @routes : Array(Route)
      @middleware : Array(HTTP::Handler)
      @static_dir : Path?
      @static_prefix : String
      @request_handlers : Array(Proc(ServerRequest, Nil))
      @options : ServerOptions
      @running : Bool
      @tls_temp_files : Array(String)

      # Build an unstarted `LocalhostServer` with no routes or middleware.
      #
      # Use `serve_static`, `add_route`, `use_middleware`, and `on_request` to
      # configure it, then call `start` (or the one-call `serve`).
      def initialize
        @routes = [] of Route
        @middleware = [] of HTTP::Handler
        @static_prefix = "/"
        @request_handlers = [] of Proc(ServerRequest, Nil)
        @options = ServerOptions.new
        @running = false
        @tls_temp_files = [] of String
      end

      # Returns the port the server is listening on, or nil if not started.
      def port : Int32?
        @port
      end

      # Returns true if the server is currently running.
      def running? : Bool
        @running
      end

      # Serve static files from *directory* under the given URL *prefix*.
      #
      # The prefix is normalised to start and end with `/`, so `"assets"`,
      # `"assets/"`, `"/assets"`, and `"/assets/"` are equivalent. Request
      # paths are percent-decoded; traversal and symlinks resolving outside
      # *directory* are rejected.
      #
      def serve_static(directory : Path, prefix : String = "/") : Nil
        unless Dir.exists?(directory)
          raise Core::FileSystemError.new(
            "Static directory does not exist: #{directory}",
            code: "DIR_NOT_FOUND"
          )
        end
        @static_dir = directory
        normalized = prefix.empty? ? "/" : prefix
        normalized = "/#{normalized}" unless normalized.starts_with?('/')
        normalized = "#{normalized}/" unless normalized.ends_with?('/')
        @static_prefix = normalized
      end

      # Register a custom route handler for *method* and *path*.
      #
      def add_route(method : String, path : String, &handler : HTTP::Server::Context ->) : Nil
        @routes << Route.new(method.upcase, path, handler)
      end

      # Add a middleware handler to the request pipeline.
      # Middleware is called in the order it was added, before route handlers.
      #
      def use_middleware(middleware : HTTP::Handler) : Nil
        @middleware << middleware
      end

      # Register a callback that is called for every incoming request.
      #
      # The callback receives a `ServerRequest` whose body is a full in-memory
      # snapshot. The server restores the body for route handlers, but reading
      # it up front means large uploads are buffered; avoid enabling this on
      # untrusted public interfaces.
      #
      def on_request(&handler : ServerRequest ->) : Nil
        @request_handlers << handler
      end

      # One-call convenience: configure to serve a static directory and start.
      # Returns the chosen port.
      #
      # ```
      # server = CrystKit::Features::LocalhostServer.new
      # port = server.serve(Path["./assets"])
      # ```
      def serve(directory : Path, prefix : String = "/", options : ServerOptions = ServerOptions.new) : Int32
        serve_static(directory, prefix)
        start(options)
      end

      # Start the HTTP server. Returns the actual port number it is listening
      # on. If *options.port* is set and available, that port is used; `0`
      # asks the OS for an ephemeral port. If the port is busy and
      # *options.auto_port* is true, an available port in the ephemeral range
      # is selected automatically.
      #
      # If *options.tls_enabled* is true, the server serves HTTPS using either
      # the provided certificate/key paths or auto-generated self-signed certs.
      def start(options : ServerOptions = ServerOptions.new) : Int32
        raise Core::NetworkError.new("Server is already running", code: "ALREADY_RUNNING") if @running
        validate_options!(options)

        @options = options
        begin
          handler = build_handler
          ssl_ctx = build_ssl_context(options) if options.tls_enabled?
          server = ManagedHTTPServer.new([handler])
          port = bind(server, options, ssl_ctx)

          @server = server
          @port = port
          @running = true

          Core::Fibers.spawn do
            server.listen
          rescue ex : Exception
            Log.debug { "Server fiber exited: #{ex.message}" }
          end
        rescue ex
          @server.try(&.close)
          @server = nil
          @port = nil
          @running = false
          cleanup_tls_temp_files
          raise ex
        end

        scheme = options.tls_enabled? ? "https" : "http"
        Log.info { "LocalhostServer started on #{scheme}://#{options.host}:#{@port}" } if options.log_requests?

        @port.not_nil!
      end

      # Stop accepting new connections and release the listening socket plus
      # any generated TLS material. In-flight requests are allowed to finish.
      #
      def stop : Nil
        return unless @running
        @running = false
        @server.try(&.close)
        @server = nil
        @port = nil
        cleanup_tls_temp_files
        Log.info { "LocalhostServer stopped" } if @options.log_requests?
      end

      # :nodoc:
      private def validate_options!(options : ServerOptions) : Nil
        if max = options.max_request_body
          if max < 0
            raise Core::Error.new(
              "max_request_body must be >= 0 or nil",
              code: "INVALID_BODY_LIMIT"
            )
          end
        end

        cors = options.cors
        return unless cors
        return unless cors.allow_credentials? && cors.allow_origins.includes?("*")

        raise Core::Error.new(
          "CORS allow_credentials cannot be combined with wildcard origins",
          code: "INVALID_CORS_CONFIG"
        )
      end

      # :nodoc:
      private def bind(server : HTTP::Server, options : ServerOptions, ssl_ctx : OpenSSL::SSL::Context::Server?) : Int32
        if requested = options.port
          begin
            return bind(server, options.host, requested, ssl_ctx).port
          rescue ex : Socket::BindError
            unless options.auto_port?
              raise Core::NetworkError.new(
                "Port #{requested} is already in use",
                code: "PORT_IN_USE"
              )
            end
          end
        end

        (PORT_RANGE_START..PORT_RANGE_END).each do |port|
          next if port == options.port
          begin
            return bind(server, options.host, port, ssl_ctx).port
          rescue Socket::BindError
          end
        end

        raise Core::NetworkError.new(
          "No available port found in range #{PORT_RANGE_START}-#{PORT_RANGE_END}",
          code: "NO_PORT_AVAILABLE"
        )
      end

      # :nodoc:
      private def bind(server : HTTP::Server, host : String, port : Int32, ssl_ctx : OpenSSL::SSL::Context::Server?) : Socket::IPAddress
        tcp_server = TCPServer.new(host, port)
        begin
          # A bounded accept timeout prevents `HTTP::Server#close` from
          # deadlocking while an accept fiber holds the listening fd open.
          tcp_server.read_timeout = ACCEPT_POLL_INTERVAL

          if ssl_ctx
            ssl_server = OpenSSL::SSL::Server.new(tcp_server, ssl_ctx)
            ssl_server.start_immediately = false
            server.bind(ssl_server)
          else
            server.bind(tcp_server)
          end

          tcp_server.local_address
        rescue ex
          tcp_server.close
          raise ex
        end
      end

      # Build an SSL context for TLS, using provided cert/key or auto-generating.
      # :nodoc:
      private def build_ssl_context(options : ServerOptions) : OpenSSL::SSL::Context::Server
        ctx = OpenSSL::SSL::Context::Server.new

        cert_path = options.tls_cert_path
        key_path = options.tls_key_path

        if cert_path && key_path
          unless File.exists?(cert_path) && File.exists?(key_path)
            raise Core::NetworkError.new(
              "TLS cert/key files not found: #{cert_path}, #{key_path}",
              code: "TLS_CERT_NOT_FOUND"
            )
          end
          ctx.certificate_chain = cert_path.to_s
          ctx.private_key = key_path.to_s
        elsif cert_path || key_path
          raise Core::NetworkError.new(
            "TLS requires both tls_cert_path and tls_key_path",
            code: "TLS_CONFIG_INCOMPLETE"
          )
        else
          generate_self_signed_cert(ctx, options.tls_temp_dir)
        end

        ctx
      rescue ex : Core::NetworkError
        raise ex
      rescue ex
        raise Core::NetworkError.new(
          "Failed to configure TLS: #{ex.message}",
          code: "TLS_CONFIG_FAILED"
        )
      end

      # Generate a self-signed X.509 certificate and private key for local
      # development, storing them in owner-only temporary files that are
      # removed when the server stops.
      # :nodoc:
      private def generate_self_signed_cert(ctx : OpenSSL::SSL::Context::Server, temp_dir : Path? = nil) : Nil
        key = OpenSSL::PKey::RSA.new(2048)
        cert = OpenSSL::X509::Certificate.new
        name = OpenSSL::X509::Name.new
        name.add_entry("CN", "localhost")
        name.add_entry("O", "CrystKit Auto-Generated")
        cert.subject = name
        cert.issuer = name
        serial = Random::Secure.rand(UInt64)
        cert.serial = serial.zero? ? 1_u64 : serial
        not_before = OpenSSL::ASN1::Time.days_from_now(-1)
        not_after = OpenSSL::ASN1::Time.days_from_now(365)
        cert.not_before = not_before
        cert.not_after = not_after
        cert.public_key = key
        cert.add_extension(
          OpenSSL::X509::Extension.new("subjectAltName", "DNS:localhost,IP:127.0.0.1")
        )

        cert.sign(key, OpenSSL::Digest.new("SHA256"))

        target_dir = temp_dir.try(&.to_s) || Dir.tempdir
        cert_path = write_temp_pem("webview_tls_cert", cert.to_pem, target_dir)
        key_path = write_temp_pem("webview_tls_key", key.to_pem, target_dir)

        ctx.certificate_chain = cert_path.to_s
        ctx.private_key = key_path.to_s
      end

      # :nodoc:
      private def write_temp_pem(prefix : String, contents : String, dir : String) : Path
        file = File.tempfile(prefix, ".pem", dir: dir)
        path = Path.new(file.path)
        @tls_temp_files << path.to_s
        begin
          file.print(contents)
        ensure
          file.close
        end
        path
      end

      # :nodoc:
      private def cleanup_tls_temp_files : Nil
        @tls_temp_files.each do |path|
          File.delete?(path)
        rescue ex
          Log.warn { "Failed to remove temporary TLS file #{path}: #{ex.message}" }
        end
        @tls_temp_files.clear
      end

      # Build the HTTP::Handler chain: middleware + main dispatcher
      # :nodoc:
      private def build_handler : HTTP::Handler
        dispatcher = RequestDispatcher.new(
          routes: @routes,
          static_dir: @static_dir,
          static_prefix: @static_prefix,
          request_handlers: @request_handlers,
          log_requests: @options.log_requests?,
          cors: @options.cors,
          custom_headers: @options.custom_headers
        )

        handlers = [] of HTTP::Handler
        if max = @options.max_request_body
          handlers << BodyLimitHandler.new(max.to_i64)
        end
        handlers.concat(@middleware)
        handlers << dispatcher

        return dispatcher if handlers.size == 1

        HTTP::Server.build_middleware(handlers)
      end
    end

    # `HTTP::Server` variant that treats accept timeouts as a normal poll
    # wake-up instead of logging them as connection errors.
    # :nodoc:
    private class ManagedHTTPServer < HTTP::Server
      private def handle_exception(e : Exception)
        return if e.is_a?(IO::TimeoutError)
        super
      end
    end

    # Rejects oversized requests before body-reading handlers run, and wraps
    # chunked bodies so the limit is enforced while streaming.
    # :nodoc:
    private class BodyLimitHandler
      include HTTP::Handler

      def initialize(@max : Int64)
      end

      def call(context : HTTP::Server::Context) : Nil
        req = context.request

        if content_length = req.headers["Content-Length"]?
          if length = content_length.to_i64?
            if length > @max
              payload_too_large(context)
              return
            end
          end
        end

        if body = req.body
          req.body = LimitedBodyIO.new(body, @max)
        end

        call_next(context)
      rescue ex : Core::Error
        if ex.code == "BODY_TOO_LARGE"
          payload_too_large(context)
        else
          raise ex
        end
      end

      private def payload_too_large(context : HTTP::Server::Context) : Nil
        context.response.status = HTTP::Status::PAYLOAD_TOO_LARGE
        context.response.content_type = "text/plain"
        context.response.print("Payload Too Large")
      rescue
        # Headers may already be on the wire; let the connection close.
      end
    end

    # IO wrapper that raises once more than *limit* bytes are read.
    # :nodoc:
    private class LimitedBodyIO < IO
      def initialize(@io : IO, @limit : Int64)
        @read = 0_i64
      end

      def read(slice : Bytes) : Int32
        count = @io.read(slice)
        @read += count
        if @read > @limit
          raise Core::Error.new(
            "Request body exceeds the configured limit of #{@limit} bytes",
            code: "BODY_TOO_LARGE"
          )
        end
        count
      end

      def write(slice : Bytes) : Nil
        raise IO::Error.new("Cannot write to a request body")
      end

      def close : Nil
        @io.close
      end
    end

    # Internal handler that dispatches requests to routes or static files.
    # :nodoc:
    private class RequestDispatcher
      include HTTP::Handler

      # Construct the dispatcher with all configuration it needs to serve a
      # request: registered routes, optional static directory/prefix, request
      # event handlers, logging flag, CORS, and custom headers. Owned by
      # `LocalhostServer`; never instantiated directly by application code.
      def initialize(
        @routes : Array(Route),
        @static_dir : Path?,
        @static_prefix : String,
        @request_handlers : Array(Proc(ServerRequest, Nil)),
        @log_requests : Bool,
        @cors : CorsOptions? = nil,
        @custom_headers : Hash(String, String) = {} of String => String,
      )
      end

      # HTTP::Handler entry point: dispatch a single request through CORS,
      # custom headers, request event emission, route matching, static file
      # serving, and a 404 fallback.
      # :nodoc:
      def call(context : HTTP::Server::Context) : Nil
        req = context.request
        method = req.method
        path = decode_path(req.path)

        # Apply custom headers to every response
        @custom_headers.each do |name, value|
          context.response.headers[name] = value
        end

        unless path
          bad_request(context)
          return
        end

        Log.info { "#{method} #{path}" } if @log_requests

        # Apply CORS headers if configured
        cors_allowed = apply_cors(context)

        # Handle real preflight OPTIONS requests immediately. A bare OPTIONS
        # request, or one from an origin that is not allowed, falls through to
        # the normal route pipeline.
        if method == "OPTIONS" && @cors && req.headers["Origin"]? && cors_allowed
          context.response.status = HTTP::Status::NO_CONTENT
          return
        end

        # Emit request event to all registered handlers
        emit_request_event(req, path)

        # Try custom routes first
        @routes.each do |route|
          if route.matches?(method, path)
            route.handler.call(context)
            return
          end
        end

        # Try static file serving
        if serve_static_file(context, path)
          return
        end

        # 404 fallback
        context.response.status = HTTP::Status::NOT_FOUND
        context.response.content_type = "text/plain"
        context.response.print("Not Found")
      end

      # :nodoc:
      private def decode_path(raw : String) : String?
        return nil unless valid_percent_encoding?(raw)
        decoded = URI.decode(raw)
        decoded.valid_encoding? ? decoded : nil
      end

      # :nodoc:
      private def valid_percent_encoding?(path : String) : Bool
        bytes = path.to_slice
        i = 0
        while i < bytes.size
          if bytes[i] == '%'.ord
            return false if i + 2 >= bytes.size
            return false unless hex_byte?(bytes[i + 1]) && hex_byte?(bytes[i + 2])
            i += 3
          else
            i += 1
          end
        end
        true
      end

      # :nodoc:
      private def hex_byte?(byte : UInt8) : Bool
        (byte >= '0'.ord && byte <= '9'.ord) ||
          (byte >= 'a'.ord && byte <= 'f'.ord) ||
          (byte >= 'A'.ord && byte <= 'F'.ord)
      end

      # :nodoc:
      private def bad_request(context : HTTP::Server::Context) : Nil
        context.response.status = HTTP::Status::BAD_REQUEST
        context.response.content_type = "text/plain"
        context.response.print("Bad Request")
      end

      # :nodoc:
      private def apply_cors(context : HTTP::Server::Context) : Bool
        cors = @cors
        return false unless cors

        origin = context.request.headers["Origin"]?
        return false unless origin

        allowed_origin = if cors.allow_origins.includes?("*")
                           "*"
                         elsif cors.allow_origins.includes?(origin)
                           origin
                         end
        return false unless allowed_origin

        if allowed_origin == "*"
          context.response.headers["Access-Control-Allow-Origin"] = "*"
        else
          context.response.headers["Access-Control-Allow-Origin"] = allowed_origin
          context.response.headers["Vary"] = "Origin"
        end

        context.response.headers["Access-Control-Allow-Methods"] = cors.allow_methods.join(", ")
        context.response.headers["Access-Control-Allow-Headers"] = cors.allow_headers.join(", ")

        unless cors.expose_headers.empty?
          context.response.headers["Access-Control-Expose-Headers"] = cors.expose_headers.join(", ")
        end

        if cors.allow_credentials?
          context.response.headers["Access-Control-Allow-Credentials"] = "true"
        end

        if max_age = cors.max_age
          context.response.headers["Access-Control-Max-Age"] = max_age.to_s
        end

        true
      end

      # :nodoc:
      private def emit_request_event(req : HTTP::Request, path : String) : Nil
        return if @request_handlers.empty?

        body = req.body.try(&.gets_to_end) || ""
        # `ServerRequest#body` is a snapshot. Put the consumed stream back so
        # route handlers can still read the original payload.
        req.body = body
        server_req = ServerRequest.new(
          method: req.method,
          path: path,
          headers: req.headers,
          body: body
        )

        @request_handlers.each do |handler|
          begin
            handler.call(server_req)
          rescue ex
            Log.warn { "Request event handler error: #{ex.message}" }
          end
        end
      end

      # :nodoc:
      private def serve_static_file(context : HTTP::Server::Context, req_path : String) : Bool
        dir = @static_dir
        return false unless dir

        # Check if path is under the static prefix
        unless req_path.starts_with?(@static_prefix) || req_path == @static_prefix.rstrip("/")
          return false
        end

        # Strip the prefix to get the relative file path
        relative = if req_path == @static_prefix.rstrip("/")
                     "/"
                   else
                     req_path[@static_prefix.size - 1..]? || "/"
                   end

        # Normalize and prevent directory traversal
        relative = relative.lstrip("/")
        relative = "index.html" if relative.empty?

        # Prevent path traversal attacks
        if relative.includes?("..") || relative.includes?('\0')
          forbidden(context)
          return true
        end

        file_path = dir / relative

        if File.directory?(file_path)
          unless inside_root?(dir, file_path)
            forbidden(context)
            return true
          end

          # Try index.html in directory
          index = file_path / "index.html"
          if File.exists?(index)
            unless inside_root?(dir, index)
              forbidden(context)
              return true
            end
            serve_file(context, index)
            return true
          end
          return false
        end

        if File.exists?(file_path)
          unless inside_root?(dir, file_path)
            forbidden(context)
            return true
          end
          serve_file(context, file_path)
          return true
        end

        false
      end

      # :nodoc:
      # Rejects symlinks (or other indirections) that resolve outside the
      # configured static root. Missing paths also return false.
      private def inside_root?(root : Path, candidate : Path) : Bool
        root_real = Path.new(File.realpath(root))
        candidate_real = Path.new(File.realpath(candidate))
        relative = candidate_real.relative_to?(root_real)
        return false unless relative
        !relative.parts.includes?("..")
      rescue
        false
      end

      # :nodoc:
      private def forbidden(context : HTTP::Server::Context) : Nil
        context.response.status = HTTP::Status::FORBIDDEN
        context.response.content_type = "text/plain"
        context.response.print("Forbidden")
      end

      # :nodoc:
      private def serve_file(context : HTTP::Server::Context, path : Path) : Nil
        content_type = MIME.from_filename?(path.to_s) || "application/octet-stream"
        context.response.content_type = content_type
        context.response.status = HTTP::Status::OK

        File.open(path) do |file|
          IO.copy(file, context.response)
        end
      rescue ex
        Log.warn { "Error serving file #{path}: #{ex.message}" }
        context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
        context.response.content_type = "text/plain"
        context.response.print("Internal Server Error")
      end
    end
  end
end
