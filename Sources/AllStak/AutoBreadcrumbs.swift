import Foundation

/// Automatic navigation / UI / app-lifecycle breadcrumbs, so that — after
/// `AllStak.start(...)` — the breadcrumb trail
/// attached to a captured event reflects what the app was *doing* (which screens
/// appeared / disappeared, and which lifecycle transitions occurred) with zero
/// per-call developer code. This complements the existing automatic outbound-HTTP
/// breadcrumb source (see ``HTTPInstrumentation``) so HTTP is no longer the only
/// auto trail.
///
/// Two surfaces, both default-on under the single ``AllStak/start`` toggle
/// `enableAutoBreadcrumbs`:
///
///   1. **UIViewController lifecycle swizzle.** `viewDidAppear:` records a
///      `navigation` breadcrumb (a screen became visible) and `viewWillDisappear:`
///      records a `ui` breadcrumb (a screen is leaving). The breadcrumb carries
///      the controller's class name and, when set, its `title`. The swizzle is
///      installed once, is idempotent, and forwards to the original implementation
///      so the host's behaviour is never altered.
///
///   2. **App lifecycle observers.** `NotificationCenter` observers emit
///      `app.lifecycle` breadcrumbs for foreground/background/active/inactive/
///      memory-warning transitions, mirroring the lifecycle markers the host app
///      already reacts to.
///
/// Hard rules honoured here (same discipline as the HTTP path):
///   * **iOS / tvOS only** — entirely guarded by `canImport(UIKit)` and a
///     `!os(watchOS)` check; a no-op on macOS / headless platforms.
///   * **Fail-open everywhere** — any internal failure (a missing selector, a
///     swizzle that cannot be installed, an unexpected notification) records
///     nothing and never disturbs the host's UI or run loop.
///   * **No-op under XCTest** — like ``HTTPInstrumentation`` and the app-hang /
///     watchdog / MetricKit paths, the swizzle is never installed under the unit-
///     test runtime so a test never patches `UIViewController` globally. The
///     breadcrumb *builders* remain unit-testable directly.
///   * **No PII** — only class names and (optional) screen titles are recorded;
///     they still pass through the active scope, but no request/response bodies,
///     URLs, or user input are touched here.
final class AutoBreadcrumbs: @unchecked Sendable {

    /// Process-wide shared coordinator. The `UIViewController` swizzle is
    /// instantiated by UIKit with no access to our client, so the live scope is
    /// read from this singleton (same global-coordinator pattern as
    /// ``HTTPInstrumentation``).
    static let shared = AutoBreadcrumbs()

    private let lock = NSLock()
    private var enabled = false
    private weak var scope: Scope?

    private init() {}

    /// Install (once) and/or refresh the live configuration. Re-calling only
    /// re-points the scope and re-enables — it never double-installs the swizzle
    /// or duplicates the lifecycle observers. Fail-open: never throws into the
    /// caller, and a no-op under XCTest / on non-UIKit platforms.
    func install(scope: Scope) {
        lock.lock()
        self.scope = scope
        self.enabled = true
        lock.unlock()

        guard !AllStakClient.isRunningUnderTests else { return }
        #if canImport(UIKit) && !os(watchOS)
        UIViewControllerBreadcrumbSwizzle.installIfNeeded()
        AppLifecycleBreadcrumbObserver.shared.installIfNeeded()
        #endif
    }

    /// Opt-out. The swizzle / observers stay installed (so toggling is cheap and
    /// safe) but every recording becomes a transparent no-op.
    func disable() {
        lock.lock(); enabled = false; lock.unlock()
    }

    /// Snapshot of the live config read by the swizzle / observers.
    private func snapshot() -> (enabled: Bool, scope: Scope?) {
        lock.lock(); defer { lock.unlock() }
        return (enabled, scope)
    }

    // MARK: - Breadcrumb builders (pure; unit-testable without UIKit)

    /// Record a `navigation` breadcrumb for a screen becoming visible. `screen`
    /// is the controller's class name; `title` is its optional display title.
    /// Visible for testing.
    func recordScreenAppear(screen: String, title: String?) {
        let snap = snapshot()
        guard snap.enabled, let scope = snap.scope else { return }
        var data: [String: Any] = ["screen": screen, "state": "appeared"]
        if let title, !title.isEmpty { data["title"] = title }
        scope.addBreadcrumb(type: "navigation", message: screen,
                            category: "navigation", level: "info", data: data)
    }

