import AppKit
import SwiftUI

/// Dev harness, driven by environment variables so the panel can be checked without clicking:
///
/// - `TANKS_SNAPSHOT_DIR=<dir>` renders the dashboard in both appearances plus the menu-bar glyphs
///   to PNGs in that directory once the first readings are in (or after 25 s), then quits.
/// - `TANKS_FIXTURE=attention` replaces the live readings with a synthetic set that trips the
///   switch-now and credits rules, so the alert state can be inspected.
@MainActor
enum TanksSnapshot {
    /// True when this process was launched to render snapshots. Such an instance lives for a
    /// couple of seconds and must not register a status item: a burst of them once left Control
    /// Center refusing to place the real app's item under the same bundle id.
    static var isRequested: Bool {
        guard let dir = ProcessInfo.processInfo.environment["TANKS_SNAPSHOT_DIR"] else { return false }
        return !dir.isEmpty
    }

    static func armIfRequested(container: TanksContainer) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["TANKS_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let fixture = env["TANKS_FIXTURE"]
        Task {
            let deadline = Date().addingTimeInterval(25)
            while container.store.lastTick == nil, Date() < deadline {
                try? await Task.sleep(for: .seconds(1))
            }
            // Give the staggered sources a chance to all report once.
            try? await Task.sleep(for: .seconds(fixture == nil ? 12 : 0))
            if fixture == "attention" { container.store.applyFixture(Self.attentionFixture(container.config), activeIDs: Self.attentionActive) }
            try? await Task.sleep(for: .milliseconds(300))
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                for scheme in [ColorScheme.dark, .light] {
                    let view = TanksDashboardView().environment(container).environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    guard let cg = renderer.cgImage else { throw NSError(domain: "snapshot", code: 1) }
                    try write(cg, to: "\(dir)/panel-\(scheme == .dark ? "dark" : "light").png")
                }
                let store = container.store
                let glyph = TanksMenuBarRenderer.image(for: .init(fill: store.bindingProjection?.fill, attention: store.attention, stale: false))
                if let cg = glyph.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    try write(cg, to: "\(dir)/menubar.png")
                }
                AppLog.info(.lifecycle, "snapshots written to \(dir)")
            } catch {
                AppLog.error(.lifecycle, "snapshot failed: \(error)")
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private static func write(_ image: CGImage, to path: String) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "snapshot", code: 2) }
        try data.write(to: URL(fileURLWithPath: path))
    }

    static let attentionActive: Set<TankAccountID> = [
        TankAccountID(vendor: .claude, slot: .primary),
        TankAccountID(vendor: .codex, slot: .primary),
        TankAccountID(vendor: .cursor, slot: .primary),
    ]

    static func attentionFixture(_ config: TanksConfig) -> [AccountReading] {
        let now = Date()
        func acct(_ v: Vendor, _ s: AccountSlot) -> TankAccount { config.account(TankAccountID(vendor: v, slot: s)) }
        let in70m = now.addingTimeInterval(70 * 60)
        let in3d = now.addingTimeInterval(3 * 86400 + 5 * 3600)
        let in12d = now.addingTimeInterval(12 * 86400)
        // A reading from 15 minutes ago feeds the sample ring so the projection (hatch, red tick,
        // switch-now) has a rate to work from.
        let earlier = now.addingTimeInterval(-15 * 60)
        let claudeP0 = AccountReading(account: acct(.claude, .primary), plan: "Max 20x", tanks: [
            Tank(key: "5-hour", label: "5-hour", used: 80, limit: 100, format: .percent, resetsAt: in70m, periodSeconds: 5 * 3600),
            Tank(key: "week", label: "week", used: 60, limit: 100, format: .percent, resetsAt: in3d, periodSeconds: 7 * 86400),
            Tank(key: "opus", label: "opus", used: 79, limit: 100, format: .percent, resetsAt: in3d, periodSeconds: 7 * 86400),
        ], fetchedAt: earlier)
        let claudeP = AccountReading(account: acct(.claude, .primary), plan: "Max 20x", tanks: [
            Tank(key: "5-hour", label: "5-hour", used: 91, limit: 100, format: .percent, resetsAt: in70m, periodSeconds: 5 * 3600),
            Tank(key: "week", label: "week", used: 63, limit: 100, format: .percent, resetsAt: in3d, periodSeconds: 7 * 86400),
            Tank(key: "opus", label: "opus", used: 84, limit: 100, format: .percent, resetsAt: in3d, periodSeconds: 7 * 86400),
            Tank(key: "credits", label: "credits (paid)", used: 41.5, limit: 50, format: .dollars, isPaid: true),
        ], fetchedAt: now)
        let claudeS = AccountReading(account: acct(.claude, .secondary), plan: "Max 20x", tanks: [
            Tank(key: "5-hour", label: "5-hour", used: 8, limit: 100, format: .percent, resetsAt: now.addingTimeInterval(4 * 3600), periodSeconds: 5 * 3600),
            Tank(key: "week", label: "week", used: 22, limit: 100, format: .percent, resetsAt: in3d, periodSeconds: 7 * 86400),
            Tank(key: "opus", label: "opus", used: 12, limit: 100, format: .percent, resetsAt: in3d, periodSeconds: 7 * 86400),
            Tank(key: "credits", label: "credits (paid)", used: 3.2, limit: 50, format: .dollars, isPaid: true),
        ], fetchedAt: now)
        let codexP0 = AccountReading(account: acct(.codex, .primary), plan: "Business", tanks: [
            Tank(key: "week", label: "week", used: 36, limit: 100, format: .percent, resetsAt: in3d, periodSeconds: 7 * 86400),
            Tank(key: "month", label: "month", used: 11880, limit: 12000, format: .credits, resetsAt: in12d, periodSeconds: 30 * 86400, note: "spend control"),
        ], fetchedAt: earlier)
        let codexP = AccountReading(account: acct(.codex, .primary), plan: "Business", tanks: [
            Tank(key: "week", label: "week", used: 37, limit: 100, format: .percent, resetsAt: in3d, periodSeconds: 7 * 86400),
            Tank(key: "month", label: "month", used: 11893, limit: 12000, format: .credits, resetsAt: in12d, periodSeconds: 30 * 86400, note: "spend control"),
        ], fetchedAt: now)
        let codexS = AccountReading(account: acct(.codex, .secondary), plan: nil, tanks: [], fetchedAt: now,
                                    status: .signedOut(reason: "run: CODEX_HOME=~/.codex-tanks/secondary codex login"))
        let cycleStart = Calendar.current.date(byAdding: .month, value: -1, to: in12d)
        let team = Tank(key: "team", label: "team on-demand", used: 13250.5, limit: 28500, format: .dollars,
                        resetsAt: in12d, periodSeconds: 30 * 86400, startsAt: cycleStart, isPaid: true)
        let cursorP = AccountReading(account: acct(.cursor, .primary), plan: "tier 2000", tanks: [
            Tank(key: "auto", label: "cursor models", used: 13, limit: 100, format: .percent, resetsAt: in12d, periodSeconds: 30 * 86400, startsAt: cycleStart),
            Tank(key: "api", label: "other models", used: 51, limit: 100, format: .percent, resetsAt: in12d, periodSeconds: 30 * 86400, startsAt: cycleStart),
            Tank(key: "spend", label: "on-demand", used: 129.42, limit: 0, format: .dollars, resetsAt: in12d, periodSeconds: 30 * 86400, startsAt: cycleStart, isPaid: true, note: "no limit"),
        ], teamPaid: team, fetchedAt: now)
        let cursorS = AccountReading(account: acct(.cursor, .secondary), plan: "tier 2000", tanks: [
            Tank(key: "auto", label: "cursor models", used: 57, limit: 100, format: .percent, resetsAt: in12d, periodSeconds: 30 * 86400, startsAt: cycleStart),
            Tank(key: "api", label: "other models", used: 21, limit: 100, format: .percent, resetsAt: in12d, periodSeconds: 30 * 86400, startsAt: cycleStart),
            Tank(key: "spend", label: "on-demand", used: 713.58, limit: 0, format: .dollars, resetsAt: in12d, periodSeconds: 30 * 86400, startsAt: cycleStart, isPaid: true, note: "no limit"),
        ], teamPaid: team, fetchedAt: now)
        return [claudeP0, claudeP, claudeS, codexP0, codexP, codexS, cursorP, cursorS]
    }
}
