require "./spec_helper"
require "../src/features/server"

private class BlockMiddleware
  include HTTP::Handler

  def initialize(&@block : HTTP::Server::Context, Proc(Nil) ->)
  end

  def call(context : HTTP::Server::Context) : Nil
    @block.call(context, -> { call_next(context); nil })
  end
end

describe CrystKit::Features::ServerOptions do
  it "defaults to a 16 MiB request body limit" do
    CrystKit::Features::ServerOptions.new.max_request_body.should eq(16 * 1024 * 1024)
  end
end

describe CrystKit::Features::LocalhostServer do
  it "starts an HTTP server on localhost (127.0.0.1)" do
    server = CrystKit::Features::LocalhostServer.new
    port = server.start
    begin
      server.running?.should be_true
      port.should be > 0
      response = HTTP::Client.get("http://127.0.0.1:#{port}/")
      [200, 404].should contain(response.status_code)
    ensure
      server.stop
    end
  end
  it "is not running after stop" do
    server = CrystKit::Features::LocalhostServer.new
    server.start
    server.stop
    server.running?.should be_false
    server.port.should be_nil
  end
  it "raises NetworkError when started twice" do
    server = CrystKit::Features::LocalhostServer.new
    server.start
    begin
      expect_raises(CrystKit::Core::NetworkError, /already running/i) do
        server.start
      end
    ensure
      server.stop
    end
  end
  it "starts on a specific port when requested" do
    server = CrystKit::Features::LocalhostServer.new
    requested_port = SpecHelpers.free_port
    options = CrystKit::Features::ServerOptions.new(port: requested_port, auto_port: false)
    port = server.start(options)
    begin
      port.should eq(requested_port)
      server.port.should eq(requested_port)
      response = HTTP::Client.get("http://127.0.0.1:#{requested_port}/")
      [200, 404].should contain(response.status_code)
    ensure
      server.stop
    end
  end
  it "returns the actual port from start" do
    server = CrystKit::Features::LocalhostServer.new
    port = server.start
    begin
      port.should eq(server.port)
    ensure
      server.stop
    end
  end
  it "auto-selects a different port when requested port is busy" do
    blocker = TCPServer.new("127.0.0.1", 0)
    occupied_port = blocker.local_address.port
    begin
      server = CrystKit::Features::LocalhostServer.new
      options = CrystKit::Features::ServerOptions.new(port: occupied_port, auto_port: true)
      port = server.start(options)
      begin
        port.should_not eq(occupied_port)
        server.running?.should be_true
      ensure
        server.stop
      end
    ensure
      blocker.close
    end
  end
  it "auto-selects a port in the ephemeral range when no port is specified" do
    server = CrystKit::Features::LocalhostServer.new
    port = server.start
    begin
      port.should be >= CrystKit::Features::LocalhostServer::PORT_RANGE_START
      port.should be <= CrystKit::Features::LocalhostServer::PORT_RANGE_END
    ensure
      server.stop
    end
  end
  it "raises NetworkError when auto_port is false and port is busy" do
    blocker = TCPServer.new("127.0.0.1", 0)
    occupied_port = blocker.local_address.port
    begin
      server = CrystKit::Features::LocalhostServer.new
      options = CrystKit::Features::ServerOptions.new(port: occupied_port, auto_port: false)
      error = expect_raises(CrystKit::Core::NetworkError) do
        server.start(options)
      end
      error.code.should eq("PORT_IN_USE")
      server.running?.should be_false
    ensure
      blocker.close
    end
  end
