import XCTest
@testable import AllStak

final class CrashReporterTests: XCTestCase {

    private func tempStore() -> CrashStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("allstak-test-" + UUID().uuidString)
        return CrashStore(directory: dir)
    }

    func testCrashStoreRoundTrip() throws {
        let store = tempStore()
        XCTAssertTrue(store.pendingReports().isEmpty)

        let report = CrashReport(kind: "nsexception", name: "NSRangeException",
                                 message: "index out of bounds", addresses: [0x1000, 0x2000],
                                 timestamp: 1_700_000_000)
        try store.write(report)

        let pending = store.pendingReports()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].name, "NSRangeException")
        XCTAssertEqual(pending[0].addresses, [0x1000, 0x2000])

        store.clearReports()
        XCTAssertTrue(store.pendingReports().isEmpty)
    }

    func testSessionImagesRoundTrip() {
        let store = tempStore()
        XCTAssertTrue(store.sessionImages().isEmpty)
        let images = BinaryImageProvider.current()
        store.saveSessionImages(images)
        XCTAssertEqual(store.sessionImages().count, images.count)
        XCTAssertEqual(store.sessionImages().first?.debugId, images.first?.debugId)
    }

    func testBuildsFatalEventFromCrashReport() {
        let client = AllStakClient(apiKey: "k", host: "https://api.example.test",
                                   environment: "prod", release: "2.0.0")
        let images = BinaryImageProvider.current()
        let report = CrashReport(kind: "signal", name: "SIGSEGV", message: "segmentation fault",
                                 addresses: [0xabc, 0xdef], timestamp: 1_700_000_000)

        let event = client.buildCrashEvent(report, images: images)

        XCTAssertEqual(event.exceptionClass, "SIGSEGV")
        XCTAssertEqual(event.level, "fatal")
        XCTAssertEqual(event.platform, "cocoa")
        XCTAssertEqual(event.release, "2.0.0")
        XCTAssertEqual(event.frames.count, 2)
        XCTAssertEqual(event.frames[0].instructionAddr, "0xabc")
        XCTAssertEqual(event.debugMeta.images.count, images.count)
    }
}
