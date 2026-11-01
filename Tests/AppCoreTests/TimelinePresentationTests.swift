@testable import AppCore
import CaptureStore
import Foundation
import XCTest

final class TimelinePresentationTests: XCTestCase {
    var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TimelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func makeSampleModel() throws -> CaptureViewModel {
        let store = try CaptureStore(path: directory.appendingPathComponent("db.sqlite").path)
        let model = CaptureViewModel(store: store, engine: nil)
        for event in SampleTraffic.events() { model.ingest(event) }
        return model
    }

    @MainActor
    func testRowPillDetailToneAndTiming() async throws {
        let model = try makeSampleModel()
        let devices = try XCTUnwrap(model.rows.first { $0.summary.hasPrefix("GET https://api.example.com/v2/devices") })
        XCTAssertEqual(devices.pill, "GET")
        XCTAssertEqual(devices.detail, "/v2/devices?limit=20")
        XCTAssertEqual(devices.statusCode, 200)
        XCTAssertEqual(devices.tone, .success)
        XCTAssertEqual(try XCTUnwrap(devices.duration), 0.084, accuracy: 0.0001)

        let failed = try XCTUnwrap(model.rows.first { $0.badge == "503" })
        XCTAssertEqual(failed.pill, "PUT")
        XCTAssertEqual(failed.tone, .failure)

        let notModified = try XCTUnwrap(model.rows.first { $0.badge == "304" })
        XCTAssertEqual(notModified.tone, .redirect)
        XCTAssertEqual(notModified.detail, "/flags.json")

        let connack = try XCTUnwrap(model.rows.first { $0.badge == "CONNACK" })
        XCTAssertEqual(connack.pill, "CONNACK")
        XCTAssertEqual(connack.detail, "← Accepted")
        XCTAssertEqual(connack.tone, .mqtt)
        XCTAssertNil(connack.duration)

        let pinned = try XCTUnwrap(model.rows.first { $0.kind == .tls })
        XCTAssertEqual(pinned.pill, "TLS")
        XCTAssertEqual(pinned.tone, .failure)

        let socket = try XCTUnwrap(model.rows.first { $0.kind == .webSocket })
        XCTAssertTrue(socket.detail.hasPrefix("/feed  → {"), socket.detail)
    }

    @MainActor
    func testQuickFiltersAndHostFilterNarrowVisibleRows() async throws {
        let model = try makeSampleModel()

        model.quickFilter = .media
        XCTAssertEqual(model.visibleRows.map(\.host), ["cdn.example.com"])

        model.quickFilter = .errors
        XCTAssertEqual(Set(model.visibleRows.map(\.pill)), ["PUT", "TLS"])

        model.quickFilter = .publish
        XCTAssertEqual(model.visibleRows.count, model.rows.filter { $0.badge == "PUBLISH" }.count)
        XCTAssertFalse(model.visibleRows.isEmpty)

        model.quickFilter = .json
        XCTAssertTrue(model.visibleRows.contains { $0.summary.hasPrefix("GET https://api.example.com/v2/devices") })
        XCTAssertFalse(model.visibleRows.contains { $0.host == "cdn.example.com" })
        XCTAssertTrue(model.visibleRows.contains { $0.summary.contains("home/kitchen/temperature") })
        XCTAssertFalse(model.visibleRows.contains { $0.summary.contains("home/garage/status") })

        model.quickFilter = .all
        model.hostFilter = "api.example.com"
        XCTAssertTrue(model.visibleRows.allSatisfy { $0.host == "api.example.com" })
        model.section = .http
        XCTAssertTrue(model.visibleRows.allSatisfy { $0.kind == .http && $0.host == "api.example.com" })

        model.newSession()
        XCTAssertNil(model.hostFilter)
    }

    @MainActor
    func testTopHostsAreOrderedByCount() async throws {
        let model = try makeSampleModel()
        let hosts = model.topHosts(limit: 3)
        XCTAssertEqual(hosts.count, 3)
        XCTAssertEqual(hosts, hosts.sorted { $0.count >= $1.count })
        XCTAssertEqual(hosts.first?.count, model.rows.filter { $0.host == hosts.first?.host }.count)
    }

    func testActivityHistogramBucketsRecentEvents() {
        let end = Date(timeIntervalSince1970: 1_000)
        let times = [end.addingTimeInterval(-100), end.addingTimeInterval(-9), end.addingTimeInterval(-6),
                     end.addingTimeInterval(-0.5), end]
        XCTAssertEqual(ActivityHistogram.counts(of: times, buckets: 3, bucketLength: 5, endingAt: end), [0, 2, 2])
        XCTAssertEqual(ActivityHistogram.counts(of: [], buckets: 2, bucketLength: 1, endingAt: end), [0, 0])
        XCTAssertEqual(ActivityHistogram.counts(of: times, buckets: 0, bucketLength: 1, endingAt: end), [])
    }
}
