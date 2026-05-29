import XCTest
@testable import AllStak

/// On-disk envelope spool: round-trip persist/load/remove, session paths refused,
/// bounded eviction (count / bytes / age, drop-oldest), corrupt-entry tolerance,
/// and fail-open behavior on an unwritable directory.
final class EnvelopeSpoolTests: XCTestCase {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("allstak-spool-test-" + UUID().uuidString)
    }

    private func body(_ s: String) -> Data { Data(s.utf8) }

    func testEnqueueLoadRemoveRoundTrip() {
        let spool = EnvelopeSpool(directory: tempDir())
        XCTAssertTrue(spool.load().isEmpty)

        XCTAssertTrue(spool.enqueue(path: "/ingest/v1/errors", payload: body("{\"a\":1}"), id: "e1"))
        let loaded = spool.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "e1")
        XCTAssertEqual(loaded[0].path, "/ingest/v1/errors")
        XCTAssertEqual(loaded[0].payload, body("{\"a\":1}"), "scrubbed bytes round-trip exactly")

        spool.remove(id: "e1")
        XCTAssertTrue(spool.load().isEmpty, "removed entry is gone")
    }

    func testSessionPathsAreNeverSpooled() {
        let spool = EnvelopeSpool(directory: tempDir())
        XCTAssertFalse(spool.enqueue(path: "/ingest/v1/sessions/start", payload: body("{}")),
                       "session start must be refused")
        XCTAssertFalse(spool.enqueue(path: "/ingest/v1/sessions/end", payload: body("{}")),
                       "session end must be refused")
        XCTAssertTrue(spool.load().isEmpty, "no session envelopes are ever persisted")

        // The path predicate itself.
        XCTAssertFalse(isPersistablePath("/ingest/v1/sessions/start"))
        XCTAssertFalse(isPersistablePath("/ingest/v1/sessions/end"))
        XCTAssertTrue(isPersistablePath("/ingest/v1/errors"))
        XCTAssertTrue(isPersistablePath("/ingest/v1/releases"))
    }

    /// Recent epoch baseline so test timestamps don't trip the max-age eviction.
    private var nowTs: Double { Date().timeIntervalSince1970 }

    func testLoadIsOldestFirst() {
        let now = nowTs
        let spool = EnvelopeSpool(directory: tempDir())
        spool.enqueue(path: "/ingest/v1/errors", payload: body("1"), id: "c", ts: now + 30)
        spool.enqueue(path: "/ingest/v1/errors", payload: body("2"), id: "a", ts: now + 10)
        spool.enqueue(path: "/ingest/v1/errors", payload: body("3"), id: "b", ts: now + 20)
        XCTAssertEqual(spool.load().map { $0.id }, ["a", "b", "c"])
    }

    func testCountCapDropsOldest() {
        let now = nowTs
        let bounds = SpoolBounds(maxEntries: 3, maxBytes: 10_000_000, maxAgeSeconds: 10_000)
        let spool = EnvelopeSpool(directory: tempDir(), bounds: bounds)
        for i in 0..<5 {
            spool.enqueue(path: "/ingest/v1/errors", payload: body("p\(i)"),
                          id: "id\(i)", ts: now + Double(i))
        }
        let kept = spool.load()
        XCTAssertEqual(kept.count, 3, "bounded to maxEntries")
        XCTAssertEqual(kept.map { $0.id }, ["id2", "id3", "id4"],
                       "the two OLDEST entries were evicted")
    }

    func testByteCapDropsOldest() {
        // Each payload ~100 bytes; cap at ~250 bytes of payload → keep ~2 newest.
        let now = nowTs
        let big = String(repeating: "x", count: 100)
        let bounds = SpoolBounds(maxEntries: 1000, maxBytes: 250, maxAgeSeconds: 10_000)
        let spool = EnvelopeSpool(directory: tempDir(), bounds: bounds)
        for i in 0..<5 {
            spool.enqueue(path: "/ingest/v1/errors", payload: body(big),
                          id: "id\(i)", ts: now + Double(i))
        }
        let kept = spool.load()
        XCTAssertLessThanOrEqual(kept.count, 3, "byte cap evicts oldest")
        XCTAssertGreaterThanOrEqual(kept.count, 1)
        // Whatever survives must be the NEWEST entries (contiguous suffix).
        XCTAssertEqual(kept.last?.id, "id4", "the newest entry always survives")
    }

    func testMaxAgeEvictsStaleEntries() {
        let now = Date().timeIntervalSince1970
        let bounds = SpoolBounds(maxEntries: 1000, maxBytes: 10_000_000, maxAgeSeconds: 3600)
        let spool = EnvelopeSpool(directory: tempDir(), bounds: bounds)
        // One fresh, one 2h-old (stale).
        spool.enqueue(path: "/ingest/v1/errors", payload: body("fresh"), id: "fresh", ts: now)
        spool.enqueue(path: "/ingest/v1/errors", payload: body("stale"), id: "stale",
                      ts: now - 7200)
        let kept = spool.load()
        XCTAssertEqual(kept.map { $0.id }, ["fresh"], "the 2h-old entry aged out")
    }

    func testCorruptEntryIsDroppedOnLoad() {
        let dir = tempDir()
        let spool = EnvelopeSpool(directory: dir)
        spool.enqueue(path: "/ingest/v1/errors", payload: body("ok"), id: "good")
        // Drop a garbage file matching the spool's naming convention.
        try? Data("not json".utf8).write(to: dir.appendingPathComponent("env-garbage.json"))
        let kept = spool.load()
        XCTAssertEqual(kept.map { $0.id }, ["good"], "the corrupt file is dropped, the good one kept")
    }

    func testReEnqueueUnderSameIdReplacesNotDuplicates() {
        let now = nowTs
        let spool = EnvelopeSpool(directory: tempDir())
        spool.enqueue(path: "/ingest/v1/errors", payload: body("v1"), id: "same", ts: now + 1)
        spool.enqueue(SpooledEnvelope(id: "same", path: "/ingest/v1/errors",
                                      payload: body("v2"), ts: now + 2))
        let kept = spool.load()
        XCTAssertEqual(kept.count, 1, "same id must not duplicate")
        XCTAssertEqual(kept[0].payload, body("v2"), "the re-enqueue replaced the payload")
    }

    func testFailOpenOnUnwritableDirectory() {
        // Point the spool at a path under a regular FILE (so mkdir + write fail).
        let file = tempDir()
        try? Data("x".utf8).write(to: file)
        let spool = EnvelopeSpool(directory: file.appendingPathComponent("cannot/exist"))
        // No throw; enqueue just fails closed and load is empty.
        XCTAssertFalse(spool.enqueue(path: "/ingest/v1/errors", payload: body("x")))
        XCTAssertTrue(spool.load().isEmpty)
    }

    func testClearRemovesEverything() {
        let spool = EnvelopeSpool(directory: tempDir())
        spool.enqueue(path: "/ingest/v1/errors", payload: body("a"), id: "a")
        spool.enqueue(path: "/ingest/v1/errors", payload: body("b"), id: "b")
        XCTAssertEqual(spool.count(), 2)
        spool.clear()
        XCTAssertEqual(spool.count(), 0)
        XCTAssertTrue(spool.load().isEmpty)
    }
}
