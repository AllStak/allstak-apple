# AllStak.podspec — CocoaPods manifest for the AllStak Apple SDK.
#
# This mirrors Package.swift (same platforms, same Swift sources) so the SDK is
# installable via either Swift Package Manager or CocoaPods. Foundation-only,
# no third-party dependencies.
#
# SINGLE SOURCE OF TRUTH FOR THE VERSION:
#   The runtime SDK version constant lives in
#   `Sources/AllStak/AllStakClient.swift` as `static let sdkVersion`.
#   `spec.version` below MUST equal that constant. They are bumped together on
#   every release; `AllStakVersionParityTests` fails the build if they drift.
#
Pod::Spec.new do |spec|
  spec.name         = "AllStak"
  spec.version      = "0.1.0" # keep in sync with AllStakClient.sdkVersion
  spec.summary      = "Official AllStak SDK for Apple platforms (iOS / macOS / tvOS)."
  spec.description  = <<-DESC
    Crash + error reporting for Apple apps: uncaught NSException and
    async-signal-safe POSIX signal capture, Sentry-style scope (breadcrumbs /
    user / tags / contexts), release-health sessions, PII scrubbing with a
    beforeSend hook, a reliable transport with offline persistence and
    retry/backoff, automatic outbound URLSession instrumentation, and native
    binary-image/UUID capture for server-side dSYM symbolication. Foundation
    only — no third-party dependencies.
  DESC
  spec.homepage     = "https://github.com/AllStak/allstak-apple"
  spec.license      = { :type => "MIT", :file => "LICENSE" }
  spec.author       = { "AllStak" => "support@allstak.sa" }

  spec.source       = {
    :git => "https://github.com/AllStak/allstak-apple.git",
    :tag => spec.version.to_s
  }

  # Platforms — must match Package.swift.
  spec.ios.deployment_target  = "13.0"
  spec.osx.deployment_target  = "11.0"
  spec.tvos.deployment_target = "13.0"

  spec.swift_versions = ["5.9"]

  # Sources — must match the AllStak target in Package.swift.
  spec.source_files = "Sources/AllStak/**/*.swift"

  # The dSYM uploader under Scripts/ is build-time/CI tooling, not part of the
  # compiled SDK, so it is intentionally not vendored here.
  spec.frameworks   = "Foundation"
end