end
describe "static file serving" do
  it "serves a static file from the configured directory" do
    SpecHelpers.with_temp_dir do |dir|
      File.write(File.join(dir, "hello.txt"), "Hello, World!")
      server = CrystKit::Features::LocalhostServer.new
      server.serve_static(Path[dir])
      port = server.start
      begin
        response = HTTP::Client.get("http://127.0.0.1:#{port}/hello.txt")
        response.status_code.should eq(200)
        response.body.should eq("Hello, World!")
        response.headers["Content-Length"]?.should eq("Hello, World!".bytesize.to_s)
      ensure
        server.stop
      end
    end
  end
  it "serves index.html when requesting root path" do
    SpecHelpers.with_temp_dir do |dir|
      File.write(File.join(dir, "index.html"), "<html>Index</html>")
      server = CrystKit::Features::LocalhostServer.new
      server.serve_static(Path[dir])
      port = server.start
      begin
        response = HTTP::Client.get("http://127.0.0.1:#{port}/")
        response.status_code.should eq(200)
        response.body.should eq("<html>Index</html>")
      ensure
        server.stop
      end
    end
  end
  it "returns 404 for missing static files" do
    SpecHelpers.with_temp_dir do |dir|
      server = CrystKit::Features::LocalhostServer.new
      server.serve_static(Path[dir])
      port = server.start
      begin
        response = HTTP::Client.get("http://127.0.0.1:#{port}/nonexistent.txt")
        response.status_code.should eq(404)
      ensure
        server.stop
      end
    end
  end
  it "returns 403 for path traversal attempts" do
    SpecHelpers.with_temp_dir do |dir|
      server = CrystKit::Features::LocalhostServer.new
      server.serve_static(Path[dir])
      port = server.start
      begin
        response = HTTP::Client.get("http://127.0.0.1:#{port}/../../etc/passwd")
        response.status_code.should eq(403)
      ensure
        server.stop
      end
    end
  end
  it "raises FileSystemError when static directory does not exist" do
    server = CrystKit::Features::LocalhostServer.new
    expect_raises(CrystKit::Core::FileSystemError, /does not exist/i) do
      server.serve_static(Path["/nonexistent/path/that/does/not/exist"])
    end
  end
  it "serves files under a custom prefix" do
    SpecHelpers.with_temp_dir do |dir|
      File.write(File.join(dir, "app.js"), "console.log('hi')")
      server = CrystKit::Features::LocalhostServer.new
      server.serve_static(Path[dir], prefix: "/assets")
      port = server.start
      begin
        response = HTTP::Client.get("http://127.0.0.1:#{port}/assets/app.js")
        response.status_code.should eq(200)
        response.body.should eq("console.log('hi')")
        response2 = HTTP::Client.get("http://127.0.0.1:#{port}/app.js")
        response2.status_code.should eq(404)
      ensure
        server.stop
      end
    end
  end
  it "sets correct content-type for served files" do
    SpecHelpers.with_temp_dir do |dir|
      File.write(File.join(dir, "style.css"), "body { color: red; }")
      server = CrystKit::Features::LocalhostServer.new
      server.serve_static(Path[dir])
      port = server.start
      begin
        response = HTTP::Client.get("http://127.0.0.1:#{port}/style.css")
        response.status_code.should eq(200)
        response.headers["Content-Type"]?.should_not be_nil
        response.headers["Content-Type"].should contain("text/css")
      ensure
        server.stop
      end
    end
  end
end
describe "custom route handlers" do
  it "handles a GET route" do
    server = CrystKit::Features::LocalhostServer.new
    server.add_route("GET", "/api/hello") do |ctx|
      ctx.response.content_type = "application/json"
      ctx.response.print(%({"message":"hello"}))
    end
    port = server.start
    begin
      response = HTTP::Client.get("http://127.0.0.1:#{port}/api/hello")
      response.status_code.should eq(200)
      response.body.should eq(%({"message":"hello"}))
    ensure
      server.stop
    end
  end
  it "handles a POST route" do
    server = CrystKit::Features::LocalhostServer.new
    received_body = ""
    server.add_route("POST", "/api/data") do |ctx|
      received_body = ctx.request.body.try(&.gets_to_end) || ""
      ctx.response.status = HTTP::Status::CREATED
      ctx.response.print("created")
    end
    port = server.start
    begin
      response = HTTP::Client.post("http://127.0.0.1:#{port}/api/data", body: "test-payload")
      response.status_code.should eq(201)
      received_body.should eq("test-payload")
    ensure
      server.stop
    end
  end
  it "returns 404 for unregistered routes" do
    server = CrystKit::Features::LocalhostServer.new
    port = server.start
    begin
      response = HTTP::Client.get("http://127.0.0.1:#{port}/api/unknown")
      response.status_code.should eq(404)
    ensure
      server.stop
    end
  end
  it "custom routes take priority over static files" do
    SpecHelpers.with_temp_dir do |dir|
      File.write(File.join(dir, "index.html"), "<html>static</html>")
      server = CrystKit::Features::LocalhostServer.new
      server.serve_static(Path[dir])
      server.add_route("GET", "/") do |ctx|
        ctx.response.print("dynamic")
      end
      port = server.start
      begin
        response = HTTP::Client.get("http://127.0.0.1:#{port}/")
        response.body.should eq("dynamic")
      ensure
        server.stop
      end
    end
  end
  it "supports matching any method with a wildcard route" do
    server = CrystKit::Features::LocalhostServer.new
    server.add_route("*", "/any") { |ctx| ctx.response.print(ctx.request.method) }
    port = server.start
    begin
      HTTP::Client.get("http://127.0.0.1:#{port}/any").body.should eq("GET")
      HTTP::Client.post("http://127.0.0.1:#{port}/any", body: "").body.should eq("POST")
    ensure
      server.stop
    end
  end

  it "supports wildcard route matching" do
    server = CrystKit::Features::LocalhostServer.new
    server.add_route("GET", "/api/*") do |ctx|
      ctx.response.print("wildcard")
    end
    port = server.start
    begin
      response = HTTP::Client.get("http://127.0.0.1:#{port}/api/anything/here")
      response.status_code.should eq(200)
      response.body.should eq("wildcard")
    ensure
      server.stop
    end
  end
