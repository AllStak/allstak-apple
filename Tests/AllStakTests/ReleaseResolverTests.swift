import XCTest
@testable import AllStak

/// Verifies the release resolution order. The bundle/info-dictionary lookup and
/// the env lookup are injected as seams so we can assert ordering without a real
/// app bundle or process environment.
final class ReleaseResolverTests: XCTestCase {

    private let sdkVersion = "0.1.0"

    // MARK: appVersion formatting

    func testAppVersionFormatsShortAndBuild() {
        let v = ReleaseResolver.appVersion(from: [
            "CFBundleShortVersionString": "1.4.2",
            "CFBundleVersion": "123",
        ])
        XCTAssertEqual(v, "1.4.2 (123)")
    }

    func testAppVersionOmitsBuildWhenEqualToShort() {
        let v = ReleaseResolver.appVersion(from: [
            "CFBundleShortVersionString": "1.4.2",
            "CFBundleVersion": "1.4.2",
        ])
        XCTAssertEqual(v, "1.4.2")
    }

    func testAppVersionShortOnlyWhenNoBuild() {
        let v = ReleaseResolver.appVersion(from: ["CFBundleShortVersionString": "2.0.0"])
        XCTAssertEqual(v, "2.0.0")
    }

    func testAppVersionNilWhenNoMarketingVersion() {
        XCTAssertNil(ReleaseResolver.appVersion(from: ["CFBundleVersion": "999"]))
        XCTAssertNil(ReleaseResolver.appVersion(from: [:]))
        XCTAssertNil(ReleaseResolver.appVersion(from: nil))
    }

    // MARK: resolution order

    func testExplicitReleaseAlwaysWins() {
        let release = ReleaseResolver.resolve(
            explicit: "9.9.9",
            autoDetect: true,
            sdkVersion: sdkVersion,
            infoDictionary: { ["CFBundleShortVersionString": "1.4.2", "CFBundleVersion": "123"] },
            environment: { _ in "env-release" })
        XCTAssertEqual(release, "9.9.9", "explicit must beat env and app version")
    }

    func testExplicitWinsEvenWhenAutoDetectIsOff() {
        let release = ReleaseResolver.resolve(
            explicit: "9.9.9",
            autoDetect: false,
            sdkVersion: sdkVersion,
            infoDictionary: { nil },
            environment: { _ in nil })
        XCTAssertEqual(release, "9.9.9")
    }

    func testEnvBeatsAppVersion() {
        let release = ReleaseResolver.resolve(
            explicit: nil,
            autoDetect: true,
            sdkVersion: sdkVersion,
            infoDictionary: { ["CFBundleShortVersionString": "1.4.2", "CFBundleVersion": "123"] },
            environment: { key in key == "ALLSTAK_RELEASE" ? "ci-deadbeef" : nil })
        XCTAssertEqual(release, "ci-deadbeef")
    }

    func testAppVersionUsedWhenNoExplicitOrEnv() {
        let release = ReleaseResolver.resolve(
            explicit: nil,
            autoDetect: true,
            sdkVersion: sdkVersion,
            infoDictionary: { ["CFBundleShortVersionString": "1.4.2", "CFBundleVersion": "123"] },
            environment: { _ in nil })
        XCTAssertEqual(release, "1.4.2 (123)",
                       "CFBundleShortVersionString must drive the automatic release")
    }

    func testFallsBackToSdkVersionWhenNothingAvailable() {
        let release = ReleaseResolver.resolve(
            explicit: nil,
            autoDetect: true,
            sdkVersion: sdkVersion,
            infoDictionary: { nil },
            environment: { _ in nil })
        XCTAssertEqual(release, sdkVersion, "release must never be empty as a last resort")
    }

    func testEmptyExplicitTreatedAsAbsent() {
        let release = ReleaseResolver.resolve(
            explicit: "",
            autoDetect: true,
            sdkVersion: sdkVersion,
            infoDictionary: { ["CFBundleShortVersionString": "3.1.0"] },
            environment: { _ in nil })
        XCTAssertEqual(release, "3.1.0")
    }

    func testAutoDetectOffYieldsNilWhenNoExplicit() {
        let release = ReleaseResolver.resolve(
            explicit: nil,
            autoDetect: false,
            sdkVersion: sdkVersion,
            infoDictionary: { ["CFBundleShortVersionString": "1.4.2"] },
            environment: { _ in "ci-x" })
        XCTAssertNil(release, "opt-out must suppress all automatic sources")
    }

    func testBlankEnvIgnored() {
        let release = ReleaseResolver.resolve(
            explicit: nil,
            autoDetect: true,
            sdkVersion: sdkVersion,
            infoDictionary: { ["CFBundleShortVersionString": "1.4.2"] },
            environment: { _ in "   " })
        XCTAssertEqual(release, "1.4.2", "whitespace-only env must fall through to app version")
    }

    // MARK: client integration

    func testClientStampsExplicitRelease() {
        let client = AllStakClient(apiKey: "k", host: "https://h.test",
                                   environment: "test", release: "1.0.0")
        let event = client.buildEvent(exceptionClass: "E", message: "m",
                                       level: "error", addresses: [0x1])
        XCTAssertEqual(event.release, "1.0.0")
    }

    func testClientFallsBackToSdkVersionInTestBundle() {
        // SwiftPM test bundles have no CFBundleShortVersionString, so with no
        // explicit release and no env override, the client falls back to the
        // SDK version (release is never nil/empty).
        let client = AllStakClient(apiKey: "k", host: "https://h.test",
                                   environment: "test", release: nil)
        let event = client.buildEvent(exceptionClass: "E", message: "m",
                                       level: "error", addresses: [0x1])
        // Either an injected ALLSTAK_RELEASE (if the CI env sets one) or the
        // SDK version — never empty.
        XCTAssertNotNil(event.release)
        XCTAssertFalse(event.release?.isEmpty ?? true)
    }
}
