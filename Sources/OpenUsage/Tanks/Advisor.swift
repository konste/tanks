import Foundation

/// One line on the advice strip. `key` is stable across polls so a dismissal (or a posted
/// notification) sticks for the window the advice concerns.
struct Advice: Sendable, Hashable, Identifiable {
    enum Severity: Sendable, Hashable, Comparable {
        case info, warn, alert
    }

    enum Action: Sendable, Hashable {
        case switchTo(TankAccountID)
        case remindAt(Date, TankAccountID)
    }

    var key: String
    var severity: Severity
    var vendor: Vendor
    var text: String
    var detail: String?
    var action: Action?
    /// Whether this advice also posts a macOS notification (rules 1 and 4 only).
    var notifies: Bool = false

    var id: String { key }
}

/// The advisor's view of one account: its projections plus whether it is the signed-in one.
struct AccountAssessment: Sendable {
    var account: TankAccount
    var isActive: Bool
    var reading: AccountReading?
    var projections: [TankProjection]

    func projection(_ key: String) -> TankProjection? {
        projections.first { $0.tank.key == key }
    }
}

/// Rule-based advisor, per docs/tanks/design.md § Advisor. Every rule names its two numbers.
enum Advisor {
    static let switchNowFill = 0.90
    static let switchNowMinutes: TimeInterval = 20 * 60
    static let otherHeadroom = 0.30
    static let spareCapacity = 0.30
    static let creditsGuard = 0.80

    static func advise(_ assessments: [AccountAssessment], now: Date = Date()) -> [Advice] {
        var out: [Advice] = []
        for vendor in Vendor.allCases {
            let pair = assessments.filter { $0.account.id.vendor == vendor }
            guard let active = pair.first(where: \.isActive) else { continue }
            let other = pair.first { !$0.isActive }
            out += windowRules(active: active, other: other, now: now)
            out += creditsGuard(pair)
        }
        out += spareCapacity(assessments)
        return out.sorted { ($0.severity, $0.vendor.rawValue) > ($1.severity, $1.vendor.rawValue) }
    }

