import Foundation

/// One persisted, ALREADY-SCRUBBED transport envelope: the exact bytes that would
/// have been POSTed, plus the ingest path and the time it was written. Mirrors the
/// AllStak JS SDK's `PersistedEvent`. The payload is stored as opaque bytes (the
/// scrubbed JSON body) so the spool never re-encodes or sees model objects.
struct SpooledEnvelope: Codable, Sendable, Equatable {
    /// Stable id used for the on-disk filename + removal after a 2xx/permanent.
    let id: String
    /// Ingest path, e.g. `/ingest/v1/errors`. Session paths are never spooled.
    let path: String
    /// The PII-scrubbed JSON body, base64 in the envelope file so the wrapper is
    /// itself plain JSON regardless of the payload's bytes.
    let payloadBase64: String
    /// Epoch seconds the entry was written (for max-age eviction).
    let ts: Double

    init(id: String = UUID().uuidString, path: String, payload: Data, ts: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.path = path
        self.payloadBase64 = payload.base64EncodedString()
        self.ts = ts
    }

    /// The raw scrubbed body to re-POST. Nil only on a corrupt entry.
    var payload: Data? { Data(base64Encoded: payloadBase64) }
}

/// Ingest paths that must NOT be persisted. Session lifecycle is best-effort
/// live-only — a replayed stale `/sessions/start` or `/end` would skew durations.
/// Mirrors the JS `isPersistablePath`.
func isPersistablePath(_ path: String) -> Bool {
    !path.hasPrefix("/ingest/v1/sessions/")
}

/// Bounds for the persistent spool. Drop-oldest enforcement on count, total
/// bytes, and max age. Conservative mobile-friendly defaults.
struct SpoolBounds: Sendable {
    var maxEntries: Int = 200
    var maxBytes: Int = 2_000_000      // ~2 MB
    var maxAgeSeconds: Double = 48 * 60 * 60   // 48h

    static let `default` = SpoolBounds()
}

/// Persistent on-disk spool of failed/queued telemetry envelopes, one JSON file
/// per envelope under a cache subdirectory (mirroring `CrashStore`'s approach:
/// `<caches>/com.allstak/spool`). One-file-per-envelope keeps writes atomic-ish
/// and removal O(1) without rewriting a log.
///
/// Invariants (enforced here, documented for the reader):
///   * Bytes handed to `enqueue` are ALREADY PII-scrubbed (the transport scrubs
///     before persisting — we store the exact bytes that would be POSTed).
///   * Session lifecycle paths are never persisted (`isPersistablePath`).
///   * Bounded by count + total bytes + max age; when full the OLDEST entry is
///     dropped. The spool can never grow unbounded.
///   * Fully fail-open: an unwritable/unavailable directory degrades to a no-op;
///     no method ever throws.
final class EnvelopeSpool: @unchecked Sendable {

    private let directory: URL
    private let bounds: SpoolBounds
    private let fileManager = FileManager.default
    private let lock = NSLock()

