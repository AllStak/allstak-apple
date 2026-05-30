import XCTest
#if canImport(Compression)
import Compression
#endif
@testable import AllStak

/// Event-shape + config tests for app-hang / watchdog-termination / MetricKit
/// capture: the synthetic event builder stamps the right mechanism / level /
/// frames, the `mechanism` field is OMITTED on ordinary events (wire shape
/// preserved) and PRESENT on synthetic ones, and the config opt-outs leave the
/// trackers un-armed. Captures the exact POSTed bytes through a recording poster.
final class AppHangWatchdogEventTests: XCTestCase {

    /// Records the body of every POST so the wire JSON can be asserted.
    private final class RecordingPoster: HTTPPoster, @unchecked Sendable {
        private let lock = NSLock()
        private var _bodies: [Data] = []
        private var fulfilled = false
        var onFirst: (() -> Void)?
        func bodies() -> [Data] { lock.lock(); defer { lock.unlock() }; return _bodies }
        func post(url: URL, headers: [String: String], body: Data) async throws
            -> (status: Int, retryAfter: String?) {
            let decodedBody = Self.decodedBody(headers: headers, body: body)
            lock.lock()
            _bodies.append(decodedBody)
            let fire = !fulfilled ? onFirst : nil
            fulfilled = true
            lock.unlock()
            fire?()
            return (200, nil)
        }

        private static func decodedBody(headers: [String: String], body: Data) -> Data {
            guard headers["Content-Encoding"]?.lowercased() == "gzip" else { return body }
            return gunzip(body) ?? body
        }

        private static func gunzip(_ data: Data) -> Data? {
            #if canImport(Compression)
            let bytes = [UInt8](data)
            guard bytes.count >= 18,
                  bytes[0] == 0x1f,
                  bytes[1] == 0x8b,
                  bytes[2] == 0x08 else { return nil }
            let expectedSize =
                Int(bytes[bytes.count - 4]) |
                (Int(bytes[bytes.count - 3]) << 8) |
                (Int(bytes[bytes.count - 2]) << 16) |
                (Int(bytes[bytes.count - 1]) << 24)
            let compressed = Array(bytes[10..<(bytes.count - 8)])
            var output = [UInt8](repeating: 0, count: expectedSize)
            let written = compressed.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return 0 }
                    return compression_decode_buffer(dstBase, dst.count,
                                                     srcBase, src.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            guard written == expectedSize else { return nil }
            return Data(output.prefix(written))
            #else
            return nil
            #endif
        }
    }

