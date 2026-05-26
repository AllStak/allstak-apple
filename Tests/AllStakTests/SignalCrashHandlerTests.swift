import XCTest
import Darwin
@testable import AllStak

/// Tests for the parts of signal crash capture that CAN be exercised in normal
/// context: the async-signal-safe record writer, the next-launch parser, the
/// reader that turns a persisted record into a `CrashReport`, and the ascii
/// formatting helper. The live `sigaction` handler itself cannot be unit-tested
/// (you can't safely raise a real SIGSEGV in-process); it is device-verification
/// only. See the report / README status note.
final class SignalCrashHandlerTests: XCTestCase {

    // MARK: integer -> ascii hex formatting (async-signal-safe helper)

    func testHexFormattingIntoFixedBuffer() {
        func hexString(_ v: UInt64) -> String {
            var buf = [UInt8](repeating: 0, count: 32)
            let n = buf.withUnsafeMutableBufferPointer {
                AsyncSignalSafeFormat.hex(v, into: $0.baseAddress!, capacity: $0.count)
            }
            return String(bytes: buf[0..<n], encoding: .ascii)!
        }
        XCTAssertEqual(hexString(0), "0")
        XCTAssertEqual(hexString(1), "1")
        XCTAssertEqual(hexString(0xF), "f")
        XCTAssertEqual(hexString(0x10), "10")
        XCTAssertEqual(hexString(0xDEADBEEF), "deadbeef")
        XCTAssertEqual(hexString(0x1234_5678_9ABC_DEF0), "123456789abcdef0")
        XCTAssertEqual(hexString(UInt64.max), "ffffffffffffffff")
    }

    func testHexFormattingRejectsUndersizedBuffer() {
        var buf = [UInt8](repeating: 0, count: 2)
        let n = buf.withUnsafeMutableBufferPointer {
            // 0xABCDE needs 5 digits, buffer holds 2 -> refuse, write nothing.
            AsyncSignalSafeFormat.hex(0xABCDE, into: $0.baseAddress!, capacity: $0.count)
        }
        XCTAssertEqual(n, 0)
    }

    // MARK: record encode -> parse round trip (the writer + reader format)

    func testEncodeParseRoundTrip() {
        let frames: [UInt64] = [0xAAAA, 0xBBBB, 0xCCCC, 0xDDDD]
        var buf = [UInt8](repeating: 0xEE, count: SignalCrashRecord.maxRecordSize)

        let total = buf.withUnsafeMutableBufferPointer { dst -> Int in
            frames.withUnsafeBufferPointer { src in
                SignalCrashRecord.encode(
                    into: dst.baseAddress!,
                    capacity: dst.count,
                    signal: SIGSEGV,
                    faultAddress: 0x1234_5678,
                    timestamp: 1_700_000_000,
                    frames: src.baseAddress!,
                    frameCount: src.count)
            }
        }
        XCTAssertEqual(total, SignalCrashRecord.headerSize + frames.count * 8)

        let data = Data(buf[0..<total])
        guard let parsed = SignalCrashRecord.parse(data) else {
            return XCTFail("record should parse")
        }
        XCTAssertEqual(parsed.signal, SIGSEGV)
        XCTAssertEqual(parsed.faultAddress, 0x1234_5678)
        XCTAssertEqual(parsed.timestamp, 1_700_000_000)
        XCTAssertEqual(parsed.frames, frames)
    }

    func testEncodeClampsFrameCountToMax() {
        let over = SignalCrashRecord.maxFrames + 50
        let frames = [UInt64](repeating: 0x42, count: over)
        var buf = [UInt8](repeating: 0, count: SignalCrashRecord.maxRecordSize)

        let total = buf.withUnsafeMutableBufferPointer { dst -> Int in
            frames.withUnsafeBufferPointer { src in
                SignalCrashRecord.encode(
                    into: dst.baseAddress!, capacity: dst.count,
                    signal: SIGABRT, faultAddress: 0, timestamp: 1,
                    frames: src.baseAddress!, frameCount: src.count)
            }
        }
        XCTAssertEqual(total, SignalCrashRecord.maxRecordSize)
        let parsed = SignalCrashRecord.parse(Data(buf[0..<total]))
        XCTAssertEqual(parsed?.frames.count, SignalCrashRecord.maxFrames)
    }