    init(directory: URL, bounds: SpoolBounds = .default) {
        self.directory = directory
        self.bounds = bounds
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Default location: `<caches>/com.allstak/spool` (sibling of the crash store).
    static func defaultSpool(bounds: SpoolBounds = .default) -> EnvelopeSpool {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return EnvelopeSpool(directory: base.appendingPathComponent("com.allstak/spool"),
                             bounds: bounds)
    }

    private func fileURL(for id: String) -> URL {
        // ids are UUIDs, but guard against traversal regardless.
        let safe = id.unicodeScalars.map { c -> Character in
            (c.properties.isAlphabetic || ("0"..."9").contains(Character(c)) || c == "-" || c == "_")
                ? Character(c) : "_"
        }
        return directory.appendingPathComponent("env-" + String(safe) + ".json")
    }

    /// Persist one already-scrubbed envelope. Session paths are refused (returns
    /// without writing). Best-effort; never throws. Enforces bounds after writing.
    @discardableResult
    func enqueue(path: String, payload: Data, id: String = UUID().uuidString,
                 ts: Double = Date().timeIntervalSince1970) -> Bool {
        guard isPersistablePath(path) else { return false }
        let envelope = SpooledEnvelope(id: id, path: path, payload: payload, ts: ts)
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        lock.lock(); defer { lock.unlock() }
        do {
            try data.write(to: fileURL(for: id), options: .atomic)
        } catch {
            return false
        }
        enforceBoundsLocked()
        return true
    }

    /// Re-persist an envelope under its existing id (used when a replayed item
    /// fails again — it must replace, not duplicate, its stored copy).
    @discardableResult
    func enqueue(_ envelope: SpooledEnvelope) -> Bool {
        guard isPersistablePath(envelope.path) else { return false }
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        lock.lock(); defer { lock.unlock() }
        do {
            try data.write(to: fileURL(for: envelope.id), options: .atomic)
        } catch {
            return false
        }
        enforceBoundsLocked()
        return true
    }

    /// Load everything currently persisted, OLDEST FIRST, after evicting entries
    /// that fell outside the bounds (age/count/bytes). Corrupt entries are
    /// dropped. Never throws.
    func load() -> [SpooledEnvelope] {
        lock.lock(); defer { lock.unlock() }
        let (kept, evicted) = boundedSnapshotLocked()
        for e in evicted { try? fileManager.removeItem(at: fileURL(for: e.id)) }
        return kept
    }

    /// Remove a persisted entry by id (after a 2xx accept or a permanent drop).
    func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: fileURL(for: id))
    }

    /// Drop everything (tests + opt-out reset).
    func clear() {
        lock.lock(); defer { lock.unlock() }
        for url in onDiskURLsLocked() { try? fileManager.removeItem(at: url) }
    }

    /// Current entry count (after bounds), for tests/metrics.
    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return boundedSnapshotLocked().kept.count
    }

    // MARK: - Internals (caller holds `lock`)

    private func onDiskURLsLocked() -> [URL] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.lastPathComponent.hasPrefix("env-") && $0.pathExtension == "json" }
    }

    /// Read + decode all entries (corrupt ones unlinked), sort oldest-first, and
    /// split into the bounded `kept` set plus the `evicted` set. Pure read except
    /// for unlinking corrupt files.
    private func boundedSnapshotLocked() -> (kept: [SpooledEnvelope], evicted: [SpooledEnvelope]) {
        var entries: [SpooledEnvelope] = []
        for url in onDiskURLsLocked() {
            guard let data = try? Data(contentsOf: url),
                  let env = try? JSONDecoder().decode(SpooledEnvelope.self, from: data) else {
                try? fileManager.removeItem(at: url) // corrupt → drop
                continue
            }
            entries.append(env)
        }
        // Oldest first; id as a stable tiebreaker.
        entries.sort { $0.ts != $1.ts ? $0.ts < $1.ts : $0.id < $1.id }
        return applyBounds(entries)
    }

    /// Enforce bounds and unlink anything that fell out (used after each write).
    private func enforceBoundsLocked() {
        let (_, evicted) = boundedSnapshotLocked()
        for e in evicted { try? fileManager.removeItem(at: fileURL(for: e.id)) }
    }

    /// Apply age → count → byte caps, dropping OLDEST first. Returns kept +
    /// evicted, both derived from an oldest-first input.
    private func applyBounds(_ list: [SpooledEnvelope]) -> (kept: [SpooledEnvelope], evicted: [SpooledEnvelope]) {
        let now = Date().timeIntervalSince1970
        var evicted: [SpooledEnvelope] = []
        var kept: [SpooledEnvelope] = []

        // 1. Age out stale entries.
        for e in list {
            if now - e.ts > bounds.maxAgeSeconds { evicted.append(e) } else { kept.append(e) }
        }
        // 2. Count cap — drop oldest (front).
        while kept.count > bounds.maxEntries {
            evicted.append(kept.removeFirst())
        }
        // 3. Byte cap — drop oldest until under budget.
        func bytes(_ e: SpooledEnvelope) -> Int { e.payloadBase64.utf8.count + e.path.utf8.count + e.id.utf8.count }
        var total = kept.reduce(0) { $0 + bytes($1) }
        while !kept.isEmpty && total > bounds.maxBytes {
            let removed = kept.removeFirst()
            total -= bytes(removed)
            evicted.append(removed)
        }
        return (kept, evicted)
    }
}
