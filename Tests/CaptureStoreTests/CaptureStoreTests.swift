@testable import CaptureStore
import Foundation
import MQTTCore
@testable import ProxyCore
import XCTest

private func exchange(
    _ method: String = "GET",
    _ url: String,
    status: Int? = 200,
    requestBody: String = "",
    responseBody: [UInt8] = [],
    responseHeaders: [CapturedHeader] = [CapturedHeader(name: "Content-Type", value: "application/json")]
) -> CaptureEvent {
    .httpExchange(HTTPExchange(
        id: UUID(),
        startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        duration: 0.125,
        method: method,
        url: url,
        requestHeaders: [CapturedHeader(name: "Accept", value: "*/*")],
        requestBody: Array(requestBody.utf8),
        statusCode: status,
        responseHeaders: responseHeaders,
        responseBody: responseBody,
        error: nil
    ))
}

/// Decodes a v5 PUBLISH through a real session so the stored event matches what the proxy records.
private func mqttPublish(topic: String, payload: String, alias: UInt16? = nil) throws -> [CaptureEvent] {
    var session = MQTTSession()
    let connect: [UInt8] = [0x10, 0x0F, 0x00, 0x04] + Array("MQTT".utf8) + [0x05, 0x02, 0x00, 0x3C, 0x00, 0x00, 0x02] + Array("id".utf8)
    var events = try session.receive(connect, from: .clientToBroker)
    var properties: [UInt8] = []
    if let alias { properties = [0x23, UInt8(alias >> 8), UInt8(alias & 0xFF)] }
    let topicBytes = Array(topic.utf8)
    let body: [UInt8] = [UInt8(topicBytes.count >> 8), UInt8(topicBytes.count & 0xFF)] + topicBytes
        + [UInt8(properties.count)] + properties + Array(payload.utf8)
    events += try session.receive([0x30, UInt8(body.count)] + body, from: .clientToBroker)
    return events.map { .mqtt(MQTTCaptureEvent(connectionID: UUID(), timestamp: Date(), broker: "broker.test:1883", event: $0)) }
}

final class CaptureStoreTests: XCTestCase {
    func testRoundTripsEveryEventKind() throws {
        let store = try CaptureStore(path: ":memory:")
        let events: [CaptureEvent] = [
            exchange("POST", "https://api.test/items?page=2", status: 201, requestBody: "{\"a\":1}", responseBody: Array("{\"ok\":true}".utf8)),
            .tunnelOpened(TunnelInfo(id: UUID(), openedAt: Date(timeIntervalSince1970: 5), host: "pinned.test", port: 443)),
            .tunnelClosed(id: UUID(), bytesFromClient: 10, bytesFromServer: 20),
            .mqttDecodingFailed(connectionID: UUID(), reason: "bad"),
            .tlsInterceptionFailed(host: "bank.test", port: 443, reason: "handshake"),
            .webSocketMessage(WebSocketMessage(connectionID: UUID(), timestamp: Date(timeIntervalSince1970: 6), url: "wss://ws.test/feed",
                                               direction: .serverToClient, opcode: .text, payload: Array("tick".utf8))),
            .webSocketDecodingFailed(connectionID: UUID(), reason: "rsv"),
        ] + (try mqttPublish(topic: "home/kitchen/temp", payload: "21.5"))

        events.forEach(store.record)
        XCTAssertNil(store.lastError)

        let loaded = try store.events(in: store.currentSession)
        XCTAssertEqual(loaded.map(\.event), events)
        XCTAssertEqual(loaded.map(\.kind), ["http", "tunnel", "tunnel", "mqtt", "tls", "websocket", "websocket", "mqtt", "mqtt"])
        XCTAssertEqual(loaded[0].host, "api.test")
        XCTAssertEqual(loaded[0].summary, "POST https://api.test/items?page=2 201")
        XCTAssertEqual(loaded[8].summary, "PUBLISH broker.test:1883 home/kitchen/temp")
    }

    func testFiltersByKindAndPages() throws {
        let store = try CaptureStore(path: ":memory:")
        for index in 0..<5 { store.record(exchange("GET", "http://a.test/\(index)")) }
        try mqttPublish(topic: "t", payload: "p").forEach(store.record)

        XCTAssertEqual(try store.events(in: store.currentSession, kinds: ["mqtt"]).count, 2)
        let page = try store.events(in: store.currentSession, limit: 2, offset: 1)
        XCTAssertEqual(page.map(\.summary), ["GET http://a.test/1 200", "GET http://a.test/2 200"])
    }

    func testSearchAcrossHTTPAndMQTT() throws {
        let store = try CaptureStore(path: ":memory:")
        store.record(exchange("GET", "https://api.test/users", responseBody: Array("{\"name\":\"Ryan\"}".utf8)))
        store.record(exchange("GET", "https://cdn.test/logo.png", responseBody: [0xFF, 0xD8, 0xFF]))
        try mqttPublish(topic: "sensors/garage/humidity", payload: "{\"rh\": 61}").forEach(store.record)

        XCTAssertEqual(try store.search("ryan").map(\.host), ["api.test"], "response body text is indexed")
        XCTAssertEqual(try store.search("humid").map(\.kind), ["mqtt"], "topic prefix match")
        XCTAssertEqual(try store.search("garage rh").count, 1, "all words must match")
        XCTAssertEqual(try store.search("application/json").count, 2, "headers are indexed and punctuation is literal")
        XCTAssertTrue(try store.search("nothing-like-this").isEmpty)
        XCTAssertTrue(try store.search("   ").isEmpty)
        XCTAssertTrue(try store.search("\"quoted").isEmpty, "quotes cannot break the query")
    }