end
describe "middleware support" do
  it "executes middleware before route handlers" do
    call_order = [] of String
    server = CrystKit::Features::LocalhostServer.new
    middleware = BlockMiddleware.new do |_, next_handler|
      call_order << "middleware"
      next_handler.call
    end
    server.use_middleware(middleware)
    server.add_route("GET", "/test") do |ctx|
      call_order << "route"
      ctx.response.print("ok")
    end
    port = server.start
    begin
      HTTP::Client.get("http://127.0.0.1:#{port}/test")
      call_order.should eq(["middleware", "route"])
    ensure
      server.stop
    end
  end
  it "middleware can modify the response" do
    server = CrystKit::Features::LocalhostServer.new
    middleware = BlockMiddleware.new do |ctx, next_handler|
      next_handler.call
      ctx.response.headers["X-Custom-Header"] = "middleware-added"
    end
    server.use_middleware(middleware)
    server.add_route("GET", "/test") do |ctx|
      ctx.response.print("body")
    end
    port = server.start
    begin
      response = HTTP::Client.get("http://127.0.0.1:#{port}/test")
      response.headers["X-Custom-Header"]?.should eq("middleware-added")
    ensure
      server.stop
    end
  end
  it "middleware can short-circuit the request pipeline" do
    server = CrystKit::Features::LocalhostServer.new
    middleware = BlockMiddleware.new do |ctx, _next_handler|
      ctx.response.status = HTTP::Status::UNAUTHORIZED
      ctx.response.print("unauthorized")
    end
    server.use_middleware(middleware)
    server.add_route("GET", "/secret") do |ctx|
      ctx.response.print("secret data")
    end
    port = server.start
    begin
      response = HTTP::Client.get("http://127.0.0.1:#{port}/secret")
      response.status_code.should eq(401)
      response.body.should eq("unauthorized")
    ensure
      server.stop
    end
  end
end
describe "request event emission" do
  it "emits a request event for every incoming request" do
    received_requests = [] of CrystKit::Features::ServerRequest
    server = CrystKit::Features::LocalhostServer.new
    server.on_request do |req|
      received_requests << req
    end
    server.add_route("GET", "/ping") do |ctx|
      ctx.response.print("pong")
    end
    port = server.start
    begin
      HTTP::Client.get("http://127.0.0.1:#{port}/ping")
      sleep 50.milliseconds
      received_requests.size.should eq(1)
      received_requests.first.method.should eq("GET")
      received_requests.first.path.should eq("/ping")
    ensure
      server.stop
    end
  end
  it "request event includes method, path, headers, and body" do
    received : CrystKit::Features::ServerRequest? = nil
    server = CrystKit::Features::LocalhostServer.new
    server.on_request do |req|
      received = req
    end
    server.add_route("POST", "/data") do |ctx|
      ctx.response.print("ok")
    end
    port = server.start
    begin
      headers = HTTP::Headers{"Content-Type" => "text/plain"}
      HTTP::Client.post("http://127.0.0.1:#{port}/data", headers: headers, body: "payload")
      sleep 50.milliseconds
      r = received
      r.should_not be_nil
      r = r.not_nil!
      r.method.should eq("POST")
      r.path.should eq("/data")
      r.body.should eq("payload")
      r.headers["Content-Type"]?.should_not be_nil
    ensure
      server.stop
    end
  end
  it "supports multiple request event handlers" do
    count1 = 0
    count2 = 0
    server = CrystKit::Features::LocalhostServer.new
    server.on_request { |_req| count1 += 1 }
    server.on_request { |_req| count2 += 1 }
    server.add_route("GET", "/") do |ctx|
      ctx.response.print("ok")
    end
    port = server.start
    begin
      HTTP::Client.get("http://127.0.0.1:#{port}/")
      sleep 50.milliseconds
      count1.should eq(1)
      count2.should eq(1)
    ensure
      server.stop
    end
  end
  it "continues processing if a request event handler raises an error" do
    server = CrystKit::Features::LocalhostServer.new
    server.on_request { |_req| raise "handler error" }
    server.add_route("GET", "/ok") do |ctx|
      ctx.response.print("still works")
    end
    port = server.start
    begin
      response = HTTP::Client.get("http://127.0.0.1:#{port}/ok")
      response.status_code.should eq(200)
      response.body.should eq("still works")
    ensure
      server.stop
    end
  end
