# Traffic Watcher

A native macOS debugging proxy for app developers, with HTTP(S) and MQTT as equal citizens.

## Status

Early development. The MQTT decoder and the capture proxy engine are in place; TLS interception, storage and the macOS app come next.

## Layout

| Module | What it does |
| --- | --- |
| `MQTTCore` | Packet model, MQTT 5 properties, packet decoder, streaming decoder for chunked TCP or WebSocket data, and `MQTTSession`, which tracks the protocol version, client ID and per-direction topic aliases for one connection |
| `ProxyCore` | SwiftNIO engine. `HTTPProxyServer` forwards plain HTTP and records each exchange, and relays HTTPS `CONNECT` tunnels untouched. `MQTTForwarder` relays a local port to one broker and decodes every packet. Events go to a `CaptureSink` such as `CaptureLog` or `AsyncStreamCaptureSink` |

Planned next: `TLSMitm` (CA and leaf certificates to decrypt tunnels), MQTT over WebSocket, `Store` (SQLite capture log) and the SwiftUI app.

### Try the MQTT forwarder

```swift
let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
let sink = AsyncStreamCaptureSink()
let forwarder = MQTTForwarder(group: group, sink: sink, brokerHost: "test.mosquitto.org", brokerPort: 1883)
try await forwarder.start(port: 18830) // point your app at localhost:18830
for await event in sink.events { print(event) }
```

## Develop

Requires Swift 6.0 or later. The core packages build on macOS 14+ and Linux.

```sh
swift test
```
