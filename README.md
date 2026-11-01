# Traffic Watcher

A native macOS debugging proxy for app developers, with HTTP(S) and MQTT as equal citizens.

## Status

Early development. The MQTT decoder, the capture proxy engine, HTTPS interception and MQTT over WebSocket and TLS are in place. Storage and the macOS app come next.

## Layout

| Module | What it does |
| --- | --- |
| `MQTTCore` | Packet model, MQTT 5 properties, packet decoder, streaming decoder for chunked TCP or WebSocket data, and `MQTTSession`, which tracks the protocol version, client ID and per-direction topic aliases for one connection |
| `TLSMitm` | `CertificateAuthority` generates a local root (P-256, PEM/DER export) and issues per-host leaf certificates for DNS names or IPs. `TLSInterceptor` caches a TLS context per host and holds the bypass list for pinned hosts |
| `ProxyCore` | SwiftNIO engine. `HTTPProxyServer` forwards plain HTTP and records each exchange. With an interceptor configured it decrypts `CONNECT` tunnels and records HTTPS exchanges too; bypassed hosts are relayed untouched, and clients that reject the certificate are reported. WebSocket upgrades (over HTTP or decrypted HTTPS) are relayed with every frame decoded: `mqtt*` subprotocols produce MQTT events, others produce `webSocketMessage` events. `MQTTForwarder` relays a local port to one broker, optionally terminating and re-encrypting TLS, and decodes every packet. Events go to a `CaptureSink` such as `CaptureLog` or `AsyncStreamCaptureSink` |

Planned next: `Store` (SQLite capture log) and the SwiftUI app.

### Decrypt HTTPS

```swift
let ca = try CertificateAuthority.generate()          // persist ca.certificatePEM / ca.privateKeyPEM
try ca.certificateDER                                  // install and trust on the device or Simulator
var configuration = HTTPProxyServer.Configuration()
configuration.interceptor = TLSInterceptor(authority: ca, bypass: ["*.pinned-bank.com"])
let proxy = HTTPProxyServer(group: group, sink: sink, configuration: configuration)
try await proxy.start(port: 9090)
```

### Try the MQTT forwarder

```swift
let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
let sink = AsyncStreamCaptureSink()
let forwarder = MQTTForwarder(group: group, sink: sink, brokerHost: "test.mosquitto.org", brokerPort: 1883)
try await forwarder.start(port: 18830) // point your app at localhost:18830
for await event in sink.events { print(event) }
```

For MQTT over TLS, pass `tls: .init(interceptor: interceptor)`. The port then defaults to 8883, and the app connects to `localhost` with the proxy's root CA trusted.

## Develop

Requires Swift 6.0 or later. The core packages build on macOS 14+ and Linux.

```sh
swift test
```
