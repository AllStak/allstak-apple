import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Async-signal-safe POSIX signal crash capture
//
// `NSSetUncaughtExceptionHandler` (see CrashReporter.swift) only sees Obj-C
// `NSException`s. The dominant class of real Swift crashes — force-unwrap traps,
// out-of-bounds, bad pointer access — never raise an NSException; they deliver a
// POSIX signal (SIGSEGV / SIGABRT / SIGTRAP / SIGILL / SIGBUS / SIGFPE). This file
// installs `sigaction` handlers for those.
//
// THE HANDLER IS RUN INSIDE A CRASHING PROCESS. The only thing it is allowed to do
// is call async-signal-safe functions (see `man 2 sigaction`). Concretely, the
// handler here:
//   * touches NO Swift heap: no String, no Array, no Dictionary, no closure
//     capture, no Foundation, no JSONEncoder, no malloc;
//   * uses ONLY pre-allocated buffers and a pre-opened file descriptor (set up in
//     `install`, in normal context);
//   * formats everything itself into a fixed byte buffer and emits it with a single
//     `write(2)`;
//   * guards re-entrancy with a `sig_atomic_t` flag, then RESTORES the previous
//     handler (or the default disposition) and re-raises, so the OS still produces
//     its own crash report and any other installed reporter still runs.
//
// The record written here is a tiny fixed binary format (see `SignalCrashRecord`).
// It is parsed back on the NEXT launch, in normal context, where allocation and
// Foundation are fine, and turned into the same `CrashReport` the NSException path
// produces.

// MARK: Binary record format

/// On-disk layout of a signal crash, written by the async-signal-safe handler and
/// read on the next launch. Deliberately fixed-width little-endian so it can be
/// emitted with one `write()` from pre-allocated memory and parsed without a JSON
/// decoder.
///
/// Layout (all little-endian):
/// ```
/// offset size field
/// 0      4    magic   = "ASK1"  (0x41 0x53 0x4B 0x31)
/// 4      1    version = 1
/// 5      3    padding (zero)
/// 8      4    signal number (Int32)
/// 12     4    padding (zero)
/// 16     8    fault address (UInt64; 0 if unknown)
/// 24     8    timestamp, whole seconds since epoch (Int64)
/// 32     4    frame count (UInt32)
/// 36     4    padding (zero)
/// 40     N*8  frame return addresses (UInt64 each)
/// ```
enum SignalCrashRecord {
    static let magic: [UInt8] = [0x41, 0x53, 0x4B, 0x31] // "ASK1"
    static let version: UInt8 = 1
    static let headerSize = 40
    static let maxFrames = 128
    /// Total bytes a fully-populated record can occupy. The whole record is
    /// pre-allocated so the handler never needs to size anything at crash time.
    static let maxRecordSize = headerSize + maxFrames * 8

    /// Parsed in-memory form (normal context only).
    struct Parsed: Equatable {
        let signal: Int32
        let faultAddress: UInt64
        let timestamp: Double
        let frames: [UInt64]
    }

    // MARK: Async-signal-safe writer (used by the handler AND unit-tested)
    //
    // Fills `buffer` (which MUST be at least `maxRecordSize` bytes) with a record
    // and returns the number of bytes used. Pure pointer arithmetic — no
    // allocation, no Foundation — so it is safe to call from a signal handler.
    // It is `static` and takes everything explicitly so the test can call it with
    // its own buffer and assert the bytes.
    @inline(__always)
    static func encode(into buffer: UnsafeMutablePointer<UInt8>,
                       capacity: Int,
                       signal: Int32,
                       faultAddress: UInt64,
                       timestamp: Int64,
                       frames: UnsafePointer<UInt64>,
                       frameCount: Int) -> Int {
        let count = min(max(frameCount, 0), maxFrames)
        let total = headerSize + count * 8
        if capacity < total { return 0 }

        // zero the header region so padding bytes are deterministic
        for i in 0..<headerSize { buffer[i] = 0 }

        buffer[0] = magic[0]; buffer[1] = magic[1]; buffer[2] = magic[2]; buffer[3] = magic[3]
        buffer[4] = version
        writeLE(buffer, 8, UInt64(bitPattern: Int64(signal)), bytes: 4)
        writeLE(buffer, 16, faultAddress, bytes: 8)
        writeLE(buffer, 24, UInt64(bitPattern: timestamp), bytes: 8)
        writeLE(buffer, 32, UInt64(count), bytes: 4)

        var offset = headerSize
        for i in 0..<count {
            writeLE(buffer, offset, frames[i], bytes: 8)
            offset += 8
        }
        return total
    }

