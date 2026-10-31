# Traffic Watcher

A native macOS debugging proxy for app developers, with HTTP(S) and MQTT as equal citizens.

## Status

Early scaffold. The first module, `MQTTCore`, decodes MQTT 3.1.1 and 5.0 control packets from raw byte streams.

## Layout

| Module | What it does |
| --- | --- |
| `MQTTCore` | Packet model, MQTT 5 properties, packet decoder, streaming decoder for chunked TCP or WebSocket data, and `MQTTSession`, which tracks the protocol version, client ID and per-direction topic aliases for one connection |

Planned next: `ProxyCore` (SwiftNIO HTTP/HTTPS proxy), `TLSMitm` (CA and leaf certificates), `Store` (SQLite capture log) and the SwiftUI app.

## Develop

Requires Swift 6.0 or later. The core packages build on macOS 14+ and Linux.

```sh
swift test
```