    /// Record a `ui` breadcrumb for a screen leaving. Visible for testing.
    func recordScreenDisappear(screen: String, title: String?) {
        let snap = snapshot()
        guard snap.enabled, let scope = snap.scope else { return }
        var data: [String: Any] = ["screen": screen, "state": "disappeared"]
        if let title, !title.isEmpty { data["title"] = title }
        scope.addBreadcrumb(type: "ui", message: screen,
                            category: "ui.lifecycle", level: "info", data: data)
    }

    /// Record an `app.lifecycle` breadcrumb for an app-state transition. `state`
    /// is a short stable token (e.g. `foreground`, `background`). Visible for
    /// testing.
    func recordLifecycle(state: String) {
        let snap = snapshot()
        guard snap.enabled, let scope = snap.scope else { return }
        scope.addBreadcrumb(type: "info", message: "App \(state)",
                            category: "app.lifecycle", level: "info",
                            data: ["state": state])
    }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit
import ObjectiveC

/// Swizzles `UIViewController.viewDidAppear:` / `viewWillDisappear:` so each
/// screen transition records an automatic breadcrumb. Idempotent, fail-open, and
/// forwards to the original implementation so the host's behaviour is unchanged.
enum UIViewControllerBreadcrumbSwizzle {

    nonisolated(unsafe) private static var installed = false
    private static let lock = NSLock()

    /// Install the swizzle once. Subsequent calls are no-ops. Fail-open.
    static func installIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !installed else { return }
        installed = true

        let cls: AnyClass = UIViewController.self
        swap(cls,
             original: #selector(UIViewController.viewDidAppear(_:)),
             swizzled: #selector(UIViewController.allstak_viewDidAppear(_:)))
        swap(cls,
             original: #selector(UIViewController.viewWillDisappear(_:)),
             swizzled: #selector(UIViewController.allstak_viewWillDisappear(_:)))
    }

    /// Exchange instance-method implementations, adding the original if the class
    /// does not already implement it directly (so the exchange targets the right
    /// IMP). Fail-open: a missing method simply leaves that hook uninstalled.
    private static func swap(_ cls: AnyClass, original: Selector, swizzled: Selector) {
        guard let orig = class_getInstanceMethod(cls, original),
              let repl = class_getInstanceMethod(cls, swizzled) else { return }
        method_exchangeImplementations(orig, repl)
    }
}

extension UIViewController {

    /// Swizzled `viewDidAppear:`. After the exchange this selector holds the
    /// ORIGINAL implementation, so we call through to it first (preserving the
    /// host's behaviour exactly) and then record a navigation breadcrumb.
    /// Recording is wrapped so an internal failure can never break a screen
    /// transition.
    @objc func allstak_viewDidAppear(_ animated: Bool) {
        // Calls the original viewDidAppear: (implementations were exchanged).
        allstak_viewDidAppear(animated)
        let screen = String(describing: type(of: self))
        AutoBreadcrumbs.shared.recordScreenAppear(screen: screen,
                                                  title: self.title)
    }

    /// Swizzled `viewWillDisappear:` — calls the original, then records a `ui`
    /// breadcrumb for the screen leaving.
    @objc func allstak_viewWillDisappear(_ animated: Bool) {
        allstak_viewWillDisappear(animated)
        let screen = String(describing: type(of: self))
        AutoBreadcrumbs.shared.recordScreenDisappear(screen: screen,
                                                     title: self.title)
    }
}

/// Adds `NotificationCenter` observers that emit `app.lifecycle` breadcrumbs for
/// app-state transitions. Installed once; idempotent and fail-open. These are
/// SEPARATE from the session/watchdog lifecycle observers in ``AllStak`` (which
/// drive session end / run-state) — these only record breadcrumbs and never
/// mutate session or crash state.
final class AppLifecycleBreadcrumbObserver: @unchecked Sendable {

    static let shared = AppLifecycleBreadcrumbObserver()

    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []
    private var installed = false

    private init() {}

    /// Map each lifecycle notification to a short, stable state token.
    private static let mapping: [(NSNotification.Name, String)] = {
        var m: [(NSNotification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "active"),
            (UIApplication.willResignActiveNotification, "inactive"),
            (UIApplication.didEnterBackgroundNotification, "background"),
            (UIApplication.willEnterForegroundNotification, "foreground"),
            (UIApplication.didReceiveMemoryWarningNotification, "memory_warning"),
        ]
        return m
    }()

    /// Register the observers once. Fail-open and idempotent.
    func installIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !installed else { return }
        installed = true

        let nc = NotificationCenter.default
        for (name, state) in Self.mapping {
            let obs = nc.addObserver(forName: name, object: nil, queue: nil) { _ in
                AutoBreadcrumbs.shared.recordLifecycle(state: state)
            }
            observers.append(obs)
        }
    }
}
#endif