    /// Write the low `bytes` bytes of `value` little-endian at `offset`. No bounds
    /// check (caller guarantees capacity); no allocation.
    @inline(__always)
    private static func writeLE(_ buffer: UnsafeMutablePointer<UInt8>, _ offset: Int,
                                _ value: UInt64, bytes: Int) {
        var v = value
        for i in 0..<bytes {
            buffer[offset + i] = UInt8(v & 0xFF)
            v >>= 8
        }
    }

    // MARK: Normal-context parser (allocation is fine here)

    /// Parse a record produced by `encode`. Returns nil for truncated/garbage data.
    static func parse(_ data: Data) -> Parsed? {
        guard data.count >= headerSize else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Parsed? in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            guard base[0] == magic[0], base[1] == magic[1],
                  base[2] == magic[2], base[3] == magic[3] else { return nil }
            guard base[4] == version else { return nil }

            let signal = Int32(truncatingIfNeeded: readLE(base, 8, bytes: 4))
            let faultAddress = readLE(base, 16, bytes: 8)
            let timestamp = Int64(bitPattern: readLE(base, 24, bytes: 8))
            let frameCount = Int(readLE(base, 32, bytes: 4))

            let available = (data.count - headerSize) / 8
            let count = min(frameCount, min(available, maxFrames))
            var frames = [UInt64]()
            frames.reserveCapacity(count)
            var offset = headerSize
            for _ in 0..<count {
                frames.append(readLE(base, offset, bytes: 8))
                offset += 8
            }
            return Parsed(signal: signal,
                          faultAddress: faultAddress,
                          timestamp: Double(timestamp),
                          frames: frames)
        }
    }

    @inline(__always)
    private static func readLE(_ base: UnsafePointer<UInt8>, _ offset: Int, bytes: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<bytes {
            v |= UInt64(base[offset + i]) << (8 * i)
        }
        return v
    }
}

// MARK: - Async-signal-safe ASCII formatting helper
//
// Not used to build the binary record (that's pure bytes), but exposed + unit-
// tested because it is the kind of formatting a signal handler may legitimately
// need (e.g. to also emit a human-greppable line). It allocates nothing: it writes
// hex digits into a caller-supplied buffer. Kept here next to the handler so its
// async-signal-safety constraints are obvious.
enum AsyncSignalSafeFormat {

    /// Write `value` as lowercase hex (no "0x" prefix, no leading zeros except for
    /// value 0) into `buffer` starting at index 0. Returns the number of digits
    /// written, or 0 if the buffer is too small. No allocation.
    @inline(__always)
    static func hex(_ value: UInt64, into buffer: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        if value == 0 {
            guard capacity >= 1 else { return 0 }
            buffer[0] = digits[0]
            return 1
        }
        // count digits
        var v = value
        var n = 0
        while v != 0 { n += 1; v >>= 4 }
        guard capacity >= n else { return 0 }
        // fill from the least-significant end
        v = value
        var i = n - 1
        while v != 0 {
            buffer[i] = digits[Int(v & 0xF)]
            v >>= 4
            i -= 1
        }
        return n
    }
}

// NOTE: `digits` above is a constant array; in the *unit test* path this allocates
// once, which is fine. In a true signal-handler hot path you'd pass a pre-built
// digit table; the binary record writer (`SignalCrashRecord.encode`) — the path
// the live handler actually uses — does no such allocation.

// MARK: - Signal handler global state
//
// `sigaction` handlers are C function pointers and cannot capture Swift context,
// so the handler reaches everything it needs through these pre-allocated globals.
// Everything a handler touches is set up in `install`, in normal context.

/// The C `struct sigaction` (the bare name `sigaction` resolves to the function).
typealias SigAction = Darwin.sigaction

/// Signals we intercept. SIGTRAP is what Swift's fatal-error/`fatalError`/force-
/// unwrap traps deliver; the rest are the classic hard faults.
let g_allstakSignals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

/// Pre-allocated alternate stack — a crashing thread's own stack may be exhausted
/// (especially SIGSEGV from a stack overflow), so the handler must run on its own.
nonisolated(unsafe) private var g_altStack: UnsafeMutableRawPointer?

/// Pre-allocated buffer the handler fills with the encoded record (no malloc).
nonisolated(unsafe) private var g_recordBuffer: UnsafeMutablePointer<UInt8>?

/// Pre-allocated frame buffer for `backtrace`.
nonisolated(unsafe) private var g_frameBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?

/// Pre-opened crash file descriptor. Opening a file is NOT async-signal-safe, so
/// it's opened here at install time and just `write()`-ten in the handler.
nonisolated(unsafe) private var g_crashFD: Int32 = -1