    func testParseRejectsGarbageAndTruncated() {
        XCTAssertNil(SignalCrashRecord.parse(Data()))
        XCTAssertNil(SignalCrashRecord.parse(Data([0x00, 0x01, 0x02])))
        // valid-length but wrong magic
        var bad = [UInt8](repeating: 0, count: SignalCrashRecord.headerSize)
        bad[0] = 0xFF
        XCTAssertNil(SignalCrashRecord.parse(Data(bad)))
    }

    // MARK: write to a real fd, parse back (mirrors the handler's write path)

    func testWriteToFileDescriptorAndReadBack() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("allstak-sigtest-" + UUID().uuidString + ".bin")
        let fd = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o600) }
        XCTAssertGreaterThanOrEqual(fd, 0)

        let frames: [UInt64] = [0x111, 0x222, 0x333]
        var buf = [UInt8](repeating: 0, count: SignalCrashRecord.maxRecordSize)
        let total = buf.withUnsafeMutableBufferPointer { dst -> Int in
            frames.withUnsafeBufferPointer { src in
                SignalCrashRecord.encode(
                    into: dst.baseAddress!, capacity: dst.count,
                    signal: SIGTRAP, faultAddress: 0xCAFE, timestamp: 42,
                    frames: src.baseAddress!, frameCount: src.count)
            }
        }
        // Exactly what the handler does: a single write() of the record bytes.
        buf.withUnsafeBufferPointer { _ = write(fd, $0.baseAddress!, total) }
        close(fd)

        let parsed = SignalCrashRecord.parse(try Data(contentsOf: url))
        XCTAssertEqual(parsed?.signal, SIGTRAP)
        XCTAssertEqual(parsed?.faultAddress, 0xCAFE)
        XCTAssertEqual(parsed?.frames, frames)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: reader -> CrashReport (next-launch conversion)

    func testReaderProducesFatalSignalReport() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("allstak-sigread-" + UUID().uuidString)
        let store = CrashStore(directory: dir)

        // Write a record exactly where the handler would (the store's fixed path).
        let url = store.signalCrashFileURL()
        let fd = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o600) }
        let frames: [UInt64] = [0xABC, 0xDEF]
        var buf = [UInt8](repeating: 0, count: SignalCrashRecord.maxRecordSize)
        let total = buf.withUnsafeMutableBufferPointer { dst -> Int in
            frames.withUnsafeBufferPointer { src in
                SignalCrashRecord.encode(
                    into: dst.baseAddress!, capacity: dst.count,
                    signal: SIGSEGV, faultAddress: 0xBADF00D, timestamp: 1_700_000_001,
                    frames: src.baseAddress!, frameCount: src.count)
            }
        }
        buf.withUnsafeBufferPointer { _ = write(fd, $0.baseAddress!, total) }
        close(fd)

        guard let report = store.pendingSignalReport() else {
            return XCTFail("expected a parsed signal report")
        }
        XCTAssertEqual(report.kind, "signal")
        XCTAssertEqual(report.name, "SIGSEGV")
        XCTAssertTrue(report.message.contains("Segmentation fault"))
        XCTAssertTrue(report.message.contains("badf00d"))
        XCTAssertEqual(report.addresses, [0xABC, 0xDEF])
        XCTAssertEqual(report.timestamp, 1_700_000_001)

        // It's consumed on read: a second read finds nothing.
        XCTAssertNil(store.pendingSignalReport())

        // And it flows through the existing fatal-event builder.
        let client = AllStakClient(apiKey: "k", host: "https://api.example.test",
                                   environment: "prod", release: "3.0.0")
        let event = client.buildCrashEvent(report, images: BinaryImageProvider.current())
        XCTAssertEqual(event.exceptionClass, "SIGSEGV")
        XCTAssertEqual(event.level, "fatal")
        XCTAssertEqual(event.frames.count, 2)

        try? FileManager.default.removeItem(at: dir)
    }

    func testSignalNamesAndMessages() {
        XCTAssertEqual(SignalCrashHandler.signalName(SIGABRT), "SIGABRT")
        XCTAssertEqual(SignalCrashHandler.signalName(SIGBUS), "SIGBUS")
        XCTAssertEqual(SignalCrashHandler.signalName(SIGILL), "SIGILL")
        XCTAssertEqual(SignalCrashHandler.signalName(SIGFPE), "SIGFPE")
        XCTAssertEqual(SignalCrashHandler.signalName(SIGTRAP), "SIGTRAP")
        // No fault address -> message has no address suffix.
        let msg = SignalCrashHandler.signalMessage(SIGABRT, faultAddress: 0)
        XCTAssertFalse(msg.contains("0x"))
    }
}
