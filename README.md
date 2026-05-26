# AllStak Apple SDK

Official AllStak SDK for Apple platforms (iOS / macOS / tvOS), Swift. Captures
errors and reports them to AllStak with the data needed for **server-side dSYM
symbolication**: native instruction addresses + the process's loaded-image UUIDs.

> Status: early (0.1.0). Implemented (dependency-free, our own code — only
> Foundation / Darwin / MachO): package, native binary-image/UUID capture, manual
> error capture + transport, **automatic uncaught-`NSException` crash capture**, and
> **async-signal-safe POSIX signal crash capture** (SIGSEGV / SIGABRT / SIGBUS /
> SIGILL / SIGFPE / SIGTRAP — the dominant class of real Swift crashes: force-unwrap
> traps, out-of-bounds, bad pointer access). Both channels are persisted to disk and
> sent on the next launch with the crash-time image layout. The signal handler runs
> on a pre-allocated alternate stack with a pre-opened crash fd, touches no heap,
> chains the previous handler, and re-raises so the OS crash report still generates.
> The record writer and the next-launch reader/parser are unit-tested; the live
> in-process handler is **pending on-device verification** (a real SIGSEGV can't be
> raised safely in CI). On the roadmap: scope/breadcrumbs and dSYM upload tooling.

## Install (Swift Package Manager)

```swift
.package(url: "https://github.com/AllStak/allstak-apple.git", from: "0.1.0")
```

## Usage

```swift
import AllStak

// Once, at launch:
AllStak.start(
    apiKey: "astk_live_xxxxxxxx",
    host: "https://api.allstak.sa",
    environment: "production",
    release: "1.4.2"
)

// Report an error:
do { try risky() } catch { AllStak.capture(error) }

// Or a message:
AllStak.capture(message: "checkout failed", level: "warning")
```

## How native symbolication works

Apple crash frames are raw instruction addresses, not symbols. This SDK sends, per
event:

- **frames** with the runtime `instructionAddr` (and `inApp`),
- **debugMeta.images** — every loaded Mach-O image's `debugId` (its `LC_UUID`),
  `imageAddr` (load address), and `codeFile`.

The backend matches each frame's image by **UUID** to the **dSYM you upload for the
release**, computes the static address (`instructionAddr − imageAddr + __TEXT
vmaddr`), and resolves it to `file:line:symbol` with `llvm-symbolizer` (including
inlined frames). Upload your build's dSYM in CI so events for that release resolve.

## Field contract

Event field names match the AllStak ingest API (camelCase). Unknown fields are
ignored server-side, so `instructionAddr` is forward-compatible while the backend
ingest contract for native addresses lands.