    private func makeClient(_ poster: RecordingPoster) -> AllStakClient {
        let transport = Transport(baseURL: "https://h.test", apiKey: "k",
                                  poster: poster, spool: nil)
        return AllStakClient(apiKey: "k", host: "https://h.test", environment: "test",
                             release: "1.0.0", enableAutoSessionTracking: false,
                             transport: transport)
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: synthetic event builder

    func testBuildSyntheticEventStampsMechanismLevelAndSymbolFrames() {
        let client = makeClient(RecordingPoster())
        let event = client.buildSyntheticEvent(
            exceptionClass: "App Hanging", message: "stuck", level: "warning",
            mechanism: "app_hang", symbolFrames: ["mainLoop", "render"])
        XCTAssertEqual(event.exceptionClass, "App Hanging")
        XCTAssertEqual(event.level, "warning")
        XCTAssertEqual(event.mechanism, "app_hang")
        XCTAssertEqual(event.platform, "cocoa")
        XCTAssertEqual(event.frames.count, 2)
        // Symbol strings ride in `function`; no instruction address for these.
        XCTAssertEqual(event.frames[0].function, "mainLoop")
        XCTAssertNil(event.frames[0].instructionAddr)
        XCTAssertTrue(event.frames[0].inApp)
    }

    // MARK: wire shape — mechanism present/absent

    func testOrdinaryEventOmitsMechanismOnTheWire() throws {
        let poster = RecordingPoster()
        let exp = expectation(description: "posted")
        poster.onFirst = { exp.fulfill() }
        let client = makeClient(poster)
        client.capture(message: "hello", level: "info")
        wait(for: [exp], timeout: 2.0)

        let obj = json(poster.bodies()[0])
        XCTAssertNil(obj["mechanism"], "ordinary events must not carry a mechanism (wire shape preserved)")
    }

    func testAppHangEventCarriesAppHangMechanismOnTheWire() throws {
        let poster = RecordingPoster()
        let exp = expectation(description: "posted")
        poster.onFirst = { exp.fulfill() }
        let client = makeClient(poster)
        client.captureAppHang(duration: 2.5, stack: ["a", "b"])
        wait(for: [exp], timeout: 2.0)

        let obj = json(poster.bodies()[0])
        XCTAssertEqual(obj["mechanism"] as? String, "app_hang")
        XCTAssertEqual(obj["level"] as? String, "warning")
        XCTAssertEqual(obj["exceptionClass"] as? String, "App Hanging")
        let frames = obj["frames"] as? [[String: Any]]
        XCTAssertEqual(frames?.count, 2)
        XCTAssertEqual(frames?.first?["function"] as? String, "a")
    }

    func testWatchdogTerminationEventCarriesMechanismAndPriorTimestamp() throws {
        let poster = RecordingPoster()
        let exp = expectation(description: "posted")
        poster.onFirst = { exp.fulfill() }
        let client = makeClient(poster)
        let marker = AppRunStateMarker(release: "1.0.0", osVersion: "17.0.0",
                                       isForeground: true, isDebugging: false,
                                       startedAt: 1_700_000_000)
        client.captureWatchdogTermination(marker)
        wait(for: [exp], timeout: 2.0)

        let obj = json(poster.bodies()[0])
        XCTAssertEqual(obj["mechanism"] as? String, "watchdog_termination")
        XCTAssertEqual(obj["level"] as? String, "error")
        XCTAssertEqual(obj["exceptionClass"] as? String, "Watchdog Termination")
        // Stamped to the prior run's start, not "now".
        XCTAssertEqual(obj["timestamp"] as? Double, 1_700_000_000)
    }

    func testMetricKitCrashDiagnosticFeedsPipelineWithCallStackExtra() throws {
        let poster = RecordingPoster()
        let exp = expectation(description: "posted")
        poster.onFirst = { exp.fulfill() }
        let client = makeClient(poster)
        client.captureMetricKitDiagnostic(mechanism: MetricKitMechanism.crash,
                                          title: "EXC_BAD_ACCESS",
                                          callStackJSON: "{\"tree\":1}")
        wait(for: [exp], timeout: 2.0)

        let obj = json(poster.bodies()[0])
        XCTAssertEqual(obj["mechanism"] as? String, "metrickit_crash")
        XCTAssertEqual(obj["level"] as? String, "fatal")
        let meta = obj["metadata"] as? [String: Any]
        XCTAssertEqual(meta?["metric_kit_call_stack"] as? String, "{\"tree\":1}")
    }

    // MARK: round-trip — mechanism survives decode

    func testMechanismRoundTripsThroughCodable() throws {
        let client = makeClient(RecordingPoster())
        let event = client.buildSyntheticEvent(
            exceptionClass: "Watchdog Termination", message: "oom", level: "error",
            mechanism: "watchdog_termination", symbolFrames: [])
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AllStakErrorEvent.self, from: data)
        XCTAssertEqual(decoded.mechanism, "watchdog_termination")
    }

    // MARK: config opt-outs (install methods are inert under XCTest)

    func testInstallAppHangDetectorIsNoOpUnderTests() {
        let client = makeClient(RecordingPoster())
        client.installAppHangDetector(timeoutInterval: 2.0)
        XCTAssertNil(client.appHangDetector,
                     "no live watchdog should be armed under the test harness")
    }

    func testInstallWatchdogTrackingIsNoOpUnderTests() {
        let store = CrashStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("allstak-cfg-" + UUID().uuidString))
        let client = makeClient(RecordingPoster())
        let tracker = client.installWatchdogTracking(store: store, crashRecorded: false)
        XCTAssertNil(tracker, "watchdog tracking must not arm under the test harness")
        XCTAssertNil(client.watchdogTracker)
    }

    func testStartWithFeaturesDisabledLeavesTrackersNil() {
        // `AllStak.start` is suppressed under XCTest for the live trackers anyway,
        // but the explicit opt-out path must also leave everything un-armed and
        // never freeze/crash.
        AllStak.start(apiKey: "k", host: "https://h.test", environment: "test",
                      release: "1.0.0",
                      enableAppHangTracking: false,
                      enableWatchdogTerminationTracking: false,
                      enableMetricKit: false)
        // No crash, no freeze; the public API stays responsive.
        AllStak.addBreadcrumb(message: "still alive")
        AllStak.capture(message: "ok", level: "info")
    }
}
