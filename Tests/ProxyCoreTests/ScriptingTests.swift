import Foundation
import MQTTCore
import NIOCore
import NIOHTTP1
import NIOPosix
@testable import ProxyCore
import XCTest

/// An engine that answers from a closure, so the runner and the proxy are tested on every platform.
final class StubEngine: ScriptEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(hook: ScriptHook, script: String, input: String)] = []
    let answer: @Sendable (ScriptHook, UserScript, String) -> ScriptCallResult

    init(_ answer: @escaping @Sendable (ScriptHook, UserScript, String) -> ScriptCallResult) {
        self.answer = answer
    }

    var calls: [(hook: ScriptHook, script: String, input: String)] { lock.withLock { _calls } }

    func call(_ hook: ScriptHook, script: UserScript, input: String) -> ScriptCallResult {
        lock.withLock { _calls.append((hook, script.displayName, input)) }
        return answer(hook, script, input)
    }

    static func json(_ object: [String: Any]) -> ScriptCallResult {
        .output(String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
}

final class ScriptRunnerTests: XCTestCase {
    private let request = HTTPRequestDraft(
        method: "POST", url: "https://api.example.com/v2/login",
        headers: [CapturedHeader(name: "Host", value: "api.example.com"), CapturedHeader(name: "Content-Encoding", value: "gzip")],
        body: [0x1F, 0x8B, 0x00])

    func testRequestEditsAreAppliedAndNamed() {
        let engine = StubEngine { _, _, _ in
            StubEngine.json([
                "logs": [["log", "hello"], ["warn", "careful"]],
                "request": ["method": "put", "url": "https://api.example.com/v3/login",
                            "headers": [["Host", "api.example.com"], ["X-Debug", "1"], ["Bad:Name", "x"], ["X-Multi", "a\r\nb"]],
                            "body": ["text": "{}"]],
            ])
        }
        let script = UserScript(name: "Sign", source: "function onRequest(r) {}", urlPattern: "*")
        let result = ScriptRunner.runRequest(request, scripts: [script], engine: engine)
        XCTAssertEqual(result.request.method, "PUT")
        XCTAssertEqual(result.request.url, "https://api.example.com/v3/login")
        XCTAssertEqual(result.request.headers, [CapturedHeader(name: "Host", value: "api.example.com"),
                                                CapturedHeader(name: "X-Debug", value: "1"),
                                                CapturedHeader(name: "X-Multi", value: "a b")],
                       "invalid names are dropped, line breaks can't split headers, and a text body drops Content-Encoding")
        XCTAssertEqual(result.request.body, Array("{}".utf8))
        XCTAssertEqual(result.applied, ["Sign"])
        XCTAssertNil(result.response)
        XCTAssertEqual(result.logs.map(\.level), [.log, .warn])
        XCTAssertEqual(result.logs.first?.message, "hello")
        XCTAssertEqual(result.logs.first?.context, "onRequest · POST https://api.example.com/v2/login")
    }

    func testInputCarriesTextOnlyForPlainBodies() throws {
        let engine = StubEngine { _, _, _ in .output(#"{"skipped":true}"#) }
        let script = UserScript(name: "S", urlPattern: "*")
        _ = ScriptRunner.runRequest(request, scripts: [script], engine: engine)
        let compressed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(engine.calls[0].input.utf8)) as? [String: Any])
        let body = try XCTUnwrap((compressed["request"] as? [String: Any])?["body"] as? [String: Any])
        XCTAssertTrue(body["text"] is NSNull, "gzip bodies aren't offered as text")
        XCTAssertEqual(body["base64"] as? String, "H4sA")

        var plain = request
        plain.headers = []
        plain.body = Array("hi".utf8)
        _ = ScriptRunner.runRequest(plain, scripts: [script], engine: engine)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(engine.calls[1].input.utf8)) as? [String: Any])
        XCTAssertEqual(((input["request"] as? [String: Any])?["body"] as? [String: Any])?["text"] as? String, "hi")
    }

    func testRespondAnswersAndLaterScriptsDontRun() {
        let engine = StubEngine { _, script, _ in
            if script.name == "Mock" {
                return StubEngine.json([
                    "request": ["headers": [["Host", "api.example.com"]], "body": NSNull()],
                    "response": ["status": 418, "headers": [["Content-Type", "text/plain"], ["Content-Length", "99"]], "body": ["text": "teapot"]],
                ])
            }
            return .output(#"{"skipped":true}"#)
        }
        let scripts = [UserScript(name: "Mock", urlPattern: "*"), UserScript(name: "Later", urlPattern: "*")]
        let result = ScriptRunner.runRequest(request, scripts: scripts, engine: engine)
        XCTAssertEqual(result.response, HTTPResponseDraft(statusCode: 418, headers: [CapturedHeader(name: "Content-Type", value: "text/plain")],
                                                          body: Array("teapot".utf8)))
        XCTAssertEqual(result.answeredBy, "Mock")
        XCTAssertEqual(result.applied, ["Mock"])
        XCTAssertEqual(engine.calls.map(\.script), ["Mock"])
    }

    func testErrorsAndSkipsLeaveTrafficAlone() {
        let engine = StubEngine { _, script, _ in
            switch script.name {
            case "Throws": StubEngine.json(["logs": [["log", "before"]], "error": "TypeError: x is undefined", "line": 3])
            case "Broken": .failure("SyntaxError: Unexpected token", line: 1)
            default: .output("not json")
            }
        }
        let scripts = [UserScript(name: "Throws", urlPattern: "*"), UserScript(name: "Broken", urlPattern: "*"), UserScript(name: "Garbage", urlPattern: "*")]
        let result = ScriptRunner.runResponse(HTTPResponseDraft(statusCode: 200, headers: [], body: []), request: request,
                                              scripts: scripts, engine: engine)
        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(result.applied, [])
        XCTAssertEqual(result.logs.map(\.level), [.log, .error, .error, .error])
        XCTAssertEqual(result.logs[1].message, "onResponse: TypeError: x is undefined")
        XCTAssertEqual(result.logs[1].line, 3)
        XCTAssertEqual(result.logs[2].line, 1)
    }

    func testResponseStatusHeadersAndBase64Body() {
        let engine = StubEngine { _, _, _ in
            StubEngine.json(["response": ["status": 503, "headers": [["Content-Encoding", "br"]], "body": ["base64": "AAEC"]]])
        }
        let result = ScriptRunner.runResponse(HTTPResponseDraft(statusCode: 200, headers: [], body: [9]), request: request,
                                              scripts: [UserScript(name: "Down", urlPattern: "*")], engine: engine)
        XCTAssertEqual(result.response, HTTPResponseDraft(statusCode: 503, headers: [CapturedHeader(name: "Content-Encoding", value: "br")],
                                                          body: [0, 1, 2]), "raw bytes keep the encoding header the script set")
        XCTAssertEqual(result.applied, ["Down"])
    }

    func testPublishEditsTopicPayloadAndRetain() {
        let engine = StubEngine { _, _, input in
            XCTAssertTrue(input.contains(#""clientId":"ios-app""#), input)
            return StubEngine.json(["message": ["topic": "home/test/temperature", "retain": true, "payload": ["text": "42"]]])
        }
        let publish = MQTTPublish(topic: "home/kitchen/temperature", payload: Array("21".utf8), qos: .atLeastOnce, packetIdentifier: 7)
        let result = ScriptRunner.runPublish(publish, resolvedTopic: publish.topic, direction: .brokerToClient, broker: "b:1883",
                                             clientID: "ios-app", scripts: [UserScript(name: "Heat", topicFilter: "#")], engine: engine)
        XCTAssertEqual(result.publish.topic, "home/test/temperature")
        XCTAssertEqual(result.topic, "home/test/temperature")
        XCTAssertEqual(result.publish.payload, Array("42".utf8))
        XCTAssertTrue(result.publish.retain)
        XCTAssertEqual(result.publish.qos, .atLeastOnce)
        XCTAssertEqual(result.publish.packetIdentifier, 7, "acknowledgements still match")
        XCTAssertEqual(result.applied, ["Heat"])
    }

    func testPublishRefusesWildcardTopics() {
        let engine = StubEngine { _, _, _ in StubEngine.json(["message": ["topic": "home/+", "payload": NSNull()]]) }
        let publish = MQTTPublish(topic: "a", payload: [])
        let result = ScriptRunner.runPublish(publish, resolvedTopic: "a", direction: .clientToBroker, broker: "b", clientID: nil,
                                             scripts: [UserScript(name: "W", topicFilter: "#")], engine: engine)
        XCTAssertEqual(result.publish, publish)
        XCTAssertEqual(result.applied, [])
    }

    func testMatchingAndHookDetection() {
        let script = UserScript(name: "S", source: """
        function onRequest(request) { return request; }
        const onPublish = (message) => message;
        // function onResponse() {}  (only a comment, but the quick look still counts it)
        """, urlPattern: "api.example.com/*", method: "GET", topicFilter: "home/#", direction: .brokerToClient)
        XCTAssertEqual(script.definedHooks, [.request, .publish, .response])
        XCTAssertTrue(script.matches(method: "get", url: "https://api.example.com/v2/x"))
        XCTAssertFalse(script.matches(method: "POST", url: "https://api.example.com/v2/x"))
        XCTAssertTrue(script.matches(topic: "home/a", direction: .brokerToClient))
        XCTAssertFalse(script.matches(topic: "home/a", direction: .clientToBroker))
        XCTAssertFalse(UserScript(name: "No HTTP", topicFilter: "#").matches(method: "GET", url: "https://x"))

        let live = LiveScripts { _ in StubEngine { _, _, _ in .output("{}") } }
        live.update([script, UserScript(isEnabled: false, name: "Off", urlPattern: "*"), UserScript(name: "Nothing")])
        XCTAssertEqual(live.snapshot?.scripts.map(\.name), ["S"], "disabled scripts and scripts that match nothing are left out")
        XCTAssertEqual(live.snapshot?.scripts(for: .request, method: "GET", url: "https://api.example.com/a").count, 1)
        live.update([])
        XCTAssertNil(live.snapshot)
        XCTAssertEqual(try JSONDecoder().decode(UserScript.self, from: Data("{}".utf8)).direction, .both)
    }

    func testRelayRunsPublishScriptsAfterRules() throws {
        let log = CaptureLog()
        let rules = LiveRules(mqtt: [MQTTRule(name: "Rename", topicFilter: "a/b", operations: [
            MQTTRewriteOperation(target: .topic, action: .set, value: "a/c"),
        ])])
        let engine = StubEngine { _, _, input in
            XCTAssertTrue(input.contains(#""topic":"a\/c""#) || input.contains(#""topic":"a/c""#), "scripts see the rules' result: \(input)")
            return StubEngine.json(["message": ["payload": ["text": "HELLO"]]])
        }
        let scripts = LiveScripts { _ in engine }
        scripts.update([UserScript(name: "Shout", source: "function onPublish(m) {}", topicFilter: "a/#")])
        let relay = MQTTRelay(sink: log, broker: "b:1883", rules: rules, scripts: scripts)
        let connect: [UInt8] = [0x10, 0x13, 0x00, 0x04] + Array("MQTT".utf8) + [0x04, 0x02, 0x00, 0x3C, 0x00, 0x07] + Array("ios-app".utf8)
        _ = relay.relay(connect, from: .clientToBroker)
        let publish: [UInt8] = [0x30, 0x07, 0x00, 0x03] + Array("a/b".utf8) + [0x68, 0x69]
        let output = relay.relay(publish, from: .clientToBroker)
        let expected = try MQTTPacketEncoder.encode(.publish(MQTTPublish(topic: "a/c", payload: Array("HELLO".utf8))), version: .v3_1_1)
        XCTAssertEqual(output, expected)
        let recorded = log.events.compactMap { event -> MQTTCaptureEvent? in if case .mqtt(let e) = event { e } else { nil } }
        XCTAssertEqual(recorded.last?.rewrittenBy, ["Rename"])
        XCTAssertEqual(recorded.last?.scriptedBy, ["Shout"])
        XCTAssertEqual(recorded.last?.event.resolvedTopic, "a/c")
    }
}

final class ScriptProxyTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
    }

    private func run(_ scripts: [UserScript], engine: ScriptEngine) async throws -> (response: String, exchange: HTTPExchange?) {
        let upstream = try await startServer(group: group) { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(UpstreamHTTPHandler()) }
            }
        }
        let port = upstream.localAddress!.port!
        let log = CaptureLog()
        var configuration = HTTPProxyServer.Configuration()
        let live = LiveScripts { _ in engine }
        live.update(scripts)
        configuration.scripts = live
        let proxy = HTTPProxyServer(group: group, sink: log, configuration: configuration)
        let proxyPort = try await proxy.start()
        let client = try await RawClient.connect(port: proxyPort, group: group)
        try await client.send("POST http://127.0.0.1:\(port)/scripted HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n" +
                              "Content-Length: 5\r\nConnection: close\r\n\r\nhello")
        await eventually("client closed") { client.isClosed }
        await eventually("exchange recorded") { !log.events.isEmpty }
        try await proxy.stop()
        try await upstream.close()
        if case .httpExchange(let exchange)? = log.events.first { return (client.text, exchange) }
        return (client.text, nil)
    }

    func testRequestAndResponseScriptsChangeTheExchange() async throws {
        let engine = StubEngine { hook, _, input in
            switch hook {
            case .request:
                let object = try! JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
                let request = object["request"] as! [String: Any]
                var headers = request["headers"] as! [[String]]
                headers.append(["X-Script", "1"])
                return StubEngine.json(["request": ["headers": headers, "body": ["text": "bye"]]])
            case .response:
                return StubEngine.json(["response": ["status": 299, "headers": [["X-Changed", "yes"]], "body": NSNull()]])
            case .publish:
                return .output("{}")
            }
        }
        let script = UserScript(name: "Both", source: "function onRequest(){} function onResponse(){}", urlPattern: "*/scripted")
        let (response, exchange) = try await run([script], engine: engine)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 299"), response)
        XCTAssertTrue(response.contains("X-Changed: yes"), response)
        XCTAssertTrue(response.hasSuffix("body=bye"), response)
        XCTAssertEqual(exchange?.requestHeaders.last, CapturedHeader(name: "X-Script", value: "1"))
        XCTAssertEqual(exchange?.scriptedBy, ["Both"])
        XCTAssertNil(exchange?.mappedLocally)
        XCTAssertEqual(engine.calls.map(\.hook), [.request, .response])
    }

    func testRespondNeverContactsTheServer() async throws {
        let engine = StubEngine { hook, _, _ in
            hook == .request
                ? StubEngine.json(["request": [:] as [String: Any], "response": ["status": 202, "headers": [] as [Any], "body": ["text": "local"]]])
                : .output(#"{"skipped":true}"#)
        }
        let script = UserScript(name: "Mock", source: "function onRequest(){}", urlPattern: "*")
        let (response, exchange) = try await run([script], engine: engine)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 202"), response)
        XCTAssertFalse(response.contains("X-Upstream"), response)
        XCTAssertTrue(response.hasSuffix("local"), response)
        XCTAssertEqual(exchange?.mappedLocally, true)
        XCTAssertEqual(exchange?.answeredByScript, true)
        XCTAssertEqual(exchange?.scriptedBy, ["Mock"])
    }

    func testScriptsWithoutTheHookAreNotCalled() async throws {
        let engine = StubEngine { _, _, _ in .output("{}") }
        let script = UserScript(name: "MQTT only", source: "function onPublish(m) {}", urlPattern: "*")
        let (response, exchange) = try await run([script], engine: engine)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 201"), response)
        XCTAssertNil(exchange?.scriptedBy)
        XCTAssertTrue(engine.calls.isEmpty)
    }
}

#if canImport(JavaScriptCore)
/// The real runtime: the prelude and the user's JavaScript in JavaScriptCore.
final class JavaScriptEngineTests: XCTestCase {
    private let request = HTTPRequestDraft(
        method: "GET", url: "https://api.example.com/v2/devices?room=kitchen&page=1",
        headers: [CapturedHeader(name: "Accept", value: "application/json"), CapturedHeader(name: "Cookie", value: "a=1"),
                  CapturedHeader(name: "cookie", value: "b=2")],
        body: [])

    private func script(_ source: String, name: String = "Test") -> UserScript {
        UserScript(name: name, source: source, urlPattern: "*", topicFilter: "#")
    }

    func testRequestHeadersQueryAndLogs() {
        let script = script("""
        function onRequest(request) {
          request.headers["authorization"] = "Bearer x";
          request.headers.accept = "text/plain";
          console.log(request.host, request.path, request.headers.COOKIE);
          delete request.headers.Cookie;
          request.query.page = 2;
          return request;
        }
        """)
        let result = ScriptRunner.runRequest(request, scripts: [script], engine: JavaScriptEngine(scripts: [script]))
        XCTAssertEqual(result.request.url, "https://api.example.com/v2/devices?room=kitchen&page=2")
        XCTAssertEqual(result.request.headers, [CapturedHeader(name: "Accept", value: "text/plain"),
                                                CapturedHeader(name: "authorization", value: "Bearer x")])
        XCTAssertEqual(result.logs.map(\.message), ["api.example.com /v2/devices [\n  \"a=1\",\n  \"b=2\"\n]"],
                       "repeated headers read as an array; objects are logged as JSON")
        XCTAssertEqual(result.applied, ["Test"])
    }

    func testResponseJSONAndRespond() {
        let edit = script("""
        function onResponse(request, response) {
          response.json.user.plan = "pro";
          response.status = 201;
        }
        """)
        let response = HTTPResponseDraft(statusCode: 200, headers: [CapturedHeader(name: "Content-Type", value: "application/json")],
                                         body: Array(#"{"user":{"plan":"free"}}"#.utf8))
        let edited = ScriptRunner.runResponse(response, request: request, scripts: [edit], engine: JavaScriptEngine(scripts: [edit]))
        XCTAssertEqual(edited.response.statusCode, 201)
        XCTAssertEqual(String(decoding: edited.response.body, as: UTF8.self), #"{"user":{"plan":"pro"}}"#)

        let mock = script(#"function onRequest(r) { if (r.query.room === "kitchen") return respond({ json: { devices: [] } }); }"#)
        let answered = ScriptRunner.runRequest(request, scripts: [mock], engine: JavaScriptEngine(scripts: [mock]))
        XCTAssertEqual(answered.response?.statusCode, 200)
        XCTAssertEqual(answered.response?.headers, [CapturedHeader(name: "Content-Type", value: "application/json")])
        XCTAssertEqual(answered.response.map { String(decoding: $0.body, as: UTF8.self) }, "{\n  \"devices\": []\n}")
        XCTAssertEqual(answered.request, request, "returning only a response leaves the request alone")
    }

    func testPublishAndStateBetweenCalls() {
        let script = script("""
        let seen = 0;
        function onPublish(message) {
          seen += 1;
          message.json.celsius = message.json.celsius * 2;
          message.json.seen = seen;
          message.topic = message.topic.replace("kitchen", "test");
        }
        """)
        let engine = JavaScriptEngine(scripts: [script])
        let publish = MQTTPublish(topic: "home/kitchen/temperature", payload: Array(#"{"celsius":21.5}"#.utf8))
        _ = ScriptRunner.runPublish(publish, resolvedTopic: publish.topic, direction: .brokerToClient, broker: "b", clientID: nil,
                                    scripts: [script], engine: engine)
        let second = ScriptRunner.runPublish(publish, resolvedTopic: publish.topic, direction: .brokerToClient, broker: "b", clientID: nil,
                                             scripts: [script], engine: engine)
        XCTAssertEqual(second.topic, "home/test/temperature")
        XCTAssertEqual(String(decoding: second.publish.payload, as: UTF8.self), #"{"celsius":43,"seen":2}"#)
    }

    func testErrorsCarryLinesAndLoadErrorsAreReportedOnce() {
        let throwing = script("function onRequest(r) {\n  null.x;\n}", name: "Throws")
        let broken = script("function onRequest(r) {\n  return (;\n}", name: "Broken")
        let engine = JavaScriptEngine(scripts: [throwing, broken])
        let first = ScriptRunner.runRequest(request, scripts: [throwing, broken], engine: engine)
        XCTAssertEqual(first.request, request)
        XCTAssertEqual(first.logs.map(\.scriptName), ["Throws", "Broken"])
        XCTAssertTrue(first.logs[0].message.hasPrefix("onRequest: TypeError"), first.logs[0].message)
        XCTAssertEqual(first.logs[0].line, 2)
        XCTAssertTrue(first.logs[1].message.contains("SyntaxError"), first.logs[1].message)
        let second = ScriptRunner.runRequest(request, scripts: [throwing, broken], engine: engine)
        XCTAssertEqual(second.logs.map(\.scriptName), ["Throws"], "a script that doesn't load is reported once")
    }

    func testRunawayScriptsAreStopped() throws {
        try XCTSkipUnless(JavaScriptEngine.canStopRunawayScripts, "JavaScriptCore's watchdog isn't available")
        let loop = script("""
        let calls = 0;
        function onRequest(r) {
          calls += 1;
          if (r.headers["x-loop"]) { while (true) {} }
          r.headers["X-Calls"] = String(calls);
        }
        """)
        let engine = JavaScriptEngine(scripts: [loop], timeLimit: 0.25)
        var looping = request
        looping.headers.append(CapturedHeader(name: "X-Loop", value: "1"))
        let started = Date()
        let stopped = ScriptRunner.runRequest(looping, scripts: [loop], engine: engine)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(stopped.request, looping)
        XCTAssertTrue(stopped.logs.first?.message.contains("stopped") == true, String(describing: stopped.logs))
        let next = ScriptRunner.runRequest(request, scripts: [loop], engine: engine)
        XCTAssertEqual(next.request.headers.last, CapturedHeader(name: "X-Calls", value: "1"), "the script starts over after being stopped")
    }

    func testSyntaxCheck() {
        XCTAssertNil(ScriptSyntax.check("function onRequest(r) { return r; }"))
        let problem = ScriptSyntax.check("function onRequest(r) {\n  return (;\n}")
        XCTAssertNotNil(problem)
        XCTAssertEqual(problem?.line, 2)
        XCTAssertNil(ScriptSyntax.check("while (true) {}"), "checking never runs the code")
    }
}
#endif