end
describe "TLS/HTTPS server" do
  it "starts with TLS enabled using auto-generated self-signed cert" do
    server = CrystKit::Features::LocalhostServer.new
    options = CrystKit::Features::ServerOptions.new(tls_enabled: true)
    port = server.start(options)
    begin
      server.running?.should be_true
      port.should be > 0
      ctx = OpenSSL::SSL::Context::Client.insecure
      tcp = TCPSocket.new("127.0.0.1", port)
      socket = OpenSSL::SSL::Socket::Client.new(tcp, context: ctx)
      socket << "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
      socket.flush
      socket.gets
      socket.close
    ensure
      server.stop
    end
  end
  it "starts with TLS and serves routes" do
    server = CrystKit::Features::LocalhostServer.new
    server.add_route("GET", "/tls-test") do |ctx|
      ctx.response.content_type = "text/plain"
      ctx.response.print("tls-ok")
    end
    options = CrystKit::Features::ServerOptions.new(tls_enabled: true)
    port = server.start(options)
    begin
      ctx = OpenSSL::SSL::Context::Client.insecure
      tcp = TCPSocket.new("127.0.0.1", port)
      socket = OpenSSL::SSL::Socket::Client.new(tcp, context: ctx)
      socket << "GET /tls-test HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
      socket.flush
      status_line = socket.gets
      status_line.should_not be_nil
      status_line.not_nil!.should contain("200")
      socket.close
    ensure
      server.stop
    end
  end
  it "raises TLS_CONFIG_FAILED when cert files are specified but not found" do
    server = CrystKit::Features::LocalhostServer.new
    options = CrystKit::Features::ServerOptions.new(
      tls_enabled: true,
      tls_cert_path: Path.new("/nonexistent/cert.pem"),
      tls_key_path: Path.new("/nonexistent/key.pem"),
    )
    expect_raises(CrystKit::Core::NetworkError, /TLS/i) do
      server.start(options)
    end
  end
end

describe "ephemeral port allocation" do
  it "returns the actual OS-assigned port when asked for port 0" do
    server = CrystKit::Features::LocalhostServer.new
    options = CrystKit::Features::ServerOptions.new(port: 0, auto_port: false)
    port = server.start(options)
    begin
      port.should be > 0
      server.port.should eq(port)
      HTTP::Client.get("http://127.0.0.1:#{port}/").status_code.should eq(404)
    ensure
      server.stop
    end
  end
end

describe "static file prefix normalization" do
  it "accepts a prefix without a leading or trailing slash" do
    SpecHelpers.with_temp_dir do |dir|
      File.write(File.join(dir, "app.js"), "console.log('hi')")
      server = CrystKit::Features::LocalhostServer.new
      server.serve_static(Path[dir], prefix: "assets")
      port = server.start
      begin
        response = HTTP::Client.get("http://127.0.0.1:#{port}/assets/app.js")
        response.status_code.should eq(200)
        response.body.should eq("console.log('hi')")
      ensure
        server.stop
      end
    end
  end
end

describe "request event body handling" do
  it "leaves the request body readable by route handlers" do
    seen_by_event = ""
    body_seen_by_route = ""
    server = CrystKit::Features::LocalhostServer.new
    server.on_request { |req| seen_by_event = req.body }
    server.add_route("POST", "/echo") do |ctx|
      body_seen_by_route = ctx.request.body.try(&.gets_to_end) || ""
      ctx.response.print(body_seen_by_route)
    end
    port = server.start
    begin
      response = HTTP::Client.post("http://127.0.0.1:#{port}/echo", body: "payload")
      seen_by_event.should eq("payload")
      body_seen_by_route.should eq("payload")
      response.body.should eq("payload")
    ensure
      server.stop
    end
  end
end