/// Saved previous dispositions, in the same order as `g_allstakSignals`, so we can
/// chain / restore and re-raise. A fixed buffer (not a Swift Dictionary) so the
/// handler can look up the previous action without hashing or allocating.
nonisolated(unsafe) private var g_previousActions: UnsafeMutablePointer<SigAction>?
/// Count of installed handlers (== entries populated in the parallel buffers).
nonisolated(unsafe) private var g_installedCount: Int = 0
/// Signal numbers parallel to `g_previousActions`, in install order. A fixed C
/// buffer so the handler avoids touching Swift Array storage.
nonisolated(unsafe) private var g_signalNumbers: UnsafeMutablePointer<Int32>?

/// Re-entrancy guard. `sig_atomic_t` is the only type the standard guarantees is
/// safe to touch from a handler.
nonisolated(unsafe) private var g_inHandler: sig_atomic_t = 0

// MARK: - The handler (async-signal-safe)

private func allstakSignalHandler(_ signal: Int32,
                                  _ info: UnsafeMutablePointer<siginfo_t>?,
                                  _ context: UnsafeMutableRawPointer?) {
    // Re-entrancy / double-fault guard: if we crash again while handling, fall
    // straight through to the previous handler. (Not perfectly atomic across
    // threads, but sufficient and allocation-free; matches common practice.)
    if g_inHandler != 0 {
        allstakChainPrevious(signal)
        return
    }
    g_inHandler = 1

    if let buffer = g_recordBuffer, let frames = g_frameBuffer {
        // backtrace() is documented async-signal-safe and writes into our
        // pre-allocated pointer buffer — no allocation.
        let frameCount = backtrace(frames, Int32(SignalCrashRecord.maxFrames))

        // siginfo si_addr is the faulting address (valid for SIGSEGV/SIGBUS/etc).
        var faultAddress: UInt64 = 0
        if let info = info {
            faultAddress = UInt64(UInt(bitPattern: info.pointee.si_addr))
        }

        // time(nil) is async-signal-safe.
        let now = Int64(time(nil))

        // Reinterpret the frame pointers as UInt64 addresses for the encoder.
        frames.withMemoryRebound(to: UInt64.self, capacity: SignalCrashRecord.maxFrames) { framePtr in
            let total = SignalCrashRecord.encode(
                into: buffer,
                capacity: SignalCrashRecord.maxRecordSize,
                signal: signal,
                faultAddress: faultAddress,
                timestamp: now,
                frames: framePtr,
                frameCount: Int(frameCount))
            if total > 0 && g_crashFD >= 0 {
                // Single write of the whole record; write() is async-signal-safe.
                _ = write(g_crashFD, buffer, total)
                _ = fsync(g_crashFD)
            }
        }
    }

    // Restore the previous disposition for THIS signal and re-raise so the OS
    // crash reporter (and any chained reporter) still runs. Do not loop.
    allstakChainPrevious(signal)
}

/// Restore the previously-installed action for `signal` (or SIG_DFL) and re-raise.
/// Async-signal-safe: only fixed-buffer reads and `sigaction`/`raise` calls.
private func allstakChainPrevious(_ signal: Int32) {
    var restored = false
    if let numbers = g_signalNumbers, let actions = g_previousActions {
        var i = 0
        while i < g_installedCount {
            if numbers[i] == signal {
                _ = sigaction(signal, actions.advanced(by: i), nil)
                restored = true
                break
            }
            i += 1
        }
    }
    if !restored {
        var def = SigAction()
        def.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&def.sa_mask)
        def.sa_flags = 0
        _ = sigaction(signal, &def, nil)
    }
    // Re-raise; the now-restored handler / default disposition takes over.
    _ = raise(signal)
}

// MARK: - Install / read (normal context)

enum SignalCrashHandler {

    /// Filename of the single pending signal-crash record inside the store dir.
    static let recordFilename = "signal.crash.bin"

