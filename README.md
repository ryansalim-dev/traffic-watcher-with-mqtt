# Traffic Watcher

A native macOS debugging proxy for app developers, with HTTP(S) and MQTT as equal citizens.

## Status

Early development. The MQTT decoder, the capture proxy engine, HTTPS interception, MQTT over WebSocket and TLS, the capture store and a first version of the macOS app are in place.

## Layout

| Module | What it does |
| --- | --- |
| `MQTTCore` | Packet model, MQTT 5 properties, packet decoder, streaming decoder for chunked TCP or WebSocket data, and `MQTTSession`, which tracks the protocol version, client ID and per-direction topic aliases for one connection |
| `TLSMitm` | `CertificateAuthority` generates a local root (P-256, PEM/DER export) and issues per-host leaf certificates for DNS names or IPs. `TLSInterceptor` caches a TLS context per host and holds the bypass list for pinned hosts |
| `ProxyCore` | SwiftNIO engine. `HTTPProxyServer` forwards plain HTTP and records each exchange. With an interceptor configured it decrypts `CONNECT` tunnels and records HTTPS exchanges too; bypassed hosts are relayed untouched, and clients that reject the certificate are reported. WebSocket upgrades (over HTTP or decrypted HTTPS) are relayed with every frame decoded: `mqtt*` subprotocols produce MQTT events, others produce `webSocketMessage` events. `MQTTForwarder` relays a local port to one broker, optionally terminating and re-encrypting TLS, and decodes every packet. Events go to a `CaptureSink` such as `CaptureLog` or `AsyncStreamCaptureSink` |
| `CaptureStore` | SQLite store and `CaptureSink`. Groups events into sessions, keeps MQTT as raw frames that are decoded again on load, searches URLs, headers, text bodies, topics and payloads with FTS5, and exports HAR 1.2 and MQTT JSON Lines |
| `Licensing` | Pro licenses through the Lemon Squeezy License API (activate, validate, deactivate), with no backend of our own. Keys for other stores or products are refused. `Entitlement.evaluate` applies the rules: a license covers versions released within 12 months of purchase, keeps working offline for 30 days after the last check, and the free tier keeps the 3 newest sessions. Stored in the keychain |
| `AppCore` | Everything behind the app that doesn't need SwiftUI, so it is tested on Linux too: `CaptureEngine` (proxy plus MQTT forwarders on one event loop group), `CertificateStorage`, `CaptureViewModel`, the MQTT `TopicTree`, body formatting and `SampleTraffic` |
| `TrafficWatcherApp` | The SwiftUI app: timeline with sections and search, inspectors for HTTP, MQTT and WebSocket, a live MQTT topic tree, a one-click bypass for pinned hosts, settings for the proxy, MQTT brokers and the root certificate (including installing it in the Simulator), and HAR and MQTT exports |

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

Requires Swift 6.0 or later. The core packages build on macOS 14+ and Linux (install `libsqlite3-dev` on Linux).

```sh
swift test
```

Run the app on macOS:

```sh
swift run TrafficWatcher
```

### Package the app

```sh
scripts/build-app.sh          # dist/TrafficWatcher.app and a zip, universal, ad hoc signed
```

The script takes its settings from environment variables (version, signing identity, Sparkle feed and key, Lemon Squeezy IDs, notarization credentials); they are listed at the top of the script. CI builds the bundle on every pull request and takes the screenshots from it. Pushing a `v*` tag runs `.github/workflows/release.yml`, which signs with Developer ID, notarizes, publishes a GitHub release and adds it to the Sparkle appcast on GitHub Pages. The secrets it needs are listed at the top of that file.

Release builds read `TWLemonSqueezyStoreID`, `TWLemonSqueezyProductIDs`, `TWPurchaseURL` and `TWReleaseDate` (`yyyy-MM-dd`) from Info.plist. Without them, as with `swift run`, Pro activation is off.

`TrafficWatcher --screenshots <dir>` loads sample traffic and writes PNGs of the main screens. CI runs it on every pull request and uploads the result as the `screenshots` artifact.

## Landing page

`site/` is the static landing page for the public name, Wiretide, published to GitHub Pages (the `gh-pages` branch, next to the Sparkle appcast) by `.github/workflows/site.yml` on every push to `main` that touches it. Download, checkout and waitlist links are set in `site/config.js`. Preview locally with `python3 -m http.server -d site`.