describe "CORS configuration" do
  it "rejects wildcard origins combined with credentials" do
    server = CrystKit::Features::LocalhostServer.new
    options = CrystKit::Features::ServerOptions.new(
      cors: CrystKit::Features::CorsOptions.new(
        allow_origins: ["*"],
        allow_credentials: true
      )
    )

    error = expect_raises(CrystKit::Core::Error, /credential/i) do
      server.start(options)
    end
    error.code.should eq("INVALID_CORS_CONFIG")
    server.running?.should be_false
  end

  it "reflects an allowed origin and varies on it" do
    server = CrystKit::Features::LocalhostServer.new
    options = CrystKit::Features::ServerOptions.new(
      cors: CrystKit::Features::CorsOptions.new(allow_origins: ["https://app.example"])
    )
    port = server.start(options)
    begin
      response = HTTP::Client.exec(
        "GET",
        "http://127.0.0.1:#{port}/",
        headers: HTTP::Headers{"Origin" => "https://app.example"}
      )
      response.headers["Access-Control-Allow-Origin"]?.should eq("https://app.example")
      response.headers["Vary"]?.should eq("Origin")
      response.headers["Access-Control-Allow-Credentials"]?.should be_nil
    ensure
      server.stop
    end
  end

  it "does not grant an origin that is not configured" do
    server = CrystKit::Features::LocalhostServer.new
    options = CrystKit::Features::ServerOptions.new(
      cors: CrystKit::Features::CorsOptions.new(allow_origins: ["https://app.example"])
    )
    port = server.start(options)
    begin
      response = HTTP::Client.exec(
        "GET",
        "http://127.0.0.1:#{port}/",
        headers: HTTP::Headers{"Origin" => "https://evil.example"}
      )
      response.headers["Access-Control-Allow-Origin"]?.should be_nil
      response.headers["Access-Control-Allow-Methods"]?.should be_nil
    ensure
      server.stop
    end
  end

  it "answers a real preflight with 204" do
    server = CrystKit::Features::LocalhostServer.new
    options = CrystKit::Features::ServerOptions.new(
      cors: CrystKit::Features::CorsOptions.new(allow_origins: ["https://app.example"])
    )
    port = server.start(options)
    begin
      response = HTTP::Client.exec(
        "OPTIONS",
        "http://127.0.0.1:#{port}/api",
        headers: HTTP::Headers{
          "Origin"                        => "https://app.example",
          "Access-Control-Request-Method" => "GET",
        }
      )
      response.status_code.should eq(204)
      response.headers["Access-Control-Allow-Origin"]?.should eq("https://app.example")
    ensure
      server.stop
    end
  end

  it "does not treat a bare OPTIONS request as a preflight" do
    server = CrystKit::Features::LocalhostServer.new
    server.add_route("OPTIONS", "/probe") do |ctx|
      ctx.response.print("custom-options")
    end
    options = CrystKit::Features::ServerOptions.new(
      cors: CrystKit::Features::CorsOptions.new(allow_origins: ["https://app.example"])
    )
    port = server.start(options)
    begin
      response = HTTP::Client.exec("OPTIONS", "http://127.0.0.1:#{port}/probe")
      response.status_code.should eq(200)
      response.body.should eq("custom-options")
    ensure
      server.stop
    end
  end
end

describe "TLS option validation and temporary material" do
  it "rejects an incomplete certificate/key pair" do
    server = CrystKit::Features::LocalhostServer.new
    options = CrystKit::Features::ServerOptions.new(
      tls_enabled: true,
      tls_cert_path: Path.new("/nonexistent/cert.pem")
    )

    error = expect_raises(CrystKit::Core::NetworkError) do
      server.start(options)
    end
    error.code.should eq("TLS_CONFIG_INCOMPLETE")
    server.running?.should be_false
  end

  it "wraps malformed supplied TLS material as TLS_CONFIG_FAILED" do
    SpecHelpers.with_temp_dir do |dir|
      cert_path = Path[dir] / "cert.pem"
      key_path = Path[dir] / "key.pem"
      File.write(cert_path.to_s, "not a certificate")
      File.write(key_path.to_s, "not a key")

      server = CrystKit::Features::LocalhostServer.new
      error = expect_raises(CrystKit::Core::NetworkError) do
        server.start(CrystKit::Features::ServerOptions.new(
          tls_enabled: true,
          tls_cert_path: cert_path,
          tls_key_path: key_path
        ))
      end
      error.code.should eq("TLS_CONFIG_FAILED")
      server.running?.should be_false
    end
  end

  it "removes generated TLS material when startup fails" do
    SpecHelpers.with_temp_dir do |dir|
      tls_path = Path[dir]
      before = Dir.children(tls_path)
      blocker = TCPServer.new("127.0.0.1", 0)
      occupied = blocker.local_address.port
      begin
        server = CrystKit::Features::LocalhostServer.new
        expect_raises(CrystKit::Core::NetworkError) do
          server.start(CrystKit::Features::ServerOptions.new(
            port: occupied,
            auto_port: false,
            tls_enabled: true,
            tls_temp_dir: tls_path
          ))
        end
        (Dir.children(tls_path) - before).should be_empty
        server.running?.should be_false
        server.port.should be_nil
      ensure
        blocker.close
      end
    end
  end

  it "protects generated key material and removes it on stop" do
    SpecHelpers.with_temp_dir do |dir|
      tls_path = Path[dir]
      before = Dir.children(tls_path)
      server = CrystKit::Features::LocalhostServer.new
      server.start(CrystKit::Features::ServerOptions.new(
        tls_enabled: true,
        tls_temp_dir: tls_path
      ))
      generated = Dir.children(tls_path) - before
      begin
        generated.size.should eq(2)
        cert_name = generated.find(&.includes?("_cert")).not_nil!
        key_name = generated.find(&.includes?("_key")).not_nil!
        cert_path = tls_path / cert_name
        key_path = tls_path / key_name

        {% unless flag?(:win32) %}
          File.info(key_path).permissions.value.should eq(0o600)
        {% end %}

        cert = OpenSSL::X509::Certificate.new(File.read(cert_path))
        cert.extensions.map(&.oid).should contain("subjectAltName")
      ensure
        server.stop
      end

      generated.each { |name| File.exists?(tls_path / name).should be_false }
    end
  end