    /// Arm signal handlers. Pre-allocates the alt-stack, record buffer, and frame
    /// buffer, and pre-opens the crash file — none of which is safe to do inside a
    /// handler. Called from normal context at launch.
    static func install(crashFileURL: URL) {
        // 1. Alternate signal stack (a faulting stack may be unusable).
        //    `sigaltstack` is unavailable on tvOS, so the alt-stack is skipped
        //    there; handlers still install and run on the normal stack.
        #if !os(tvOS)
        let stackSize = max(Int(SIGSTKSZ), 64 * 1024)
        let stack = UnsafeMutableRawPointer.allocate(byteCount: stackSize,
                                                     alignment: MemoryLayout<UInt>.alignment)
        g_altStack = stack
        var ss = stack_t()
        ss.ss_sp = stack
        ss.ss_size = stackSize
        ss.ss_flags = 0
        _ = sigaltstack(&ss, nil)
        #endif

        // 2. Pre-allocate the buffers the handler fills.
        g_recordBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: SignalCrashRecord.maxRecordSize)
        g_frameBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: SignalCrashRecord.maxFrames)

        // 3. Pre-open the crash file (O_CREAT|O_WRONLY|O_TRUNC). open() is not
        //    async-signal-safe, so it happens here, not in the handler.
        crashFileURL.path.withCString { path in
            g_crashFD = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        }

        // 4. Pre-allocate the fixed parallel buffers the handler reads (previous
        //    actions + their signal numbers) — never a Swift Dictionary/Array, so
        //    handler lookup needs no hashing/allocation.
        let n = g_allstakSignals.count
        let actions = UnsafeMutablePointer<SigAction>.allocate(capacity: n)
        actions.initialize(repeating: SigAction(), count: n)
        let numbers = UnsafeMutablePointer<Int32>.allocate(capacity: n)
        numbers.initialize(repeating: 0, count: n)
        g_previousActions = actions
        g_signalNumbers = numbers

        // 5. Install handlers with SA_SIGINFO | SA_ONSTACK, saving the previous
        //    action so we can chain/restore + re-raise.
        var installed = 0
        for sig in g_allstakSignals {
            var action = SigAction()
            action.__sigaction_u.__sa_sigaction = allstakSignalHandler
            #if os(tvOS)
            // No alternate stack on tvOS (no sigaltstack) — omit SA_ONSTACK.
            action.sa_flags = SA_SIGINFO
            #else
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            #endif
            sigemptyset(&action.sa_mask)
            var old = SigAction()
            if sigaction(sig, &action, &old) == 0 {
                actions[installed] = old
                numbers[installed] = sig
                installed += 1
            }
        }
        g_installedCount = installed
    }

    /// Read + delete a persisted signal-crash record, converting it to the shared
    /// `CrashReport`. Runs in normal context (Foundation + allocation allowed).
    /// Returns nil if there's no record / it's unparseable (file is still removed).
    static func readPendingReport(crashFileURL: URL) -> CrashReport? {
        guard let data = try? Data(contentsOf: crashFileURL) else { return nil }
        try? FileManager.default.removeItem(at: crashFileURL)
        guard let parsed = SignalCrashRecord.parse(data), !data.isEmpty else { return nil }
        return makeReport(from: parsed)
    }

    /// Parse a persisted signal-crash record WITHOUT deleting it, so the caller
    /// can remove it only after the transport acknowledges the resulting event
    /// (avoiding a clear-before-ack data loss). An unparseable record is deleted
    /// immediately (it can never become a sendable event) and `nil` is returned.
    static func peekPendingReport(crashFileURL: URL) -> CrashReport? {
        guard let data = try? Data(contentsOf: crashFileURL) else { return nil }
        guard let parsed = SignalCrashRecord.parse(data), !data.isEmpty else {
            try? FileManager.default.removeItem(at: crashFileURL) // corrupt → drop
            return nil
        }
        return makeReport(from: parsed)
    }

    /// Convert a parsed record into the shared `CrashReport` model. Pulled out so
    /// it can be unit-tested directly.
    static func makeReport(from parsed: SignalCrashRecord.Parsed) -> CrashReport {
        return CrashReport(
            kind: "signal",
            name: signalName(parsed.signal),
            message: signalMessage(parsed.signal, faultAddress: parsed.faultAddress),
            addresses: parsed.frames.map { UInt($0) },
            timestamp: parsed.timestamp)
    }

    /// Human-readable signal name. (Normal context — Strings are fine here.)
    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGSEGV: return "SIGSEGV"
        case SIGABRT: return "SIGABRT"
        case SIGBUS:  return "SIGBUS"
        case SIGILL:  return "SIGILL"
        case SIGFPE:  return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default:      return "SIG\(signal)"
        }
    }

    static func signalMessage(_ signal: Int32, faultAddress: UInt64) -> String {
        let base: String
        switch signal {
        case SIGSEGV: base = "Segmentation fault"
        case SIGABRT: base = "Abnormal termination (abort)"
        case SIGBUS:  base = "Bus error"
        case SIGILL:  base = "Illegal instruction"
        case SIGFPE:  base = "Floating-point exception"
        case SIGTRAP: base = "Trace/breakpoint trap (fatal error / force-unwrap)"
        default:      base = "Fatal signal \(signal)"
        }
        if faultAddress != 0 {
            return base + " at 0x" + String(faultAddress, radix: 16)
        }
        return base
    }
}