    /// Rules 1 and 2: the active account's window is projected to cross 100% before its reset and
    /// the other account's same window has headroom.
    private static func windowRules(active: AccountAssessment, other: AccountAssessment?, now: Date) -> [Advice] {
        var out: [Advice] = []
        for projection in active.projections where !projection.tank.isPaid {
            let tank = projection.tank
            // A window already at the switch-now level counts even before a rate exists (the first
            // three minutes after launch, or a burst that landed between polls).
            guard let crossesAt = projection.crossesAt
                ?? (projection.fill >= switchNowFill ? (tank.resetsAt ?? now) : nil) else { continue }
            // A second included pool on the same account comes before any account switch: on
            // 2026-09-27 the strip said "switch to admin-konstantin" while konstantin's other
            // models sat at 100% and its cursor models at 13% (his correction).
            if let fallback = samePoolFallback(active.account.id.vendor, tank.key),
               let spare = active.projection(fallback.key), spare.fill < switchNowFill {
                out.append(poolAdvice(active: active, projection: projection, crossesAt: crossesAt,
                                      fallback: fallback, spare: spare, now: now))
                continue
            }
            let otherFill = other?.projection(tank.key)?.fill
            // A switch only helps when every window on the other account is usable: on
            // 2026-09-26 the strip said "switch to admin-konstantin, 5-hour at 0%" while that
            // account's week sat at 100% (his correction). The matching window needs 30%
            // headroom and no other window there may be at the switch-now level.
            let blocked = other.flatMap { blockingWindow(on: $0, except: tank.key) }
            let otherHasRoom = (otherFill.map { 1 - $0 >= otherHeadroom } ?? false) && blocked == nil
            let minutesToFull = crossesAt.timeIntervalSince(now)
            let urgent = projection.fill >= switchNowFill || minutesToFull <= switchNowMinutes
            let otherText = other.map { o in
                guard let otherFill else { return "\(o.account.label) has no reading" }
                let same = "\(o.account.label) \(tank.label) at \(Fmt.percent(otherFill))"
                guard let blocked, 1 - otherFill >= otherHeadroom else { return same }
                return same + " but its \(blocked.tank.label) at \(Fmt.percent(blocked.fill))"
            } ?? "no second account"
            let when = projection.crossesAt == nil
                ? "is at \(Fmt.percent(projection.fill))"
                : "hits 100% at \(Fmt.clock(crossesAt))"
            let base = "\(vendor(active)) / \(active.account.label) \(tank.label) \(when) — \(otherText)."
            let detail = burnDetail(projection)
            if urgent && otherHasRoom, let other {
                out.append(Advice(
                    key: "switch-now:\(active.account.id):\(tank.key):\(Fmt.windowStamp(tank))",
                    severity: .alert, vendor: active.account.id.vendor,
                    text: "Switch now — " + base, detail: detail,
                    action: .switchTo(other.account.id), notifies: true
                ))
            } else if otherHasRoom, let other, minutesToFull > 3600 {
                let switchAt = crossesAt.addingTimeInterval(-switchNowMinutes)
                out.append(Advice(
                    key: "switch-later:\(active.account.id):\(tank.key):\(Fmt.windowStamp(tank))",
                    severity: .warn, vendor: active.account.id.vendor,
                    text: base + " Switch at \(Fmt.clock(switchAt)).", detail: detail,
                    action: .remindAt(switchAt, other.account.id)
                ))
            } else {
                out.append(Advice(
                    key: "runs-dry:\(active.account.id):\(tank.key):\(Fmt.windowStamp(tank))",
                    severity: urgent ? .alert : .warn, vendor: active.account.id.vendor,
                    text: base + (other == nil ? "" : " No headroom on the other account."), detail: detail,
                    notifies: urgent
                ))
            }
        }
        return out
    }

    /// A second included pool on the same account that takes the work once `key` is spent.
    /// Cursor's dashboard (2026-09-27): Cursor Models "Additional usage beyond limits consumes
    /// Other Models quota or on-demand spend"; Other Models "consumes on-demand spend". So a spent
    /// cursor-models pool spills into other models on its own, and a spent other-models pool bills
    /// on-demand unless the work moves to a Cursor model by hand.
    struct SamePoolFallback: Sendable, Equatable {
        var key: String
        /// The vendor moves the work itself; nothing for him to do.
        var automatic: Bool
        /// What to pick by hand when `automatic` is false.
        var models: String
    }

    static func samePoolFallback(_ vendor: Vendor, _ key: String) -> SamePoolFallback? {
        guard vendor == .cursor else { return nil }
        switch key {
        case "api": return SamePoolFallback(key: "auto", automatic: false, models: "Auto, Composer or Grok")
        case "auto": return SamePoolFallback(key: "api", automatic: true, models: "")
        default: return nil
        }
    }

    /// The advice for a window whose same-account fallback still has room: move models (or, for an
    /// automatic spill, just a note). It never offers the account switch; that returns once the
    /// fallback pool itself reaches the switch-now level.
    private static func poolAdvice(active: AccountAssessment, projection: TankProjection, crossesAt: Date,
                                   fallback: SamePoolFallback, spare: TankProjection, now: Date) -> Advice {
        let tank = projection.tank
        let urgent = projection.fill >= switchNowFill || crossesAt.timeIntervalSince(now) <= switchNowMinutes
        let when = projection.crossesAt == nil
            ? "is at \(Fmt.percent(projection.fill))"
            : "hits 100% at \(Fmt.clock(crossesAt))"
        let head = "\(vendor(active)) / \(active.account.label) \(tank.label) \(when) — \(spare.tank.label) at \(Fmt.percent(spare.fill))."
        let stamp = Fmt.windowStamp(tank)
        if fallback.automatic {
            return Advice(
                key: "spills:\(active.account.id):\(tank.key):\(stamp)",
                severity: .info, vendor: active.account.id.vendor,
                text: head + " Past 100% the work draws on \(spare.tank.label) by itself.",
                detail: burnDetail(projection)
            )
        }
        let tail = projection.fill >= 1
            ? " Use \(fallback.models): they stay included, \(tank.label) now bill on-demand."
            : " Move to \(fallback.models) before then: past 100% \(tank.label) bill on-demand."
        return Advice(
            key: "use-pool:\(active.account.id):\(tank.key):\(stamp)",
            severity: urgent ? .warn : .info, vendor: active.account.id.vendor,
            text: (urgent ? "Switch model — " : "") + head + tail,
            detail: burnDetail(projection), notifies: urgent
        )
    }