end

describe "server lifecycle and convenience helpers" do
  it "serve starts a static directory in one call" do
    SpecHelpers.with_temp_dir do |dir|
      File.write(File.join(dir, "index.html"), "<html>served</html>")
      server = CrystKit::Features::LocalhostServer.new
      port = server.serve(Path[dir])
      begin
        response = HTTP::Client.get("http://127.0.0.1:#{port}/")
        response.status_code.should eq(200)
        response.body.should eq("<html>served</html>")
      ensure
        server.stop
      end
    end
  end

  it "can restart on a new port after stop" do
    server = CrystKit::Features::LocalhostServer.new
    server.add_route("GET", "/") { |ctx| ctx.response.print("alive") }
    first = server.start
    server.stop
    second = server.start
    begin
      second.should_not eq(0)
      HTTP::Client.get("http://127.0.0.1:#{second}/").body.should eq("alive")
    ensure
      server.stop
    end
  end

  it "adds configured custom headers to every response" do
    server = CrystKit::Features::LocalhostServer.new
    server.start(CrystKit::Features::ServerOptions.new(
      custom_headers: {"X-Frame-Options" => "DENY"}
    ))
    begin
      response = HTTP::Client.get("http://127.0.0.1:#{server.port}/missing")
      response.headers["X-Frame-Options"]?.should eq("DENY")
    ensure
      server.stop
    end
  end
end

describe "route error handling" do
  it "returns 500 and keeps serving after a route raises" do
    server = CrystKit::Features::LocalhostServer.new
    server.add_route("GET", "/boom") { |_ctx| raise "route exploded" }
    server.add_route("GET", "/ok") { |ctx| ctx.response.print("ok") }
    port = server.start
    begin
      failed = HTTP::Client.get("http://127.0.0.1:#{port}/boom")
      failed.status_code.should eq(500)
      HTTP::Client.get("http://127.0.0.1:#{port}/ok").body.should eq("ok")
      server.running?.should be_true
    ensure
      server.stop
    end
  end
end

describe "static file containment" do
  {% unless flag?(:win32) %}
    it "refuses symlinks that escape the static root" do
      SpecHelpers.with_temp_dir do |dir|
        outside = File.tempname("crystkit_outside_secret")
        File.write(outside, "top secret")
        File.symlink(outside, File.join(dir, "escape.txt"))
        server = CrystKit::Features::LocalhostServer.new
        server.serve_static(Path[dir])
        port = server.start
        begin
          response = HTTP::Client.get("http://127.0.0.1:#{port}/escape.txt")
          response.status_code.should eq(403)
          response.body.should_not contain("top secret")
        ensure
          server.stop
          File.delete?(outside)
        end
      end
    end
  {% end %}

  it "serves nested files and directory indexes" do
    SpecHelpers.with_temp_dir do |dir|
      Dir.mkdir_p(File.join(dir, "nested"))
      File.write(File.join(dir, "nested", "index.html"), "nested index")
      server = CrystKit::Features::LocalhostServer.new
      server.serve_static(Path[dir], prefix: "/assets/")
      port = server.start
      begin
        HTTP::Client.get("http://127.0.0.1:#{port}/assets/nested").body.should eq("nested index")
        HTTP::Client.get("http://127.0.0.1:#{port}/assets/nested/").body.should eq("nested index")
      ensure
        server.stop
      end
    end
  end
end

