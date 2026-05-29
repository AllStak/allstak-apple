import Foundation
import ObjectiveC

/// Automatic outbound HTTP instrumentation (sentry-cocoa-style).
///
/// A `URLProtocol` subclass — ``AllStakURLProtocol`` — observes the outbound
/// requests the host app makes through `URLSession`, records a redacted `http`
/// breadcrumb into the active ``Scope`` (method, redacted URL, status, duration,
/// response size), captures network failures as breadcrumbs too, and (when a
/// trace/release-health context exists) attaches W3C `traceparent` + `baggage`
/// headers to the outbound request for distributed tracing — keeping the wire
/// format byte-for-byte consistent with the sibling SDKs
/// (`allstak-js/src/modules/trace-propagation.ts`).
///
/// Registration covers two surfaces, mirroring sentry-cocoa:
///   1. `URLProtocol.registerClass` — catches `URLSession.shared` and any session
///      built from a default/ephemeral configuration without an explicit
///      `protocolClasses` list.
///   2. A swizzle of `URLSessionConfiguration.default` / `.ephemeral` so the
///      protocol is prepended to the `protocolClasses` of freshly-created
///      configurations (the registered class alone does NOT cover sessions made
///      from `URLSessionConfiguration.default`).
///
/// Hard rules honoured here:
///   * The SDK's OWN ingest host is skipped (no recursion / self-observation).
///   * URLs and headers are redacted via ``Sanitizer`` — no secrets in
///     breadcrumb URLs or in the recorded request metadata.
///   * Fail-open everywhere: any internal failure leaves the host's request
///     untouched and simply records nothing.
///   * No-ops cleanly on platforms / runtimes without working `URLProtocol`
///     support — the host's networking is never broken.
final class HTTPInstrumentation: @unchecked Sendable {

    /// Process-wide shared coordinator. `URLProtocol` is instantiated by
    /// Foundation with no access to our client, so the live configuration is read
    /// from this singleton (sentry-cocoa uses the same global-hub pattern).
    static let shared = HTTPInstrumentation()

    private let lock = NSLock()
    private var installed = false

    // Live configuration, read by `AllStakURLProtocol` instances.
    private var enabled = false
    private var ingestHost: String?         // scheme + host(+port), lower-cased
    private weak var scope: Scope?
    private var sanitizer = Sanitizer(sendDefaultPii: false)
    private var traceProvider: (@Sendable () -> TraceContext?)?

    private init() {}

    /// A minimal trace/release-health context used to build W3C propagation
    /// headers. `traceId` is required for propagation; `sessionId` rides in
    /// baggage so a backend can correlate the request with release-health.
    struct TraceContext: Sendable {
        let traceId: String
        let sessionId: String?
        let sampled: Bool
        init(traceId: String, sessionId: String? = nil, sampled: Bool = true) {
            self.traceId = traceId
            self.sessionId = sessionId
            self.sampled = sampled
        }
    }

    // MARK: Install / configure

    /// Install the instrumentation once. Subsequent calls only refresh the live
    /// configuration (so a re-`start()` re-points the scope / ingest host without
    /// double-registering the protocol). Fail-open: never throws into the caller.
    func install(scope: Scope,
                 ingestHost: String,
                 sanitizer: Sanitizer,
                 traceProvider: @escaping @Sendable () -> TraceContext?) {
        lock.lock()
        self.scope = scope
        self.ingestHost = Self.normalizedHostKey(ingestHost)
        self.sanitizer = sanitizer
        self.traceProvider = traceProvider
        self.enabled = true
        let alreadyInstalled = installed
        installed = true
        lock.unlock()

        guard !alreadyInstalled else { return }
        URLProtocol.registerClass(AllStakURLProtocol.self)
        AllStakURLProtocol.swizzleSessionConfiguration()
    }

    /// Disable instrumentation (opt-out). The protocol stays registered but every
    /// instance becomes a transparent pass-through, so this is safe to toggle.
    func disable() {
        lock.lock(); enabled = false; lock.unlock()
    }

    // MARK: Snapshot read by URLProtocol instances

