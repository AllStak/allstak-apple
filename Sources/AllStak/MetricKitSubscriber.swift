import Foundation

// MARK: - MetricKit subscriber (post-hoc diagnostics)
//
// MetricKit (iOS 14+ / macOS 12+) delivers aggregated crash + hang diagnostics
// the day AFTER they occur, sampled by the OS. They complement — they do not
// replace — our in-process hang/crash capture: they catch terminations the
// in-process watchdog cannot observe (the OS already killed us) and carry a
// system-symbolicated call tree. We subscribe behind a flag and feed each
// diagnostic into the same capture/transport pipeline, tagged with the relevant
// mechanism. Entirely guarded by `canImport(MetricKit)` and fail-open: if the
// framework is missing or anything throws, the subscriber is simply inert.

/// Mechanisms stamped on events produced from MetricKit diagnostics.
enum MetricKitMechanism {
    static let crash = "metrickit_crash"
    static let hang = "metrickit_app_hang"
}

#if canImport(MetricKit) && !os(tvOS)
import MetricKit

/// Subscribes to `MXMetricManager` and forwards `MXCrashDiagnostic` /
/// `MXHangDiagnostic` payloads to an injected, fire-and-forget sink. The sink is
/// wired to the capture path in production. Availability-gated to iOS 14+ /
/// macOS 12+; a no-op on older OSes.
@available(iOS 14.0, macOS 12.0, *)
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    /// `(mechanism, title, callStackJSON)`. Fire-and-forget; must not throw.
    typealias DiagnosticSink = @Sendable (_ mechanism: String, _ title: String, _ callStackJSON: String?) -> Void

    private let sink: DiagnosticSink
    private var subscribed = false

    init(sink: @escaping DiagnosticSink) {
        self.sink = sink
        super.init()
    }

    /// Register with the shared metric manager. Fail-open; never throws into the
    /// caller. A no-op if already subscribed.
    func subscribe() {
        guard !subscribed else { return }
        subscribed = true
        MXMetricManager.shared.add(self)
    }

    /// Deregister. Idempotent.
    func unsubscribe() {
        guard subscribed else { return }
        subscribed = false
        MXMetricManager.shared.remove(self)
    }

    // MARK: MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        // We only consume diagnostics; metric payloads are ignored.
    }

    @available(iOS 14.0, macOS 12.0, *)
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let reason = crash.terminationReason ?? "MetricKit crash diagnostic"
                sink(MetricKitMechanism.crash, reason, Self.callStackJSON(crash.callStackTree))
            }
            for hang in payload.hangDiagnostics ?? [] {
                let title = "App Hang (\(hang.hangDuration)) — MetricKit"
                sink(MetricKitMechanism.hang, title, Self.callStackJSON(hang.callStackTree))
            }
        }
    }

    /// Serialize a `MXCallStackTree` to a UTF-8 JSON string, best-effort.
    private static func callStackJSON(_ tree: MXCallStackTree) -> String? {
        String(data: tree.jsonRepresentation(), encoding: .utf8)
    }
}
#endif