describe "CORS response details" do
  it "uses the wildcard origin when credentials are not requested" do
    server = CrystKit::Features::LocalhostServer.new
    server.start(CrystKit::Features::ServerOptions.new(
      cors: CrystKit::Features::CorsOptions.new
    ))
    begin
      response = HTTP::Client.exec(
        "GET",
        "http://127.0.0.1:#{server.port}/",
        headers: HTTP::Headers{"Origin" => "https://anywhere.example"}
      )
      response.headers["Access-Control-Allow-Origin"]?.should eq("*")
      response.headers["Access-Control-Allow-Credentials"]?.should be_nil
    ensure
      server.stop
    end
  end

  it "emits credentials, exposed headers, and max-age for a configured origin" do
    server = CrystKit::Features::LocalhostServer.new
    server.start(CrystKit::Features::ServerOptions.new(
      cors: CrystKit::Features::CorsOptions.new(
        allow_origins: ["https://app.example"],
        allow_methods: ["GET", "POST"],
        allow_headers: ["X-Custom"],
        expose_headers: ["X-Request-Id"],
        allow_credentials: true,
        max_age: 600
      )
    ))
    begin
      response = HTTP::Client.exec(
        "GET",
        "http://127.0.0.1:#{server.port}/",
        headers: HTTP::Headers{"Origin" => "https://app.example"}
      )
      response.headers["Access-Control-Allow-Origin"]?.should eq("https://app.example")
      response.headers["Access-Control-Allow-Credentials"]?.should eq("true")
      response.headers["Access-Control-Allow-Methods"]?.should eq("GET, POST")
      response.headers["Access-Control-Allow-Headers"]?.should eq("X-Custom")
      response.headers["Access-Control-Expose-Headers"]?.should eq("X-Request-Id")
      response.headers["Access-Control-Max-Age"]?.should eq("600")
    ensure
      server.stop
    end
  end
end

describe "TLS with caller-provided material" do
  it "serves HTTPS and leaves caller files in place" do
    SpecHelpers.with_self_signed_cert do |cert_path, key_path|
      server = CrystKit::Features::LocalhostServer.new
      port = server.start(CrystKit::Features::ServerOptions.new(
        tls_enabled: true,
        tls_cert_path: cert_path,
        tls_key_path: key_path
      ))
      begin
        ctx = OpenSSL::SSL::Context::Client.insecure
        tcp = TCPSocket.new("127.0.0.1", port)
        socket = OpenSSL::SSL::Socket::Client.new(tcp, context: ctx)
        socket << "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        socket.flush
        socket.gets.not_nil!.should contain("404")
        socket.close
      ensure
        server.stop
      end
      File.exists?(cert_path).should be_true
      File.exists?(key_path).should be_true
    end
  end
end

describe "percent-encoded request paths" do
  it "serves static files whose names contain spaces" do
    SpecHelpers.with_temp_dir do |dir|
      File.write(File.join(dir, "my file.txt"), "space file")
      server = CrystKit::Features::LocalhostServer.new
      server.serve_static(Path[dir])
      port = server.start
      begin
        response = HTTP::Client.get("http://127.0.0.1:#{port}/my%20file.txt")
        response.status_code.should eq(200)
        response.body.should eq("space file")
      ensure
        server.stop
      end
    end
  end

  it "decodes the path before matching routes" do
    seen_by_event = ""
    server = CrystKit::Features::LocalhostServer.new
    server.on_request { |req| seen_by_event = req.path }
    server.add_route("GET", "/hello world") { |ctx| ctx.response.print("decoded") }
    port = server.start
    begin
      response = HTTP::Client.get("http://127.0.0.1:#{port}/hello%20world")
      response.status_code.should eq(200)
      response.body.should eq("decoded")
      seen_by_event.should eq("/hello world")
    ensure
      server.stop
    end
  end

  it "returns 400 for malformed percent escapes" do
    server = CrystKit::Features::LocalhostServer.new
    port = server.start
    begin
      response = HTTP::Client.get("http://127.0.0.1:#{port}/bad%ZZ")
      response.status_code.should eq(400)
    ensure
      server.stop
    end
  end

  it "returns 400 for percent escapes that are not valid UTF-8" do
    server = CrystKit::Features::LocalhostServer.new
    port = server.start
    begin
      response = HTTP::Client.get("http://127.0.0.1:#{port}/bad%FF")
      response.status_code.should eq(400)
    ensure
      server.stop
    end
  end

  it "rejects encoded path traversal" do
    SpecHelpers.with_temp_dir do |dir|
      File.write(File.join(dir, "ok.txt"), "ok")
      server = CrystKit::Features::LocalhostServer.new
      server.serve_static(Path[dir])
      port = server.start
      begin
        response = HTTP::Client.get("http://127.0.0.1:#{port}/%2e%2e/%2e%2e/etc/passwd")
        response.status_code.should eq(403)
      ensure
        server.stop
      end
    end
  end
