# Changelog

All notable changes to the AllStak Apple SDK are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Version source of truth.** The runtime `AllStakClient.sdkVersion` constant
> and `AllStak.podspec`'s `spec.version` must match; bump them together on every
> release. `AllStakVersionParityTests` enforces this at build time.

## [Unreleased]

### Added

- **Crash capture.** Automatic uncaught-`NSException` capture and
  async-signal-safe POSIX signal crash capture (SIGSEGV / SIGABRT / SIGBUS /
  SIGILL / SIGFPE / SIGTRAP). Both channels persist to disk and send on the next
  launch with the crash-time loaded-image layout.
- **Scope.** Sentry-style scope: breadcrumbs, `user`, `tags`, `contexts`, and
  `extra`, merged onto every event.
- **Release health.** Automatic session tracking (start/end, crash-free
  sessions/users) with the resolved release stamped on events and sessions.
- **Privacy.** PII scrubbing at the wire chokepoint, a `beforeSend` hook to
  edit/drop events, and a `sendDefaultPii` opt-in.
- **Reliable transport.** On-disk envelope spool for offline persistence, plus
  retry with exponential backoff and `Retry-After` honoring.
- **Outbound HTTP instrumentation.** Automatic `URLSession` breadcrumbs
  (method, query-stripped URL, status, duration, size) with W3C
  `traceparent` + `baggage` propagation; the ingest host is always skipped.
- **Automatic release detection.** Explicit → `ALLSTAK_RELEASE` env → app
  `Info.plist` version → SDK version (never empty).
- **Native symbolication support.** Instruction addresses + `debugMeta.images`
  (`LC_UUID`s) for server-side dSYM resolution, with a build-time dSYM upload
  script (`Scripts/allstak-upload-dsyms.sh`) for CI.
- **CocoaPods support.** `AllStak.podspec` mirrors `Package.swift` (iOS 13+,
  macOS 11+, tvOS 13+), so the SDK installs via Swift Package Manager **or**
  CocoaPods. Its version is kept in lockstep with the runtime SDK version
  constant, guarded by `AllStakVersionParityTests`.

### Not yet implemented (roadmap)

- App-hang / ANR detection (main-thread watchdog).
- OOM / watchdog-termination heuristics and MetricKit ingestion.
- On-device end-to-end verification of the live signal handler.
- Performance tracing / spans, profiling, UI auto-instrumentation, attachments,
  and screenshots.
