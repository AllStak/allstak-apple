import XCTest
import Foundation
@testable import AllStak

/// Guards the single source of truth for the SDK version.
///
/// The runtime version constant (`AllStakClient.sdkVersion`) and the CocoaPods
/// manifest (`AllStak.podspec`'s `spec.version`) must declare the *same*
/// version. They are physically separate files (one Swift, one Ruby), so they
/// can silently drift on a release bump — these tests fail the build if they do,
/// turning "remember to bump both" into an enforced invariant.
final class AllStakVersionParityTests: XCTestCase {

    /// Repo root, derived from this test file's location
    /// (`<repo>/Tests/AllStakTests/<this>` -> `<repo>`), mirroring the helper in
    /// `UploadDsymsScriptTests`.
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AllStakTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    /// Extracts the `spec.version = "x.y.z"` value from the podspec, ignoring
    /// the trailing `# keep in sync ...` comment.
    private func podspecVersion() throws -> String? {
        let podspec = repoRoot().appendingPathComponent("AllStak.podspec")
        let text = try String(contentsOf: podspec, encoding: .utf8)
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("spec.version") else { continue }
            // spec.version      = "0.1.0" # comment
            guard let firstQuote = line.firstIndex(of: "\""),
                  let lastQuote = line[line.index(after: firstQuote)...].firstIndex(of: "\"")
            else { return nil }
            return String(line[line.index(after: firstQuote)..<lastQuote])
        }
        return nil
    }

    func testPodspecExists() {
        let podspec = repoRoot().appendingPathComponent("AllStak.podspec")
        XCTAssertTrue(FileManager.default.fileExists(atPath: podspec.path),
                      "AllStak.podspec must exist at the repo root for CocoaPods installs")
    }

    func testPodspecVersionMatchesRuntimeConstant() throws {
        let podVersion = try podspecVersion()
        XCTAssertNotNil(podVersion, "could not parse spec.version from AllStak.podspec")
        XCTAssertEqual(
            podVersion, AllStakClient.sdkVersion,
            "AllStak.podspec spec.version must equal AllStakClient.sdkVersion — " +
            "bump both together (single source of truth).")
    }

    func testSdkVersionIsSemverShaped() {
        let v = AllStakClient.sdkVersion
        let parts = v.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "sdkVersion should be MAJOR.MINOR.PATCH, got \(v)")
        for p in parts {
            XCTAssertTrue(p.allSatisfy { $0.isNumber }, "non-numeric semver component in \(v)")
        }
    }
}