end

describe "request body limits" do
  it "rejects a Content-Length body above max_request_body with 413" do
    server = CrystKit::Features::LocalhostServer.new
    server.add_route("POST", "/echo") { |ctx| ctx.response.print(ctx.request.body.try(&.gets_to_end) || "") }
    port = server.start(CrystKit::Features::ServerOptions.new(max_request_body: 10))
    begin
      response = HTTP::Client.post("http://127.0.0.1:#{port}/echo", body: "12345678901")
      response.status_code.should eq(413)
    ensure
      server.stop
    end
  end

  it "rejects a chunked body that crosses max_request_body with 413" do
    server = CrystKit::Features::LocalhostServer.new
    server.add_route("POST", "/echo") { |ctx| ctx.response.print(ctx.request.body.try(&.gets_to_end) || "") }
    port = server.start(CrystKit::Features::ServerOptions.new(max_request_body: 10))
    socket = nil
    begin
      socket = TCPSocket.new("127.0.0.1", port)
      socket << "POST /echo HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
      socket << "5\r\nhello\r\n8\r\nworld!!!\r\n0\r\n\r\n"
      socket.flush
      response = socket.gets_to_end
      response.should contain("413")
    ensure
      socket.try(&.close)
      server.stop
    end
  end

  it "allows a body exactly at the limit" do
    server = CrystKit::Features::LocalhostServer.new
    server.add_route("POST", "/echo") { |ctx| ctx.response.print(ctx.request.body.try(&.gets_to_end) || "") }
    port = server.start(CrystKit::Features::ServerOptions.new(max_request_body: 10))
    begin
      response = HTTP::Client.post("http://127.0.0.1:#{port}/echo", body: "1234567890")
      response.status_code.should eq(200)
      response.body.should eq("1234567890")
    ensure
      server.stop
    end
  end

  it "disables the limit when max_request_body is nil" do
    server = CrystKit::Features::LocalhostServer.new
    server.add_route("POST", "/echo") { |ctx| ctx.response.print(ctx.request.body.try(&.gets_to_end) || "") }
    port = server.start(CrystKit::Features::ServerOptions.new(max_request_body: nil))
    begin
      response = HTTP::Client.post("http://127.0.0.1:#{port}/echo", body: "12345678901")
      response.status_code.should eq(200)
    ensure
      server.stop
    end
  end

  it "rejects a negative max_request_body at startup" do
    server = CrystKit::Features::LocalhostServer.new
    error = expect_raises(CrystKit::Core::Error) do
      server.start(CrystKit::Features::ServerOptions.new(max_request_body: -1))
    end
    error.code.should eq("INVALID_BODY_LIMIT")
    server.running?.should be_false
  end
end

describe "rapid TLS lifecycle" do
  it "finishes repeated TLS start/stop cycles without deadlocking" do
    done = Channel(Nil).new
    failed = Channel(Exception).new

    spawn do
      begin
        5.times do
          server = CrystKit::Features::LocalhostServer.new
          server.start(CrystKit::Features::ServerOptions.new(port: 0, tls_enabled: true))
          server.stop
        end
        done.send nil
      rescue ex
        failed.send ex
      end
    end

    select
    when done.receive
      # success
    when ex = failed.receive
      raise ex
    when timeout(15.seconds)
      fail "rapid TLS start/stop hung"
    end
  end
end

describe "accept timeout isolation" do
  it "does not apply the accept poll timeout to keep-alive connections" do
    server = CrystKit::Features::LocalhostServer.new
    server.add_route("GET", "/") { |ctx| ctx.response.print("ok") }
    port = server.start(CrystKit::Features::ServerOptions.new(port: 0))
    client = HTTP::Client.new("127.0.0.1", port)
    begin
      client.get("/").status_code.should eq(200)
      sleep 300.milliseconds
      client.get("/").status_code.should eq(200)
    ensure
      client.close
      server.stop
    end
  end
end

describe "rapid start/stop lifecycle" do
  it "finishes repeated start/stop cycles without deadlocking" do
    done = Channel(Nil).new
    failed = Channel(Exception).new

    spawn do
      begin
        25.times do
          server = CrystKit::Features::LocalhostServer.new
          server.start(CrystKit::Features::ServerOptions.new(port: 0))
          server.stop
        end
        done.send nil
      rescue ex
        failed.send ex
      end
    end

    select
    when done.receive
      # success
    when ex = failed.receive
      raise ex
    when timeout(10.seconds)
      fail "rapid start/stop hung"
    end
  end
end
