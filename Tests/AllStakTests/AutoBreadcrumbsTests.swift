import XCTest
@testable import AllStak

/// Automatic navigation / UI / app-lifecycle breadcrumbs: a screen appearing
/// records a `navigation` breadcrumb, a screen leaving records a `ui` breadcrumb,
/// app-state transitions record `app.lifecycle` breadcrumbs, all carry the right
/// shape, and the opt-out (`disable()`) makes every recording a transparent
/// no-op.
///
/// The `UIViewController` swizzle and the `NotificationCenter` observers are NOT
/// installed under XCTest (mirroring the HTTP / app-hang / watchdog paths — a test
/// must never patch `UIViewController` globally or spin real observers), so these
/// tests drive the pure breadcrumb *builders* directly against the live scope,
/// exactly the path the swizzle / observers call into in production.
final class AutoBreadcrumbsTests: XCTestCase {

    /// Reset the shared coordinator between tests so config never leaks. `install`
    /// re-points the scope + enables; `disable` opts out. The swizzle install is a
    /// no-op under XCTest, so this only refreshes the in-memory config.
    override func tearDown() {
        AutoBreadcrumbs.shared.disable()
        super.tearDown()
    }

    // MARK: 1. Screen-appear records a navigation breadcrumb

    func testScreenAppearRecordsNavigationBreadcrumb() throws {
        let scope = Scope()
        AutoBreadcrumbs.shared.install(scope: scope)

        AutoBreadcrumbs.shared.recordScreenAppear(screen: "CheckoutViewController",
                                                  title: "Checkout")

        let crumb = try XCTUnwrap(scope.breadcrumbs.first { $0.type == "navigation" },
                                  "screen appear must record a navigation breadcrumb")
        XCTAssertEqual(crumb.category, "navigation")
        XCTAssertEqual(crumb.level, "info")
        XCTAssertEqual(crumb.message, "CheckoutViewController")
        XCTAssertEqual(crumb.data?["screen"], .string("CheckoutViewController"))
        XCTAssertEqual(crumb.data?["state"], .string("appeared"))
        XCTAssertEqual(crumb.data?["title"], .string("Checkout"))
    }

    func testScreenAppearOmitsEmptyTitle() throws {
        let scope = Scope()
        AutoBreadcrumbs.shared.install(scope: scope)

        AutoBreadcrumbs.shared.recordScreenAppear(screen: "HomeViewController", title: nil)
        let crumb = try XCTUnwrap(scope.breadcrumbs.first { $0.type == "navigation" })
        XCTAssertNil(crumb.data?["title"], "a nil title must be omitted from the breadcrumb data")
        XCTAssertEqual(crumb.data?["screen"], .string("HomeViewController"))
    }

    // MARK: 2. Screen-disappear records a ui breadcrumb

    func testScreenDisappearRecordsUiBreadcrumb() throws {
        let scope = Scope()
        AutoBreadcrumbs.shared.install(scope: scope)

        AutoBreadcrumbs.shared.recordScreenDisappear(screen: "SettingsViewController",
                                                     title: "Settings")
        let crumb = try XCTUnwrap(scope.breadcrumbs.first { $0.type == "ui" },
                                  "screen disappear must record a ui breadcrumb")
        XCTAssertEqual(crumb.category, "ui.lifecycle")
        XCTAssertEqual(crumb.level, "info")
        XCTAssertEqual(crumb.message, "SettingsViewController")
        XCTAssertEqual(crumb.data?["state"], .string("disappeared"))
        XCTAssertEqual(crumb.data?["title"], .string("Settings"))
    }

    // MARK: 3. App-lifecycle transitions record app.lifecycle breadcrumbs

