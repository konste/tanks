import Foundation

/// The transport seam telemetry is emitted through. Tanks sends nothing anywhere: the only sink is
/// the inert one below, kept so `TelemetryRecorder` and its tests stay unchanged.
protocol TelemetrySink: AnyObject {
    func capture(_ event: String, _ properties: [String: Any])
    func setOptionalAnalyticsEnabled(_ enabled: Bool)
    func flush()
}

/// Discards every event. No network, no SDK, no install id leaves the Mac.
final class NoopTelemetrySink: TelemetrySink {
    init(enabled _: Bool) {}
    func capture(_ event: String, _ properties: [String: Any]) {}
    func setOptionalAnalyticsEnabled(_ enabled: Bool) {}
    func flush() {}
}
