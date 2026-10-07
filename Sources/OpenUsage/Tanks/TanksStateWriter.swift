import Foundation

/// Writes the current state to disk after every tick so shell tools can read it:
/// `~/.chief-data/tanks-state.json` (all six accounts, kept at the ~/.chief-data root since Tanks
/// atomic-renames it and a symlink there wouldn't survive that) and, when configured, the schema
/// `allowance_probe.py` produces at `~/.chief-data/run/allowance-state.json` for the active Claude
/// account, so `allowance_watch.py` / `render_allowance_page.py` keep working unchanged.
struct TanksStateWriter: Sendable {
    var config: TanksConfig
    var files: TextFileAccessing = LocalTextFileAccessor()

    func write(_ states: [TankAccountID: TankStore.AccountState], advice: [Advice], now: Date = Date()) {
        writeTanksState(states, advice: advice, now: now)
        if let path = config.allowanceStatePath, let claude = states.values.first(where: { $0.account.id.vendor == .claude && $0.isActive }) {
            writeAllowanceState(claude, to: path.expandingTilde, now: now)
        }
    }

    private func writeTanksState(_ states: [TankAccountID: TankStore.AccountState], advice: [Advice], now: Date) {
        var accounts: [[String: Any]] = []
        for id in states.keys.sorted(by: { $0.description < $1.description }) {
            guard let state = states[id] else { continue }
            var tanks: [[String: Any]] = []
            for p in state.projections {
                var t: [String: Any] = [
                    "key": p.tank.key, "label": p.tank.label, "used": p.tank.used, "limit": p.tank.limit,
                    "format": String(describing: p.tank.format), "fill_percent": (p.fill * 100).rounded(),
                    "tier": String(describing: p.tier), "is_paid": p.tank.isPaid,
                ]
                if let r = p.tank.resetsAt { t["resets_at"] = OpenUsageISO8601.string(from: r) }
                if let r = p.ratePerHour { t["rate_per_hour"] = r }
                if let v = p.projectedAtReset { t["projected_at_reset"] = v }
                if let c = p.crossesAt { t["crosses_100_at"] = OpenUsageISO8601.string(from: c) }
                tanks.append(t)
            }
            var entry: [String: Any] = [
                "vendor": id.vendor.rawValue, "slot": id.slot.rawValue, "email": state.account.email,
                "active": state.isActive, "tanks": tanks,
            ]
            if let reading = state.reading {
                entry["fetched_at"] = OpenUsageISO8601.string(from: reading.fetchedAt)
                entry["status"] = Self.statusText(reading.status)
                if let plan = reading.plan { entry["plan"] = plan }
            }
            accounts.append(entry)
        }
        let doc: [String: Any] = [
            "written_at": OpenUsageISO8601.string(from: now),
            "accounts": accounts,
            "advice": advice.map { ["key": $0.key, "severity": String(describing: $0.severity), "vendor": $0.vendor.rawValue, "text": $0.text] },
        ]
        writeJSON(doc, to: config.tanksStatePath.expandingTilde)
    }

    /// The probe's schema (see `allowance_probe.py` `main()`): five_hour / weekly_all / weekly_scoped
    /// percent bars with severity, credits in minor units, a `state` colour and a `report` string.
    private func writeAllowanceState(_ claude: TankStore.AccountState, to path: String, now: Date) {
        guard let reading = claude.reading, reading.isLive else { return }
        func bar(_ key: String) -> [String: Any]? {
            guard let p = claude.projections.first(where: { $0.tank.key == key }) else { return nil }
            var rec: [String: Any] = ["percent": p.tank.used.rounded(), "severity": Self.severity(p.tank.used), "is_active": false]
            if let r = p.tank.resetsAt { rec["resets_at"] = OpenUsageISO8601.string(from: r) }
            return rec
        }
        var five = bar("5-hour") ?? [:]
        five["is_active"] = true
        let week = bar("week") ?? [:]
        var scoped: [String: Any] = [:]
        if let p = claude.projections.first(where: { $0.tank.periodSeconds == 7 * 86400 && $0.tank.key != "week" && $0.tank.format == .percent }) {
            scoped = bar(p.tank.key) ?? [:]
            scoped["model"] = p.tank.label
        }
        var credits: [String: Any] = ["enabled": false]
        if let c = claude.projections.first(where: { $0.tank.key == "credits" }) {
            credits = [
                "percent": (c.fill * 100).rounded(), "used_minor": Int(c.tank.used * 100), "limit_minor": Int(c.tank.limit * 100),
                "currency": "USD", "enabled": true, "limit_reached": c.fill >= 1,
            ]
        }
        let fivePct = (five["percent"] as? Double) ?? 0
        let weekPct = (week["percent"] as? Double) ?? 0
        let worst = max(fivePct, weekPct)
        let doc: [String: Any] = [
            "read_at": OpenUsageISO8601.string(from: now),
            "source": "tanks",
            "account": claude.account.email,
            "state": worst >= 92 ? "red" : (worst >= 80 ? "amber" : "green"),
            "report": "\(Int(fivePct))%/\(Int(weekPct))%",
            "five_hour": five, "weekly_all": week, "weekly_scoped": scoped, "credits": credits,
            "governing_bar": fivePct >= weekPct ? "5-hour" : "weekly",
            "stale": false,
        ]
        writeJSON(doc, to: path)
    }

    private static func severity(_ percent: Double) -> String {
        percent >= 92 ? "critical" : (percent >= 80 ? "warning" : "normal")
    }

    private static func statusText(_ status: AccountReading.Status) -> String {
        switch status {
        case .ok: "ok"
        case .stale(let r): "stale: \(r)"
        case .signedOut(let r): "signed out: \(r)"
        case .error(let r): "error: \(r)"
        }
    }

    private func writeJSON(_ doc: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return }
        do {
            try files.writeText(path, text)
        } catch {
            AppLog.warn(.config, "state write failed at \(path): \(error.localizedDescription)")
        }
    }
}
