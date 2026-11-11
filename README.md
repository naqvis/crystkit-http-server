# crystkit-http-server

[![CI](https://github.com/naqvis/crystkit-http-server/actions/workflows/ci.yml/badge.svg)](https://github.com/naqvis/crystkit-http-server/actions/workflows/ci.yml)

Local HTTP server and TLS certificate pinning for [CrystKit](https://github.com/naqvis/crystkit).

It adds:

- `CrystKit::Features::LocalhostServer` - an in-process HTTP server with routes, middleware, static files, CORS, TLS, and request events.
- `CrystKit::Features::CertificatePinner` - RFC 7469 SPKI-based TLS certificate pinning.
- `CrystKit::Plugins::Server` - an IPC plugin exposing `server.start`, `server.stop`, and `server.status`, gated by the `server:manage` capability.

## Installation

Add to your `shard.yml`:

```yaml
dependencies:
  crystkit-http-server:
    github: naqvis/crystkit-http-server
```

Run `shards install`.

## Local HTTP server

```crystal
require "crystkit"
require "crystkit-http-server"

server = CrystKit::Features::LocalhostServer.new
server.add_route("GET", "/ping") { |ctx| ctx.response.print("pong") }
port = server.start
puts "listening on http://127.0.0.1:#{port}"
```

`#start` returns the actual bound port and always reports it through `#port`. A `nil` port (the default) selects a free port from the ephemeral range; `0` asks the OS for an ephemeral port. A busy explicitly requested port raises `Core::NetworkError` with code `PORT_IN_USE` unless `auto_port` is enabled, in which case the next free port is selected.

```crystal
options = CrystKit::Features::ServerOptions.new(port: 0)
port = server.start(options)
```

The server binds to `127.0.0.1` by default. Binding `0.0.0.0` through `Features::LocalhostServer` is possible, but exposes the process to the network; the IPC plugin deliberately rejects non-loopback hosts.

Routes match the method and path exactly; use `"*"` as the method or a trailing `/*` in the path for simple wildcards. `use_middleware` handlers run in registration order before route/static dispatch, and `on_request` callbacks run before dispatch. Configure routes, middleware, static files, and request events before calling `#start`.

### Server options

| Option                           | Default       | Meaning                                                                                                                           |
| -------------------------------- | ------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `port`                           | `nil`         | `nil` selects a free port from the ephemeral range; `0` asks the OS for an ephemeral port; any other value is the requested port. |
| `auto_port`                      | `true`        | When a requested port is busy, select another free port instead of raising `PORT_IN_USE`.                                         |
| `host`                           | `"127.0.0.1"` | Bind address. Prefer loopback unless you intentionally expose the server.                                                         |
| `log_requests`                   | `false`       | Log each request line and lifecycle transitions.                                                                                  |
| `max_request_body`               | `16 MiB`      | Maximum request body in bytes. Larger `Content-Length` values or streaming bodies return `413`; set `nil` to disable the limit.   |
| `cors`                           | `nil`         | Optional `CorsOptions` instance.                                                                                                  |
| `custom_headers`                 | `{}`          | Headers added to every response.                                                                                                  |
| `tls_enabled`                    | `false`       | Serve HTTPS.                                                                                                                      |
| `tls_cert_path` / `tls_key_path` | `nil`         | PEM certificate/key pair. When both are omitted, a self-signed localhost certificate is generated.                                |
| `tls_temp_dir`                   | `nil`         | Directory for generated TLS material. Defaults to the system temp directory; files are removed on stop.                           |

### Static files

```crystal
server.serve_static(Path["./public"], prefix: "/assets")
```

Prefixes are normalised, so `"assets"`, `"assets/"`, `"/assets"`, and `"/assets/"` are equivalent. Request paths are percent-decoded before route matching and static lookup, so files with spaces and other escaped characters work; malformed escapes return `400`, and encoded traversal attempts return `403`. Directory requests try `index.html`; missing files return `404`; path traversal and symlinks that resolve outside the static root return `403`.

### Middleware and request events

```crystal
server.use_middleware(MyAuthMiddleware.new)
server.on_request do |req|
  puts "#{req.method} #{req.path}: #{req.body}"
end
```

`ServerRequest#body` is a snapshot of the request body. The server restores the body afterwards, so route handlers can still read the original payload. Reading the body for events buffers the payload in memory; `max_request_body` (default 16 MiB) caps how much can be read. Set `max_request_body: nil` to disable the cap, and avoid enabling request events on untrusted public interfaces.

### CORS

```crystal
server.start(CrystKit::Features::ServerOptions.new(
  cors: CrystKit::Features::CorsOptions.new(
    allow_origins: ["https://app.example"],
    allow_credentials: true
  )
))
```

Only configured origins receive `Access-Control-Allow-*` headers. Real preflight requests (`OPTIONS` with an `Origin` header) receive `204`; bare `OPTIONS` requests still reach custom routes. The invalid combination of wildcard origins and `allow_credentials` is rejected at startup with `INVALID_CORS_CONFIG`.

### TLS

```crystal
# Self-signed certificate for local development.
server.start(CrystKit::Features::ServerOptions.new(tls_enabled: true))

# Or supply a certificate chain and private key.
server.start(CrystKit::Features::ServerOptions.new(
  tls_enabled: true,
  tls_cert_path: Path["cert.pem"],
  tls_key_path: Path["key.pem"]
))
```

Generated certificates include `DNS:localhost` and `IP:127.0.0.1` subject alternative names. The generated private key is written with owner-only permissions (`0600`) and both temporary files are removed when the server stops. Generated material goes to `tls_temp_dir` when set, otherwise the system temp directory. Supplying only one of `tls_cert_path` / `tls_key_path` raises `TLS_CONFIG_INCOMPLETE`.

## Certificate pinning

Pins are standard RFC 7469 SPKI hashes: base64-encoded SHA-256 digests of the certificate's raw SubjectPublicKeyInfo DER, formatted as `sha256/<base64>`. They match pins produced by OpenSSL and other pinning tooling:

```sh
openssl x509 -in cert.pem -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary \
  | openssl base64 -A
```

```crystal
pinner = CrystKit::Features::CertificatePinner.new
pinner.pin("example.com", "sha256/UFIPBLCdwpL/DP3TtuRyzMrgBmuDyS/1E7wkvrZuDB4=")

# Pin directly from a trusted certificate, then open a real TLS connection:
pinner.pin_certificate("example.com", trusted_certificate)

tcp = TCPSocket.new("example.com", 443)
socket = OpenSSL::SSL::Socket::Client.new(
  tcp,
  context: OpenSSL::SSL::Context::Client.new,
  hostname: "example.com"
)

cert = socket.peer_certificate
pinner.verify_certificate("example.com", cert)  # leaf certificate
pinner.verify_chain("example.com", [cert])      # or a full chain, if available
pinner.verify_peer("example.com", socket)       # or verify the live socket

# The verified socket can be reused for HTTP:
client = HTTP::Client.new(socket, "example.com", 443)
```

- Hosts are matched case-insensitively.
- Multiple pins per host are supported for key rotation; verification succeeds if any presented hash matches any configured pin.
- A pin mismatch raises `Core::SecurityError` with code `PINNING_FAILED`.
- Hosts with no pins pass verification (fail-open). Check `#pins_for` before connecting if you need fail-closed behavior.
- `#pin` rejects malformed values with `INVALID_PIN` and canonicalizes whitespace.
- `#pin_certificate` raises `INVALID_CERTIFICATE` if a certificate has no usable public key.
- `#all_pins` and `#pins_for` return isolated copies, so mutation cannot bypass the pinner. Pin mutations and verification are synchronized across fibers/threads.

`CertificatePinner` works with any `OpenSSL::SSL::Socket::Client`, including the socket reused by `HTTP::Client.new(io, host, port)`. `CrystKit::Features::HTTPClient` does not expose its live socket, so pinning with that client requires a custom TLS client or the lower-level path shown above.

## Plugin

```crystal
plugin = CrystKit::Plugins::Server.new
app.plugin(plugin)

# Configure routes, static files, middleware, or request events on the
# underlying feature server before the frontend starts it.
plugin.server.add_route("GET", "/health") { |ctx| ctx.response.print("ok") }
```

Grant the capability in your capabilities manifest:

```json
{
  "capabilities": ["server:manage"]
}
```

| Command         | Payload                                                 | Result                                                         |
| --------------- | ------------------------------------------------------- | -------------------------------------------------------------- |
| `server.start`  | `null`, `{}`, `{"port": 0}`, or `{"host": "127.0.0.1"}` | `{"port": <actual port>, "host": "<host>"}`                    |
| `server.stop`   | none                                                    | `null`                                                         |
| `server.status` | none                                                    | `{"running": <bool>, "port": <int or null>, "host": "<host>"}` |

- `port` omitted or `null` selects a free port from the ephemeral range; `0` requests an OS-assigned ephemeral port.
- `host` must be a loopback address (`127.0.0.1`, `localhost`, `::1`); `localhost` is normalised to `127.0.0.1`, and anything else is rejected with `HOST_NOT_ALLOWED`.
- Calling `server.start` while the server is running stops and rebinds it.
- Invalid payload shapes, non-integer ports, and ports outside `0..65535` are rejected with `BAD_REQUEST`.

```js
const { port } = await ipc.invoke("server.start", { port: 0 });
await fetch(`http://127.0.0.1:${port}/`);
await ipc.invoke("server.stop");
```

## Error codes

Failures raise `CrystKit::Core::Error` (or one of its subclasses) with a stable `code`:

| Code                    | Raised by                                                                       |
| ----------------------- | ------------------------------------------------------------------------------- |
| `ALREADY_RUNNING`       | `LocalhostServer#start` when the feature-level server is already running.       |
| `PORT_IN_USE`           | `LocalhostServer#start` when a requested port is busy and `auto_port` is false. |
| `NO_PORT_AVAILABLE`     | No free port was found in the ephemeral range.                                  |
| `DIR_NOT_FOUND`         | `serve_static` with a missing directory.                                        |
| `INVALID_BODY_LIMIT`    | `max_request_body` was negative.                                                |
| `INVALID_CORS_CONFIG`   | Wildcard origins combined with `allow_credentials`.                             |
| `TLS_CONFIG_INCOMPLETE` | Only one of `tls_cert_path` / `tls_key_path` was supplied.                      |
| `TLS_CERT_NOT_FOUND`    | The supplied certificate or key file does not exist.                            |
| `TLS_CONFIG_FAILED`     | The TLS context could not be configured.                                        |
| `HOST_NOT_ALLOWED`      | The plugin was asked to bind a non-loopback host.                               |
| `BAD_REQUEST`           | The plugin received an invalid payload or port.                                 |
| `INVALID_PIN`           | A pin is not a `sha256/` base64 SHA-256 hash.                                   |
| `INVALID_CERTIFICATE`   | A certificate's public key could not be encoded as SPKI.                        |
| `PINNING_FAILED`        | Presented certificate hashes did not match the configured pins.                 |

## Development

Run the specs with:

```sh
crystal spec
```

## License

MIT

## Contributors

- [Ali Naqvi](https://github.com/naqvis) - creator and maintainer
