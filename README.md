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
> raised safely in CI). Build-time **dSYM upload tooling** for server-side
> symbolication ships in [`Scripts/`](Scripts/allstak-upload-dsyms.sh) (see
> [Uploading dSYMs](#uploading-dsyms-server-side-symbolication)). On the roadmap:
> scope/breadcrumbs.

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
