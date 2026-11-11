require "./spec_helper"

private def with_server_app(& : CrystKit::Plugins::Server, CrystKit::Test::FakeFrontend ->)
  app = CrystKit::App.new(CrystKit::AppConfig.new)
  plugin = CrystKit::Plugins::Server.new
  app.plugin(plugin)
  frontend = CrystKit::Test::FakeFrontend.new(app)
  begin
    yield plugin, frontend
  ensure
    plugin.cleanup_plugin
    frontend.detach
  end
end

private def start_server(frontend : CrystKit::Test::FakeFrontend, payload : String = "{}") : Int32
  result = frontend.invoke("server.start", JSON.parse(payload))
  result.ok?.should be_true
  result.value.not_nil!["port"].as_i
end

describe CrystKit::Plugins::Server do
  it "requires server:manage for every command" do
    plugin = CrystKit::Plugins::Server.new
    plugin.metadata.commands.each do |command|
      plugin.metadata.ipc.commands[command].capability.should eq("server:manage")
    end
  end

  it "starts on an OS-assigned port when called without arguments" do
    with_server_app do |_plugin, frontend|
      port = start_server(frontend, "null")
      port.should be > 0

      response = HTTP::Client.get("http://127.0.0.1:#{port}/")
      response.status_code.should eq(404)

      status = frontend.invoke("server.status").value.not_nil!
      status["running"].as_bool.should be_true
      status["port"].as_i.should eq(port)
      status["host"].as_s.should eq("127.0.0.1")
    end
  end

  it "returns the actual bound port when the caller asks for port 0" do
    with_server_app do |_plugin, frontend|
      port = start_server(frontend, %({"port": 0}))
      port.should be > 0
      HTTP::Client.get("http://127.0.0.1:#{port}/").status_code.should eq(404)
    end
  end

  it "treats an explicit null port as auto-selection" do
    with_server_app do |_plugin, frontend|
      port = start_server(frontend, %({"port": null}))
      port.should be > 0
      HTTP::Client.get("http://127.0.0.1:#{port}/").status_code.should eq(404)
    end
  end

  it "rebinds instead of failing when start is called while running" do
    with_server_app do |_plugin, frontend|
      start_server(frontend, "{}")
      second = start_server(frontend, "{}")

      second.should be > 0
      HTTP::Client.get("http://127.0.0.1:#{second}/").status_code.should eq(404)
      frontend.invoke("server.status").value.not_nil!["port"].as_i.should eq(second)
    end
  end

  it "starts on an explicitly requested port" do
    with_server_app do |_plugin, frontend|
      requested = SpecHelpers.free_port
      port = start_server(frontend, %({"port": #{requested}}))
      port.should eq(requested)
      HTTP::Client.get("http://127.0.0.1:#{port}/").status_code.should eq(404)
    end
  end

  it "falls back to another port when the requested port is busy" do
    blocker = TCPServer.new("127.0.0.1", 0)
    occupied = blocker.local_address.port
    begin
      with_server_app do |_plugin, frontend|
        port = start_server(frontend, %({"port": #{occupied}}))
        port.should_not eq(occupied)
        HTTP::Client.get("http://127.0.0.1:#{port}/").status_code.should eq(404)
      end
    ensure
      blocker.close
    end
  end

  it "normalizes the localhost hostname to IPv4 loopback" do
    with_server_app do |_plugin, frontend|
      port = start_server(frontend, %({"host": "localhost"}))
      HTTP::Client.get("http://127.0.0.1:#{port}/").status_code.should eq(404)
      frontend.invoke("server.status").value.not_nil!["host"].as_s.should eq("127.0.0.1")
    end
  end

  it "treats an explicit null host as the loopback default" do
    with_server_app do |_plugin, frontend|
      port = start_server(frontend, %({"host": null}))
      HTTP::Client.get("http://127.0.0.1:#{port}/").status_code.should eq(404)
      frontend.invoke("server.status").value.not_nil!["host"].as_s.should eq("127.0.0.1")
    end
  end

  it "reports a stopped state before the first start" do
    with_server_app do |_plugin, frontend|
      status = frontend.invoke("server.status").value.not_nil!
      status["running"].as_bool.should be_false
      status["port"].raw.should be_nil
      status["host"].as_s.should eq("127.0.0.1")
    end
  end

  it "stops the running server during plugin cleanup" do
    with_server_app do |plugin, frontend|
      start_server(frontend, "{}")
      plugin.server.running?.should be_true
      plugin.cleanup_plugin
      plugin.server.running?.should be_false
      plugin.server.port.should be_nil
    end
  end

  it "stops safely before ever starting" do
    with_server_app do |_plugin, frontend|
      frontend.invoke("server.stop").ok?.should be_true
    end
  end

  it "rejects a non-integer port" do
    with_server_app do |_plugin, frontend|
      result = frontend.invoke("server.start", JSON.parse(%({"port": "8080"})))
      result.ok?.should be_false
      result.error.not_nil!.code.should eq("BAD_REQUEST")
    end
  end

  it "rejects a fractional port" do
    with_server_app do |_plugin, frontend|
      result = frontend.invoke("server.start", JSON.parse(%({"port": 8080.5})))
      result.ok?.should be_false
      result.error.not_nil!.code.should eq("BAD_REQUEST")
    end
  end

  it "rejects a non-string host" do
    with_server_app do |_plugin, frontend|
      result = frontend.invoke("server.start", JSON.parse(%({"host": 123})))
      result.ok?.should be_false
      result.error.not_nil!.code.should eq("BAD_REQUEST")
    end
  end

  it "rejects a negative port" do
    with_server_app do |_plugin, frontend|
      result = frontend.invoke("server.start", JSON.parse(%({"port": -1})))
      result.ok?.should be_false
      result.error.not_nil!.code.should eq("BAD_REQUEST")
    end
  end

  it "accepts an explicit loopback host" do
    with_server_app do |_plugin, frontend|
      port = start_server(frontend, %({"host": "127.0.0.1"}))
      HTTP::Client.get("http://127.0.0.1:#{port}/").status_code.should eq(404)
    end
  end

  it "refuses to bind a non-loopback interface" do
    with_server_app do |_plugin, frontend|
      result = frontend.invoke("server.start", JSON.parse(%({"host": "0.0.0.0"})))
      result.ok?.should be_false
      result.error.not_nil!.code.should eq("HOST_NOT_ALLOWED")
    end
  end

  it "rejects ports outside the TCP range" do
    with_server_app do |_plugin, frontend|
      result = frontend.invoke("server.start", JSON.parse(%({"port": 70000})))
      result.ok?.should be_false
      result.error.not_nil!.code.should eq("BAD_REQUEST")
    end
  end

  it "rejects a non-object payload" do
    with_server_app do |_plugin, frontend|
      result = frontend.invoke("server.start", JSON.parse(%(["8080"])))
      result.ok?.should be_false
      result.error.not_nil!.code.should eq("BAD_REQUEST")
    end
  end

  it "serves routes configured by the host application" do
    with_server_app do |plugin, frontend|
      plugin.server.add_route("GET", "/health") { |ctx| ctx.response.print("healthy") }
      port = start_server(frontend, "{}")
      response = HTTP::Client.get("http://127.0.0.1:#{port}/health")
      response.status_code.should eq(200)
      response.body.should eq("healthy")
    end
  end

  it "stops idempotently" do
    with_server_app do |_plugin, frontend|
      start_server(frontend, "{}")
      frontend.invoke("server.stop").ok?.should be_true
      frontend.invoke("server.stop").ok?.should be_true
      status = frontend.invoke("server.status").value.not_nil!
      status["running"].as_bool.should be_false
      status["port"].raw.should be_nil
    end
  end
end