    struct Config {
        let enabled: Bool
        let ingestHost: String?
        let scope: Scope?
        let sanitizer: Sanitizer
        let traceProvider: (@Sendable () -> TraceContext?)?
    }

    func currentConfig() -> Config {
        lock.lock(); defer { lock.unlock() }
        return Config(enabled: enabled, ingestHost: ingestHost, scope: scope,
                      sanitizer: sanitizer, traceProvider: traceProvider)
    }

    // MARK: Helpers

    /// Normalize a host string (`https://api.allstak.sa/`, `api.allstak.sa`, …) to
    /// a comparable `scheme://host[:port]` key, lower-cased. Returns `nil` when it
    /// cannot be parsed (fail-open — an unparsable ingest host just means we never
    /// match it, which only risks self-observation, never breaking the host app).
    static func normalizedHostKey(_ raw: String) -> String? {
        let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        if let comps = URLComponents(string: trimmed), let host = comps.host {
            var key = host.lowercased()
            if let port = comps.port { key += ":\(port)" }
            return key
        }
        // Bare host with no scheme.
        let bare = trimmed.lowercased()
        return bare.isEmpty ? nil : bare
    }

    /// `true` when `url` points at the SDK's own ingest host (so we must NOT
    /// observe or propagate into it — that would recurse the transport).
    func isOwnIngest(_ url: URL) -> Bool {
        guard let ingestHost else { return false }
        guard let host = url.host?.lowercased() else { return false }
        var key = host
        if let port = url.port { key += ":\(port)" }
        // Match either the host alone or host:port form.
        return key == ingestHost || host == ingestHost
    }
}

/// `URLProtocol` that intercepts outbound `URLSession` traffic for breadcrumb
/// recording + W3C trace-header propagation, then forwards the (possibly
/// header-augmented) request through an internal session and relays the response
/// transparently back to the client.
///
/// A per-request marker property prevents the protocol from re-handling the
/// request it itself forwards (infinite recursion guard), exactly like
/// sentry-cocoa's `SentryNetworkTracker` URLProtocol pattern.
final class AllStakURLProtocol: URLProtocol, @unchecked Sendable {

    /// Marker set on the request copy we forward so `canInit` declines it the
    /// second time around (avoids the protocol intercepting its own traffic).
    private static let handledKey = "com.allstak.httpInstrumentation.handled"

    /// Per-instance session that actually performs the forwarded request, with
    /// `self` as its delegate so the response/data/completion are relayed back to
    /// `self.client` (the protocol contract). Built WITHOUT our own class in
    /// `protocolClasses` so the forwarded request is never re-intercepted, and torn
    /// down in `stopLoading`. Created lazily in `startLoading`.
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var startTime: Date?
    private var receivedBytes = 0

    /// Test seam: extra `URLProtocol` classes to add to the forwarding session so
    /// a unit test can answer the forwarded request offline (no socket). `nil` in
    /// production — the forwarding session then carries only Foundation's built-in
    /// protocols. Never set this outside tests.
    nonisolated(unsafe) static var forwardingProtocolClassesOverride: [AnyClass]?

    /// Build the forwarding session, scrubbing our protocol out of its
    /// `protocolClasses` (the swizzle would otherwise re-add it) so the forwarded
    /// request is not intercepted again.
    private func makeForwardingSession() -> URLSession {
        let config = URLSessionConfiguration.default
        var classes = (config.protocolClasses ?? []).filter { $0 != AllStakURLProtocol.self }
        // In tests, prepend an offline backend so the forwarded request never
        // touches the network. Production leaves this nil.
        if let override = Self.forwardingProtocolClassesOverride {
            classes = override + classes
        }
        config.protocolClasses = classes
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: URLProtocol contract

    override class func canInit(with request: URLRequest) -> Bool {
        // Decline if we already handled (forwarded) this request.
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }
        guard let url = request.url else { return false }
        // Only http(s); skip data:/file:/ws: and the SDK's own ingest host.
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        let coordinator = HTTPInstrumentation.shared
        let config = coordinator.currentConfig()
        guard config.enabled else { return false }
        if coordinator.isOwnIngest(url) { return false }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override class func requestIsCacheEquivalent(_ a: URLRequest, to b: URLRequest) -> Bool {
        super.requestIsCacheEquivalent(a, to: b)
    }

    override func startLoading() {
        let coordinator = HTTPInstrumentation.shared
        let config = coordinator.currentConfig()

        // Build the forwarded request: mark it handled (so we don't re-intercept)
        // and inject W3C trace headers when a trace context exists. Any failure
        // here falls back to forwarding the original request unchanged.
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            // Cannot copy → forward the original verbatim, no instrumentation.
            forwardWithoutInstrumentation()
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)

        if let url = request.url, !coordinator.isOwnIngest(url),
           let trace = config.traceProvider?() {
            Self.injectTraceHeaders(into: mutable, trace: trace)
        }

        startTime = Date()
        let session = makeForwardingSession()
        self.session = session
        let task = session.dataTask(with: mutable as URLRequest)
        dataTask = task
        task.resume()
    }

