# AllStak Apple SDK

Official AllStak SDK for Apple platforms (iOS / macOS / tvOS), Swift. Captures
errors and reports them to AllStak with the data needed for **server-side dSYM
symbolication**: native instruction addresses + the process's loaded-image UUIDs.

> Status: early (0.2.0), dependency-free (Foundation / Darwin / MachO only — no
> third-party pods). Installable via Swift Package Manager **or** CocoaPods (see
> [Install](#install)). The full, current feature set is below.

## Features

What the SDK supports today (all our own code, Foundation-only):

- **Crash & error capture**
  - Automatic uncaught-`NSException` capture.
  - Async-signal-safe **POSIX signal** crash capture (SIGSEGV / SIGABRT /
    SIGBUS / SIGILL / SIGFPE / SIGTRAP — the dominant class of real Swift
    crashes: force-unwrap traps, out-of-bounds, bad pointer access). The handler
    runs on a pre-allocated alternate stack with a pre-opened crash fd, touches
    no heap, chains the previous handler, and re-raises so the OS crash report
    still generates.
  - Both channels are persisted to disk and sent on the **next launch** with the
    crash-time loaded-image layout.
  - Manual `AllStak.capture(error)` / `AllStak.capture(message:level:)`.
- **Scope** — standard breadcrumbs, `user`, `tags`, `contexts`, and `extra`,
  merged onto every event.
- **Release health** — automatic session tracking (start/end + crash-free
  sessions/users), with the resolved release stamped on every event/session.
- **Privacy** — PII scrubbing at the wire chokepoint, a `beforeSend` hook to
  edit/drop events, and a `sendDefaultPii` opt-in for default-redacted fields.
- **Reliable transport** — offline persistence (an on-disk envelope spool) plus
  retry with exponential backoff and `Retry-After` honoring, so events survive
  flaky networks and process restarts.
- **Outbound HTTP instrumentation** — automatic `URLSession` breadcrumbs
  (method, query-stripped URL, status, duration, size) with W3C
  `traceparent` + `baggage` propagation; the ingest host is always skipped.
- **Automatic UI / navigation / lifecycle breadcrumbs** — `UIViewController`
  appear/disappear (`navigation` + `ui` breadcrumbs with the screen's class and
  title) and app-state transitions (`app.lifecycle` breadcrumbs:
  active / inactive / foreground / background / memory warning). iOS / tvOS only,
  default-on, opt-out via `enableAutoBreadcrumbs: false`.
- **Automatic release detection** — explicit → `ALLSTAK_RELEASE` env → app
  `Info.plist` version → SDK version (never empty).
- **Native symbolication support** — sends instruction addresses +
  `debugMeta.images` (`LC_UUID`s) for server-side dSYM resolution, plus a
  build-time **dSYM upload script** for CI.

### Feature status (honest)

Implemented above (now also including **app-hang / ANR** detection,
**OOM / watchdog-termination** heuristics, and **MetricKit** ingestion).
**Still on the roadmap** (not yet in this SDK):

- **On-device E2E verification of the live signal handler.** The crash-record
  writer and the next-launch reader/parser are unit-tested; raising a real
  SIGSEGV in-process can't be done safely in CI, so the live handler still needs
  device verification.
- Performance tracing / spans, profiling, attachments, and screenshots are out
  of scope for now.

## Install

### Swift Package Manager

```swift
.package(url: "https://github.com/AllStak/allstak-apple.git", from: "0.2.0")
```

### CocoaPods

```ruby
pod 'AllStak', '~> 0.2'
```

> The CocoaPods `spec.version` and the runtime `AllStakClient.sdkVersion`
> constant are a **single source of truth** — they are bumped together on every
> release, and `AllStakVersionParityTests` fails the build if they drift.

## Usage

```swift
import AllStak

// Once, at launch:
AllStak.start(
    apiKey: "astk_live_xxxxxxxx",
    environment: "production",
    release: "1.4.2"
)

// Report an error:
do { try risky() } catch { AllStak.capture(error) }

// Or a message:
AllStak.capture(message: "checkout failed", level: "warning")
```

## Automatic HTTP instrumentation

On by default, the SDK observes the outbound `URLSession` requests your app makes
and records a redacted `http` breadcrumb for each — method, **query-stripped** URL,
status code, duration, and response size — including failed requests. When a trace
context exists it also attaches W3C `traceparent` + `baggage` headers to the
outbound request for distributed tracing, so a request that lands on your AllStak
backend correlates with the mobile session that made it.

It is fail-open and never breaks your networking: the SDK's own ingest host is
always skipped (no recursion), URLs and recorded metadata are run through the same
PII redaction as everything else (no tokens in breadcrumb URLs), and on any
internal failure the request is forwarded untouched. Opt out with:

```swift
AllStak.start(apiKey: "astk_live_xxxxxxxx",
              enableAutoHttpInstrumentation: false)
```

## Automatic UI / navigation / lifecycle breadcrumbs

On by default (iOS / tvOS), the SDK records breadcrumbs for what your app is
*doing* — with no per-call code — so the trail attached to a captured event shows
the screens and app-state transitions that led up to it:

- **Navigation / UI** — `UIViewController.viewDidAppear` records a `navigation`
  breadcrumb (the screen that became visible) and `viewWillDisappear` records a
  `ui` breadcrumb (the screen that is leaving). Each carries the controller's
  class name and, when set, its `title`.
- **App lifecycle** — `app.lifecycle` breadcrumbs for `active` / `inactive` /
  `foreground` / `background` / `memory_warning` transitions.

This is fully fail-open: it forwards to the original `UIViewController`
implementations untouched, only records class names and titles (no request
bodies, URLs, or user input), and is a no-op on macOS / headless platforms and
under tests. Opt out with:

```swift
AllStak.start(apiKey: "astk_live_xxxxxxxx",
              enableAutoBreadcrumbs: false)
```

## Release identifier (automatic)

If you omit `release`, the SDK auto-detects it. Resolution order, highest first:

1. **Explicit** `release:` you pass to `start` — always wins.
2. **`ALLSTAK_RELEASE`** read from the process environment (build-time override).
3. **App version** read at runtime from the host app's `Info.plist`
   (`CFBundleShortVersionString` + `CFBundleVersion`), formatted `1.4.2 (123)`.
4. **SDK version** as a last resort, so `release` is never empty.

```swift
// No release passed — auto-detects the app's Info.plist version, e.g. "1.4.2 (123)":
AllStak.start(apiKey: "astk_live_xxxxxxxx", environment: "production")

// Opt out of all automatic detection (only an explicit release is ever sent):
AllStak.start(apiKey: "astk_live_xxxxxxxx", release: "1.4.2", autoDetectRelease: false)
```

**Honest note on git on mobile.** A shipped `.app`/`.ipa` contains no `.git`
directory and no `git` binary, so there is no runtime git detection in
production. The genuinely automatic, runtime-available release identifier for a
mobile app is its own `Info.plist` version — which is what step 3 reads.

**Embedding a git SHA (recommended).** To tie events to a commit, inject the SHA
at build time and forward it as `ALLSTAK_RELEASE`. For example, in a build phase
or CI step set it in the app's `Info.plist`/environment, or pass it explicitly:

```sh
# In CI, before archiving:
export ALLSTAK_RELEASE="1.4.2+$(git rev-parse --short HEAD)"
```

Then `AllStak.start(...)` with no `release` picks it up automatically. (We
deliberately do **not** ship an SPM prebuild plugin to embed the SHA: it would
add build-graph complexity for a one-line CI export. Keep it in CI.)

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

## Uploading dSYMs (server-side symbolication)

Symbolication happens on the server, so the backend needs the **dSYM** for every
release you ship. Use the bundled uploader at
[`Scripts/allstak-upload-dsyms.sh`](Scripts/allstak-upload-dsyms.sh) — a
dependency-free POSIX shell script (only `curl`) that finds your `.dSYM` bundles,
locates the DWARF Mach-O inside each (`Contents/Resources/DWARF/<binary>`), and
uploads the raw binary to AllStak. A universal dSYM registers one slice per arch
server-side (the server reads each slice's `LC_UUID`/`debugId` + `__TEXT` vmaddr).

It is build-time / CI tooling only — it is **not** part of the runtime SDK and
does not affect `swift build` / `swift test`.

### Credentials

The upload uses a **user/CI bearer token with the `SOURCEMAPS_UPLOAD`
capability**, scoped to a project id. This is **not** the runtime `X-AllStak-Key`
ingest key — never bake an upload token into your app.

| Input | Flag | Env var |
|-------|------|---------|
| API base URL | `--api` | `ALLSTAK_API` |
| Project id (UUID) | `--project-id` | `ALLSTAK_PROJECT_ID` |
| Bearer upload token | `--token` | `ALLSTAK_AUTH_TOKEN` |
| dSYM search path(s) | `--path` (repeatable) | Xcode `DWARF_DSYM_FOLDER_PATH` / `DWARF_DSYM_FILE_NAME` |

`--dry-run` prints what would be uploaded and makes no network calls. The script
is idempotent and CI-friendly: exit `0` = all uploaded, `1` = bad usage / missing
credential, `2` = an upload failed (or a file exceeded the 64 MB limit), `3` = no
dSYM found.

```sh
# Manual / local upload of an archive's dSYMs:
ALLSTAK_API=https://api.allstak.sa \
ALLSTAK_PROJECT_ID=11111111-2222-3333-4444-555555555555 \
ALLSTAK_AUTH_TOKEN=ci-upload-token \
  Scripts/allstak-upload-dsyms.sh --path "MyApp.xcarchive/dSYMs"

# See what it would do, no network:
Scripts/allstak-upload-dsyms.sh --dry-run --path "MyApp.xcarchive/dSYMs"
```

### Xcode "Run Script" build phase

Add a **Run Script** phase (Target → Build Phases → +) **after** "Compile
Sources". Xcode exports `DWARF_DSYM_FOLDER_PATH` / `DWARF_DSYM_FILE_NAME`, so the
script needs no `--path`. Set `DEBUG_INFORMATION_FORMAT = DWARF with dSYM File`
(the default for Release/Archive) so a dSYM is actually produced.

```sh
# Only upload for release builds; keep debug builds fast.
if [ "${CONFIGURATION}" != "Release" ]; then
  echo "[allstak] skipping dSYM upload for ${CONFIGURATION}"
  exit 0
fi

export ALLSTAK_API="https://api.allstak.sa"
export ALLSTAK_PROJECT_ID="11111111-2222-3333-4444-555555555555"
# Provide ALLSTAK_AUTH_TOKEN via the build environment / a CI secret —
# do NOT hard-code an upload token in the project file.

"${SRCROOT}/Scripts/allstak-upload-dsyms.sh"
```

(For SwiftPM-consumed projects, point `${SRCROOT}` at wherever you vendor the
script, or call it from the checkout under `…/allstak-apple/Scripts/`.)

### CI example (GitHub Actions)

```yaml
- name: Archive
  run: |
    xcodebuild -scheme MyApp -configuration Release \
      -archivePath build/MyApp.xcarchive archive

- name: Upload dSYMs to AllStak
  env:
    ALLSTAK_API: https://api.allstak.sa
    ALLSTAK_PROJECT_ID: ${{ vars.ALLSTAK_PROJECT_ID }}
    ALLSTAK_AUTH_TOKEN: ${{ secrets.ALLSTAK_UPLOAD_TOKEN }}
  run: |
    ./Scripts/allstak-upload-dsyms.sh --path build/MyApp.xcarchive/dSYMs
```

Run it for the **same release** your app reports (see the release section above)
so crash events for that build resolve to `file:line:symbol`.

## Field contract

Event field names match the AllStak ingest API (camelCase). Unknown fields are
ignored server-side, so `instructionAddr` is forward-compatible while the backend
ingest contract for native addresses lands.

## Contributing and Support

- Report bugs with the GitHub bug report template: https://github.com/AllStak/allstak-apple/issues/new/choose
- Open pull requests using the checklist in [CONTRIBUTING.md](CONTRIBUTING.md).
- Report security vulnerabilities privately through [SECURITY.md](SECURITY.md).