    /// `burn 12%/h`, or nothing when the rate rounds to zero (a full pool has nothing left to burn;
    /// "burn 0%/h" under a 100% bar read as a contradiction, 2026-09-27).
    private static func burnDetail(_ projection: TankProjection) -> String? {
        guard let rate = projection.ratePerHour else { return nil }
        let text = Fmt.rate(rate, projection.tank)
        guard !["0", "0%", "$0.00"].contains(text) else { return nil }
        return "burn \(text)/h"
    }

    /// The fullest other-account window at or past the switch-now level, other than the one being
    /// compared; a switch lands on it straight away, so it makes the other account unusable.
    static func blockingWindow(on other: AccountAssessment, except key: String) -> TankProjection? {
        other.projections
            .filter { !$0.tank.isPaid && $0.tank.key != key && $0.fill >= switchNowFill }
            .max { $0.fill < $1.fill }
    }

    /// Rule 4: a paid overflow at 80% of its monthly cap is red regardless of window state.
    private static func creditsGuard(_ pair: [AccountAssessment]) -> [Advice] {
        pair.flatMap { assessment in
            assessment.projections.filter { ($0.tank.isPaid || $0.tank.format == .dollars) && $0.tank.limit > 0 && $0.fill >= creditsGuard }.map { p in
                Advice(
                    key: "credits:\(assessment.account.id):\(p.tank.key):\(Fmt.windowStamp(p.tank))",
                    severity: .alert, vendor: assessment.account.id.vendor,
                    text: "\(vendor(assessment)) / \(assessment.account.label) \(p.tank.label) at \(Fmt.amount(p.tank.used, p.tank)) of \(Fmt.amount(p.tank.limit, p.tank)) — past the cap every turn bills.",
                    notifies: true
                )
            }
        }
    }

    /// Rule 3: a window projected to reach its reset with more than 30% unused, named as a place
    /// to send work. Only the longest window per account is worth naming (a 5-hour window refills
    /// on its own).
    private static func spareCapacity(_ assessments: [AccountAssessment]) -> [Advice] {
        assessments.compactMap { assessment in
            let candidates = assessment.projections.filter { !$0.tank.isPaid && $0.tank.limit > 0 && $0.tank.periodSeconds ?? 0 >= 6 * 3600 }
            guard let longest = candidates.max(by: { ($0.tank.periodSeconds ?? 0) < ($1.tank.periodSeconds ?? 0) }),
                  let projectedFill = longest.projectedFill ?? (longest.ratePerHour == nil ? Optional(longest.fill) : nil),
                  1 - projectedFill > spareCapacity,
                  let remaining = longest.tank.remainingSeconds
            else { return nil }
            let tank = longest.tank
            let left = Fmt.duration(remaining)
            return Advice(
                key: "spare:\(assessment.account.id):\(tank.key):\(Fmt.windowStamp(tank))",
                severity: .info, vendor: assessment.account.id.vendor,
                text: "\(vendor(assessment)) / \(assessment.account.label) \(tank.label) is at \(Fmt.amount(tank.used, tank)) of \(Fmt.amount(tank.limit, tank)) with \(left) left — spare capacity."
            )
        }
    }