    override func stopLoading() {
        dataTask?.cancel()
        dataTask = nil
        // Break the session→delegate(self) retain cycle so the protocol instance
        // and its session are released.
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: Forwarding fallback (no instrumentation possible)

    private func forwardWithoutInstrumentation() {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
        startTime = Date()
        let session = makeForwardingSession()
        self.session = session
        let task = session.dataTask(with: mutable as URLRequest)
        dataTask = task
        task.resume()
    }

    // MARK: Trace header injection (W3C parity with allstak-js)

    /// Inject `traceparent` + `baggage` + `x-allstak-*` headers, set-if-missing so
    /// host-supplied headers always win. Mirrors
    /// `allstak-js/src/modules/trace-propagation.ts`.
    static func injectTraceHeaders(into request: NSMutableURLRequest,
                                   trace: HTTPInstrumentation.TraceContext) {
        let values = TracePropagation.values(traceId: trace.traceId,
                                             sessionId: trace.sessionId,
                                             sampled: trace.sampled)
        setIfMissing(request, "traceparent", values.traceparent)
        setIfMissing(request, "x-allstak-trace-id", values.traceId)
        // Merge into an existing baggage rather than clobbering vendor members.
        mergeBaggage(request, "baggage", values.baggage)
        setIfMissing(request, "allstak-baggage", values.baggage)
    }

    private static func setIfMissing(_ request: NSMutableURLRequest, _ name: String, _ value: String) {
        if request.value(forHTTPHeaderField: name) == nil {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private static func mergeBaggage(_ request: NSMutableURLRequest, _ name: String, _ baggage: String) {
        if let existing = request.value(forHTTPHeaderField: name), !existing.isEmpty {
            request.setValue(TracePropagation.mergeBaggage(existing: existing, baggage: baggage),
                             forHTTPHeaderField: name)
        } else {
            request.setValue(baggage, forHTTPHeaderField: name)
        }
    }

    // MARK: Swizzle URLSessionConfiguration.default / .ephemeral

    nonisolated(unsafe) private static var swizzled = false
    private static let swizzleLock = NSLock()

    /// Prepend ``AllStakURLProtocol`` to the `protocolClasses` of freshly-created
    /// default/ephemeral configurations, so sessions built from them are
    /// instrumented even though `URLProtocol.registerClass` does not cover them.
    /// Idempotent and fail-open.
    static func swizzleSessionConfiguration() {
        swizzleLock.lock(); defer { swizzleLock.unlock() }
        guard !swizzled else { return }
        swizzled = true
        let cls: AnyClass = URLSessionConfiguration.self
        // Both `default` and `ephemeral` are class properties returning a fresh
        // configuration each call; swap their getters for ones that prepend us.
        swap(cls, original: #selector(getter: URLSessionConfiguration.default),
             swizzled: #selector(URLSessionConfiguration.allstak_defaultConfiguration))
        swap(cls, original: #selector(getter: URLSessionConfiguration.ephemeral),
             swizzled: #selector(URLSessionConfiguration.allstak_ephemeralConfiguration))
    }

    private static func swap(_ cls: AnyClass, original: Selector, swizzled: Selector) {
        guard let meta = object_getClass(cls),
              let orig = class_getClassMethod(cls, original),
              let repl = class_getClassMethod(cls, swizzled) else { return }
        // Class methods live on the metaclass.
        if class_addMethod(meta, original,
                           method_getImplementation(repl),
                           method_getTypeEncoding(repl)) {
            class_replaceMethod(meta, swizzled,
                                method_getImplementation(orig),
                                method_getTypeEncoding(orig))
        } else {
            method_exchangeImplementations(orig, repl)
        }
    }
}

// MARK: - URLSession data-task delegate (relays response back to the client)

extension AllStakURLProtocol: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        client?.urlProtocol(self, didReceive: response,
                            cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedBytes += data.count
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Record the breadcrumb (success or failure) before relaying completion.
        recordBreadcrumb(task: task, error: error)
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
        dataTask = nil
        // Release the forwarding session (delegate retain cycle) now we're done.
        session.finishTasksAndInvalidate()
        self.session = nil
    }

    /// Build + record a redacted `http` breadcrumb into the active scope.
    /// Fully fail-open — a recording failure never affects the relayed response.
    private func recordBreadcrumb(task: URLSessionTask, error: Error?) {
        let config = HTTPInstrumentation.shared.currentConfig()
        guard config.enabled, let scope = config.scope, let url = request.url else { return }

        let method = request.httpMethod ?? "GET"
        let durationMs = startTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        // Redact the URL: drop the query entirely (it can carry tokens) and scrub
        // any PII left in the path component (e.g. an email in a REST path).
        let redactedUrl = config.sanitizer.scrubString(Self.redactedURLString(url))

        var data: [String: Any] = [
            "method": method,
            "url": redactedUrl,
            "duration_ms": durationMs,
        ]
        let level: String
        let message: String
        if let error {
            level = "error"
            data["error"] = config.sanitizer.scrubString(String(describing: error))
            message = "\(method) \(redactedUrl) -> failed"
        } else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            data["status_code"] = status
            // Prefer the server-reported size; fall back to bytes we relayed.
            let size = task.response?.expectedContentLength ?? -1
            data["response_size"] = size >= 0 ? Int(size) : receivedBytes
            level = status >= 400 ? "error" : "info"
            message = "\(method) \(redactedUrl) -> \(status)"
        }

        scope.addBreadcrumb(type: "http", message: message,
                            category: "http", level: level, data: data)
    }

    /// `scheme://host[:port]/path` with the query + fragment removed. Userinfo (a
    /// `user:pass@` prefix, which can carry credentials) is also stripped. The
    /// path is left for the sanitizer's value-pattern scrubbing.
    static func redactedURLString(_ url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            // Fall back to the absolute string minus anything after `?`.
            return String(url.absoluteString.split(separator: "?", maxSplits: 1).first ?? "")
        }
        comps.query = nil
        comps.fragment = nil
        comps.user = nil
        comps.password = nil
        return comps.string ?? url.absoluteString
    }
}

// MARK: - URLSessionConfiguration swizzled getters

extension URLSessionConfiguration {

    /// Swizzled replacement for `URLSessionConfiguration.default`. After the
    /// `method_exchangeImplementations`, calling this selector invokes the
    /// ORIGINAL getter; we then prepend our protocol. Fail-open.
    @objc class func allstak_defaultConfiguration() -> URLSessionConfiguration {
        // After swizzling, this selector is the original implementation.
        let config = allstak_defaultConfiguration()
        config.allstak_prependProtocol()
        return config
    }

    @objc class func allstak_ephemeralConfiguration() -> URLSessionConfiguration {
        let config = allstak_ephemeralConfiguration()
        config.allstak_prependProtocol()
        return config
    }

    /// Prepend ``AllStakURLProtocol`` to `protocolClasses` if not already present.
    fileprivate func allstak_prependProtocol() {
        var classes = protocolClasses ?? []
        guard !classes.contains(where: { $0 == AllStakURLProtocol.self }) else { return }
        classes.insert(AllStakURLProtocol.self, at: 0)
        protocolClasses = classes
    }
}