    func testSessionsAreIsolatedAndDeletable() throws {
        let store = try CaptureStore(path: ":memory:", sessionName: "First")
        let first = store.currentSession
        store.record(exchange("GET", "http://one.test/"))
        let second = try store.startSession(named: "Second")
        store.record(exchange("GET", "http://two.test/"))
        store.record(exchange("GET", "http://two.test/again"))

        let sessions = try store.sessions()
        XCTAssertEqual(sessions.map(\.name), ["Second", "First"])
        XCTAssertEqual(sessions.map(\.eventCount), [2, 1])
        XCTAssertEqual(try store.search("two").count, 2)
        XCTAssertEqual(try store.search("two", in: first).count, 0)

        try store.renameSession(first, to: "Login flow")
        XCTAssertThrowsError(try store.deleteSession(second))
        try store.deleteSession(first)
        XCTAssertEqual(try store.sessions().map(\.name), ["Second"])
        XCTAssertTrue(try store.search("one").isEmpty, "search index rows are removed with the session")
    }

    func testPersistsAcrossReopen() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tw-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session: UUID
        do {
            let store = try CaptureStore(path: path)
            session = store.currentSession
            store.record(exchange("GET", "http://keep.test/"))
        }
        let reopened = try CaptureStore(path: path)
        XCTAssertEqual(try reopened.events(in: session).count, 1)
        XCTAssertEqual(try reopened.sessions().count, 2)
    }

    func testConcurrentRecording() throws {
        let store = try CaptureStore(path: ":memory:")
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            store.record(exchange("GET", "http://load.test/\(index)"))
        }
        XCTAssertNil(store.lastError)
        XCTAssertEqual(try store.events(in: store.currentSession, limit: 1000).count, 200)
    }
}

final class ExportTests: XCTestCase {
    func testHARExport() throws {
        let store = try CaptureStore(path: ":memory:")
        store.record(exchange("POST", "https://api.test/items?page=2&q=a%20b", status: 201, requestBody: "hello",
                              responseBody: Array("{\"ok\":true}".utf8)))
        store.record(exchange("GET", "https://cdn.test/img", responseBody: [0xFF, 0x00],
                              responseHeaders: [CapturedHeader(name: "Content-Type", value: "image/png")]))
        try mqttPublish(topic: "x", payload: "y").forEach(store.record)

        let data = try store.exportHAR(session: store.currentSession)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let log = try XCTUnwrap(json["log"] as? [String: Any])
        XCTAssertEqual(log["version"] as? String, "1.2")
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2, "only HTTP exchanges are exported")

        let first = entries[0]
        XCTAssertEqual(first["time"] as? Double, 125)
        XCTAssertEqual(first["startedDateTime"] as? String, "2027-01-15T08:00:00.000Z")
        let request = try XCTUnwrap(first["request"] as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "POST")
        XCTAssertEqual((request["postData"] as? [String: Any])?["text"] as? String, "hello")
        let query = try XCTUnwrap(request["queryString"] as? [[String: String]])
        XCTAssertEqual(query, [["name": "page", "value": "2"], ["name": "q", "value": "a b"]])
        let response = try XCTUnwrap(first["response"] as? [String: Any])
        XCTAssertEqual(response["status"] as? Int, 201)
        XCTAssertEqual((response["content"] as? [String: Any])?["text"] as? String, "{\"ok\":true}")

        let binary = try XCTUnwrap((entries[1]["response"] as? [String: Any])?["content"] as? [String: Any])
        XCTAssertEqual(binary["encoding"] as? String, "base64")
        XCTAssertEqual(binary["text"] as? String, "/wA=")
        XCTAssertEqual(binary["mimeType"] as? String, "image/png")
    }

    func testMQTTJSONLinesExport() throws {
        let store = try CaptureStore(path: ":memory:")
        store.record(exchange("GET", "http://ignored.test/"))
        try mqttPublish(topic: "home/door", payload: "open").forEach(store.record)

        let text = String(decoding: try store.exportMQTTJSONLines(session: store.currentSession), as: UTF8.self)
        let lines = text.split(separator: "\n").map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0]["type"] as? String, "CONNECT")
        XCTAssertEqual(lines[0]["clientIdentifier"] as? String, "id")
        XCTAssertEqual(lines[1]["type"] as? String, "PUBLISH")
        XCTAssertEqual(lines[1]["topic"] as? String, "home/door")
        XCTAssertEqual(lines[1]["payload"] as? String, "open")
        XCTAssertEqual(lines[1]["payloadHex"] as? String, "6f70656e")
        XCTAssertEqual(lines[1]["version"] as? String, "5.0")
        XCTAssertEqual(lines[1]["direction"] as? String, "clientToBroker")
        XCTAssertTrue((lines[1]["raw"] as? String)?.hasPrefix("30") ?? false)
    }
}
