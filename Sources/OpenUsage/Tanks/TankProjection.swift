import Foundation

/// A private ring of (time, used) samples for one tank. Never displayed: it exists only to give
/// the projection a slope. Samples older than the horizon are dropped; a drop in `used` (a reset,
/// or a switch to a different window) clears the ring so the segment spanning the reset never
/// enters the fit.
struct SampleRing: Sendable, Hashable {
    struct Sample: Sendable, Hashable {
        var at: Date
        var used: Double
    }

    private(set) var samples: [Sample] = []
    var horizon: TimeInterval

    init(horizon: TimeInterval) {
        self.horizon = horizon
    }

    /// Horizon per window length: an hour of samples for anything up to a 5-hour window, twelve
    /// hours for weekly and monthly ones — long enough to smooth a burst, short enough to track a
    /// changed pace within the same window.
    static func horizon(forPeriod period: TimeInterval?) -> TimeInterval {
        guard let period, period > 6 * 3600 else { return 3600 }
        return 12 * 3600
    }

    mutating func append(used: Double, at: Date) {
        if let last = samples.last, used < last.used - 0.5 {
            samples.removeAll()
        }
        samples.append(Sample(at: at, used: used))
        let cutoff = at.addingTimeInterval(-horizon)
        samples.removeAll { $0.at < cutoff }
    }

    /// Least-squares slope in units per second, floored at zero, or `nil` when the ring spans less
    /// than three minutes (two polls one minute apart say nothing about pace yet).
    var slopePerSecond: Double? {
        guard let first = samples.first, let last = samples.last,
              last.at.timeIntervalSince(first.at) >= 180
        else { return nil }
        let n = Double(samples.count)
        let t0 = first.at
        let xs = samples.map { $0.at.timeIntervalSince(t0) }
        let ys = samples.map(\.used)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) {
            num += (x - meanX) * (y - meanY)
            den += (x - meanX) * (x - meanX)
        }
        guard den > 0 else { return nil }
        return max(0, num / den)
    }
}

/// Colour tiers, in the probe's terms: amber at 80% fill (or projected to land in the last 10%),
/// red at 92% (or projected to cross 100% before the reset). `idle` is the non-active account's
/// resting colour; `signedOut` the "no data" blue.
enum TankTier: Sendable, Hashable {
    case green, amber, red, idle, signedOut
}

/// Everything the bar needs, computed from a tank plus its ring. Pure, so it is testable without
/// a clock: pass `now`.
struct TankProjection: Sendable, Hashable {
    var tank: Tank
    /// Units per hour, `nil` when the ring cannot give a slope yet.
    var ratePerHour: Double?
    /// Expected `used` at the reset, `nil` without a slope or a reset.
    var projectedAtReset: Double?
    /// When the tank hits its limit, if before the reset.
    var crossesAt: Date?
    var tier: TankTier

    var fill: Double { min(1, tank.fill) }
    var projectedFill: Double? {
        guard let projectedAtReset, tank.limit > 0 else { return nil }
        return min(1, projectedAtReset / tank.limit)
    }

    static func make(tank: Tank, ring: SampleRing?, isActiveAccount: Bool, now: Date = Date()) -> TankProjection {
        let slope = ring?.slopePerSecond
        var projected: Double?
        var crosses: Date?
        if let slope, let resetsAt = tank.resetsAt, resetsAt > now {
            let toReset = resetsAt.timeIntervalSince(now)
            projected = tank.used + slope * toReset
            if slope > 0, tank.used < tank.limit {
                let secondsToFull = (tank.limit - tank.used) / slope
                if secondsToFull < toReset {
                    crosses = now.addingTimeInterval(secondsToFull)
                }
            }
        }
        let fill = tank.fill
        let projectedFill = projected.map { $0 / max(tank.limit, 0.0001) }
        let tier: TankTier
        if crosses != nil || fill >= 0.92 {
            tier = .red
        } else if fill >= 0.80 || (projectedFill ?? 0) >= 0.90 {
            tier = .amber
        } else if isActiveAccount {
            tier = .green
        } else {
            tier = .idle
        }
        return TankProjection(
            tank: tank,
            ratePerHour: slope.map { $0 * 3600 },
            projectedAtReset: projected,
            crossesAt: crosses,
            tier: tier
        )
    }
}