    private static func vendor(_ a: AccountAssessment) -> String {
        a.account.id.vendor.rawValue.capitalized
    }
}

/// Shared number/time formatting for the panel and the advisor. Local time, 24-hour.
enum Fmt {
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func amount(_ value: Double, _ tank: Tank) -> String {
        switch tank.format {
        case .percent: "\(Int(value.rounded()))%"
        case .dollars: dollars(value)
        case .credits: "\(Int(value.rounded()))"
        }
    }

    static func dollars(_ value: Double) -> String {
        if value >= 1000 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 0
            return "$" + (f.string(from: NSNumber(value: value)) ?? "\(Int(value))")
        }
        return value < 10 ? String(format: "$%.2f", value) : "$\(Int(value.rounded()))"
    }

    static func rate(_ perHour: Double, _ tank: Tank) -> String {
        switch tank.format {
        case .percent: "\(Int(perHour.rounded()))%"
        case .dollars: dollars(perHour)
        case .credits: "\(Int(perHour.rounded()))"
        }
    }

    /// `14:10` today, `Sat 07:00` within the week, `Oct 12` beyond.
    static func clock(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if cal.isDate(date, inSameDayAs: now) {
            f.dateFormat = "HH:mm"
        } else if date.timeIntervalSince(now) < 6 * 86400 {
            f.dateFormat = "EEE HH:mm"
        } else {
            f.dateFormat = "MMM d"
        }
        return f.string(from: date)
    }

    /// The current window as a range, sized for the row under a bar: `16:00 – 21:00` inside one
    /// day, `Sat 22:00 – Sun 03:00` under two days, `Sep 19 – Sep 26 20:00` when both ends share
    /// a time of day (every fixed-length window does), else `Sep 1 11:24 – Oct 1 11:24`.
    /// `withTime: false` drops the clock from multi-day ranges (`Sep 1 – Oct 1`) for rows where
    /// the projection needs the room; the tooltip still carries the full endpoints.
    static func window(_ start: Date, _ end: Date, withTime: Bool = true) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if cal.isDate(start, inSameDayAs: end) {
            f.dateFormat = "HH:mm"
            return "\(f.string(from: start)) – \(f.string(from: end))"
        }
        if end.timeIntervalSince(start) < 2 * 86400 {
            f.dateFormat = "EEE HH:mm"
            return "\(f.string(from: start)) – \(f.string(from: end))"
        }
        let startTime = cal.dateComponents([.hour, .minute], from: start)
        let endTime = cal.dateComponents([.hour, .minute], from: end)
        if startTime == endTime || !withTime {
            f.dateFormat = "MMM d"
            let t = DateFormatter()
            t.locale = f.locale
            t.dateFormat = "HH:mm"
            // Same month: `Sep 23 – 30 01:47`; the row under a bar has no room for the month twice.
            let endText = cal.isDate(start, equalTo: end, toGranularity: .month)
                ? "\(cal.component(.day, from: end))" : f.string(from: end)
            let time = withTime && startTime == endTime ? " \(t.string(from: end))" : ""
            return "\(f.string(from: start)) – \(endText)\(time)"
        }
        f.dateFormat = "MMM d HH:mm"
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    /// `Tue Sep 1, 11:24` — the tooltip form of a window endpoint.
    static func fullDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d, HH:mm"
        return f.string(from: date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds >= 2 * 86400 { return "\(Int(seconds / 86400)) days" }
        if seconds >= 3600 { return "\(Int(seconds / 3600)) h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)) min" }
        return "\(Int(seconds / 60)) min"
    }

    /// Identifies the window instance: advice keyed on it clears itself at the reset. Rounded to
    /// the minute: Codex reports its month reset a second later on some polls (…800 then …801 on
    /// 2026-09-26), and every drift minted a new key and a repeat notification.
    static func windowStamp(_ tank: Tank) -> String {
        tank.resetsAt.map { String(Int(($0.timeIntervalSince1970 / 60).rounded()) * 60) } ?? "-"
    }
}
