# Wiretide

A native macOS debugging proxy for app developers, with HTTP(S) and MQTT as equal citizens.

## Status

Feature-complete for v1.0 and not yet released: the first release waits on Developer ID signing and notarization.

- **Free:** capture and inspect HTTP, HTTPS, WebSocket and MQTT (TCP, TLS and WebSockets), a live MQTT topic tree, full-text search, HAR and MQTT exports, and one saved session next to the one recording.
- **Pro** (one-time purchase with 12 months of updates): breakpoints, Map Local, Map Remote and Rewrite for HTTP, MQTT message rewrites, JavaScript scripting, MQTT publish and replay, and unlimited saved sessions.

## Layout

| Module | What it does |
| --- | --- |
| `MQTTCore` | Packet model, MQTT 5 properties, packet decoder, streaming decoder for chunked TCP or WebSocket data, an encoder for the packets a client sends, and `MQTTSession`, which tracks the protocol version, client ID and per-direction topic aliases for one connection |
| `TLSMitm` | `CertificateAuthority` generates a local root (P-256, PEM/DER export) and issues per-host leaf certificates for DNS names or IPs. `TLSInterceptor` caches a TLS context per host and holds the bypass list for pinned hosts |
| `ProxyCore` | SwiftNIO engine. `HTTPProxyServer` forwards plain HTTP and records each exchange. With an interceptor configured it decrypts `CONNECT` tunnels and records HTTPS exchanges too; bypassed hosts are relayed untouched, and clients that reject the certificate are reported. WebSocket upgrades (over HTTP or decrypted HTTPS) are relayed with every frame decoded: `mqtt*` subprotocols produce MQTT events, others produce `webSocketMessage` events. `MQTTForwarder` relays a local port to one broker, optionally terminating and re-encrypting TLS, and decodes every packet. `MQTTPublisher` connects to a broker as a client (3.1.1 or 5, optional TLS) and publishes at QoS 0, 1 or 2, feeding its own traffic into the capture. `gzip` and `deflate` bodies are decoded so captures, rules and scripts see the real content, and each exchange records DNS, connect, TLS, waiting and download timings. `BreakpointRule` and `HTTPBreakpointHandler` let the proxy pause matching requests and responses for editing or aborting. `HTTPRule` (Map Local, Map Remote, Rewrite) and `MQTTRule` (topic, payload and retain rewrites on relayed PUBLISH packets) change traffic on the way through. `UserScript`, `LiveScripts` and `ScriptRunner` run JavaScript hooks on requests, responses and MQTT PUBLISH packets; `JavaScriptEngine` runs them in JavaScriptCore on Apple platforms (elsewhere scripts are kept but don't run). Events go to a `CaptureSink` such as `CaptureLog` or `AsyncStreamCaptureSink` |
| `CaptureStore` | SQLite store and `CaptureSink`. Groups events into sessions, keeps MQTT as raw frames that are decoded again on load, searches URLs, headers, text bodies, topics and payloads with FTS5, and exports HAR 1.2 and MQTT JSON Lines |
| `Licensing` | Pro licenses behind a `LicenseProvider` protocol (activate, validate, deactivate), with no backend of our own. `LemonSqueezyClient` is the provider in use; another store only needs a new conformance, and each saved license remembers which store issued it. Keys for other stores or products are refused. `Entitlement.evaluate` applies the rules: a license covers versions released within 12 months of purchase, keeps working offline for 30 days after the last check, and the free tier keeps one saved session next to the one recording (starting another asks before replacing it; nothing is deleted on its own). Stored in the keychain |
| `HelperCore`, `WiretideHelper` | A root helper the app installs with `SMAppService`. While capturing, it points the HTTP and HTTPS proxy of every enabled network service at Wiretide. It changes only those keys, keeps a backup on disk, and restores the previous settings when capture stops, when the app quits or crashes (the XPC connection closes), or at the next boot. It accepts connections only from the Wiretide app signed by the same team |
| `AppCore` | Everything behind the app that doesn't need SwiftUI, so it is tested on Linux too: `CaptureEngine` (proxy plus MQTT forwarders on one event loop group), `CertificateStorage`, `CaptureViewModel`, the MQTT `TopicTree`, body formatting, `SampleTraffic`, and the Pro tools' state: `BreakpointCenter` (rules and paused exchanges), `MQTTComposer` (publish and replay), `RewriteCenter` (map and rewrite rules) and `ScriptCenter` (scripts, templates and the console) |
| `WiretideApp` | The SwiftUI app: timeline with sections and search, inspectors for HTTP, MQTT and WebSocket, a live MQTT topic tree, a one-click bypass for pinned hosts, the Saved Sessions window, settings for the proxy, MQTT brokers, the root certificate (including installing it in the Simulator) and the license, HAR and MQTT exports, Sparkle updates, and the Pro tools: a breakpoint editor for paused requests and responses, breakpoint rules, a Publish sheet that also replays captured messages, the Map & Rewrite window and the Scripts window. Header editors are a key-value table with a Raw text view. New screens use `Dropdown` and `DropdownMenu` from `Dropdown.swift` rather than stock `Picker` and `Menu` |

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

### Publish an MQTT message

```swift
let publisher = MQTTPublisher(group: group, sink: sink)   // sink: nil to skip capturing
let target = MQTTBrokerTarget(host: "test.mosquitto.org", version: .v5)
try await publisher.publish([MQTTOutgoingMessage(topic: "demo/hello", payload: Array("hi".utf8), qos: .atLeastOnce)], to: target)
```

### Script traffic (Pro)

Scripts are JavaScript. Each defines any of three functions, and Wiretide calls them for the requests and MQTT messages its URL pattern and topic filter match, after map and rewrite rules and before breakpoints:

```js
function onRequest(request) {            // method, url, host, path, query, headers, body, json
  request.headers["Authorization"] = "Bearer dev-token";
  if (request.query.mock === "empty") return respond({ status: 200, json: { items: [] } });
  return request;
}

function onResponse(request, response) { // status, headers, body, json
  if (response.json) response.json.user.plan = "pro";
  return response;
}

function onPublish(message) {            // topic, payload, json, retain; qos, direction, broker, clientId
  message.json.fahrenheit = message.json.celsius * 9 / 5 + 32;
  return message;
}
```

Headers read case-insensitively, and binary bodies come as `bodyBase64` / `payloadBase64`. `console.log` writes to the window's console. A call that runs longer than one second is stopped and the request goes on unchanged. Top-level variables keep their values until the script is edited. MQTT scripts apply to forwarders (TCP and TLS) and MQTT over WebSockets through the proxy; QoS and packet IDs are kept so acknowledgements still match.

## Develop

Requires Swift 6.0 or later. The core packages build on macOS 14+ and Linux (install `libsqlite3-dev` and `zlib1g-dev` on Linux).

```sh
swift test
```

Run the app on macOS:

```sh
swift run Wiretide
```

### Package the app

```sh
scripts/build-app.sh          # dist/Wiretide.app and a zip, universal, ad hoc signed
```

The script takes its settings from environment variables (version, signing identity, Sparkle feed and key, Lemon Squeezy IDs, notarization credentials); they are listed at the top of the script. CI builds the bundle and takes the screenshots from it on every push to `main`, and on demand for any branch (Actions → CI → Run workflow); pull requests run only the Linux tests, to save macOS minutes. Pushing a `v*` tag runs `.github/workflows/release.yml`, which signs with Developer ID, notarizes, publishes the zip as a release of the public `wiretide-releases` repo and adds it to the Sparkle appcast at wiretide.app. The tag's annotation (`git tag -a v1.0.0 -m "..."`) becomes the release notes. The secrets it needs are listed at the top of that file.

Release builds read `TWLemonSqueezyStoreID`, `TWLemonSqueezyProductIDs`, `TWPurchaseURL` and `TWReleaseDate` (`yyyy-MM-dd`) from Info.plist. Without them, as with `swift run`, Pro activation is off.

`Wiretide --screenshots <dir>` loads sample traffic and writes PNGs of the main screens. The macOS CI job runs it and uploads the result as the `screenshots` artifact.

## Landing page

`site/` is the static landing page for Wiretide, built on the `gh-pages` branch (next to the Sparkle appcast) and deployed to Cloudflare Pages with `scripts/deploy-site.sh` by `.github/workflows/site.yml` on every push to `main` that touches it. It includes the legal pages (`terms/`, `privacy/`, `eula/`, `fulfillment-policy/`). Download, checkout and waitlist links are set in `site/config.js`. Changes that touch only the site skip the app CI. Preview locally with `python3 -m http.server -d site`.