    func testLifecycleRecordsAppLifecycleBreadcrumb() throws {
        let scope = Scope()
        AutoBreadcrumbs.shared.install(scope: scope)

        AutoBreadcrumbs.shared.recordLifecycle(state: "background")
        let crumb = try XCTUnwrap(scope.breadcrumbs.first { $0.category == "app.lifecycle" })
        // `info` is a valid breadcrumb type in the allowlist; lifecycle is not a
        // navigation event, so it is recorded as info under the app.lifecycle category.
        XCTAssertEqual(crumb.type, "info")
        XCTAssertEqual(crumb.level, "info")
        XCTAssertEqual(crumb.message, "App background")
        XCTAssertEqual(crumb.data?["state"], .string("background"))
    }

    func testMultipleLifecycleTransitionsAllRecorded() {
        let scope = Scope()
        AutoBreadcrumbs.shared.install(scope: scope)

        for state in ["foreground", "active", "inactive", "background", "memory_warning"] {
            AutoBreadcrumbs.shared.recordLifecycle(state: state)
        }
        let lifecycle = scope.breadcrumbs.filter { $0.category == "app.lifecycle" }
        XCTAssertEqual(lifecycle.count, 5, "every lifecycle transition records a breadcrumb")
        XCTAssertEqual(lifecycle.last?.data?["state"], .string("memory_warning"))
    }

    // MARK: 4. Opt-out (disable) makes every recording a no-op

    func testDisableOptsOutOfAllRecording() {
        let scope = Scope()
        AutoBreadcrumbs.shared.install(scope: scope)
        AutoBreadcrumbs.shared.disable()

        AutoBreadcrumbs.shared.recordScreenAppear(screen: "X", title: nil)
        AutoBreadcrumbs.shared.recordScreenDisappear(screen: "X", title: nil)
        AutoBreadcrumbs.shared.recordLifecycle(state: "background")

        XCTAssertTrue(scope.breadcrumbs.isEmpty,
                      "a disabled coordinator must record nothing (transparent no-op)")
    }

    // MARK: 5. Re-install re-points the scope (parity with the HTTP coordinator)

    func testReinstallRepointsScope() throws {
        let first = Scope()
        AutoBreadcrumbs.shared.install(scope: first)
        let second = Scope()
        AutoBreadcrumbs.shared.install(scope: second) // re-point

        AutoBreadcrumbs.shared.recordScreenAppear(screen: "AfterReinstall", title: nil)

        XCTAssertTrue(first.breadcrumbs.isEmpty, "the old scope must no longer receive crumbs")
        XCTAssertEqual(second.breadcrumbs.count, 1, "the new scope receives the crumb")
        XCTAssertEqual(second.breadcrumbs.first?.data?["screen"], .string("AfterReinstall"))
    }

    // MARK: 6. No live scope → no crash, no recording (weak scope released)

    func testNoScopeIsFailOpen() {
        // Install against a scope that is then released; the coordinator holds it
        // weakly, so recording afterwards must be a safe no-op (never a crash).
        autoreleasepool {
            let transient = Scope()
            AutoBreadcrumbs.shared.install(scope: transient)
        }
        // No assertion on a buffer (the scope is gone); the contract is simply
        // that this does not crash and silently records nothing.
        AutoBreadcrumbs.shared.recordLifecycle(state: "background")
    }

    // MARK: 7. Auto-breadcrumbs and HTTP breadcrumbs share the same scope buffer

    func testAutoBreadcrumbsCoexistWithManualBreadcrumbs() {
        let scope = Scope()
        AutoBreadcrumbs.shared.install(scope: scope)

        // A manual breadcrumb (as the public API records) plus an auto one land in
        // the same FIFO buffer in order.
        scope.addBreadcrumb(type: "user", message: "tapped login", category: "ui.click")
        AutoBreadcrumbs.shared.recordScreenAppear(screen: "LoginViewController", title: nil)

        XCTAssertEqual(scope.breadcrumbs.count, 2)
        XCTAssertEqual(scope.breadcrumbs.first?.type, "user")
        XCTAssertEqual(scope.breadcrumbs.last?.type, "navigation")
    }
}
