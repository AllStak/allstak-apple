import XCTest
@testable import AllStak

final class AllStakTests: XCTestCase {

    func testBinaryImagesHaveDebugUuids() {
        let images = BinaryImageProvider.current()
        XCTAssertFalse(images.isEmpty, "the running process must expose loaded images")

        let uuidRegex = #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#
        let img = images[0]
        XCTAssertNotNil(img.debugId.range(of: uuidRegex, options: .regularExpression),
                        "debugId should be an uppercase hyphenated UUID, got \(img.debugId)")
        XCTAssertTrue(img.imageAddr.hasPrefix("0x"))
        XCTAssertEqual(img.type, "macho")
        XCTAssertFalse(img.codeFile.isEmpty)
    }

    func testImageForAddressPicksAnImage() {
        let images = BinaryImageProvider.current()
        guard let first = images.first,
              let load = UInt(first.imageAddr.dropFirst(2), radix: 16) else {
            return XCTFail("expected at least one image with a hex load address")
        }
        // An address at/after a known load address resolves to some image.
        XCTAssertNotNil(BinaryImageProvider.image(forAddress: load + 0x10))
    }

    func testBuildEventShapeAndEncoding() throws {
        let client = AllStakClient(apiKey: "astk_test", host: "https://api.example.test",
                                   environment: "test", release: "1.0.0")
        let event = client.buildEvent(
            exceptionClass: "MyError",
            message: "boom",
            level: "error",
            addresses: [0x1000, 0x2000])

        XCTAssertEqual(event.exceptionClass, "MyError")
        XCTAssertEqual(event.message, "boom")
        XCTAssertEqual(event.platform, "cocoa")
        XCTAssertEqual(event.environment, "test")
        XCTAssertEqual(event.release, "1.0.0")
        XCTAssertEqual(event.frames.count, 2)
        XCTAssertEqual(event.frames[0].instructionAddr, "0x1000")
        XCTAssertTrue(event.frames[0].inApp)
        XCTAssertFalse(event.debugMeta.images.isEmpty)
        XCTAssertEqual(event.sdkName, "allstak-apple")

        // Encodes to the camelCase JSON the backend expects (unknown fields ignored).
        let json = String(data: try JSONEncoder().encode(event), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"exceptionClass\""))
        XCTAssertTrue(json.contains("\"debugMeta\""))
        XCTAssertTrue(json.contains("\"instructionAddr\""))
        XCTAssertTrue(json.contains("\"debugId\""))
        XCTAssertTrue(json.contains("\"cocoa\""))
    }
}
