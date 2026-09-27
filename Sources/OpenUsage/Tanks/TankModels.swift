import Foundation

/// The three subscriptions Tanks watches. Order is the dashboard's column order.
enum Vendor: String, CaseIterable, Sendable, Codable, Hashable {
    case claude, codex, cursor

    var title: String {
        switch self {
        case .claude: "CLAUDE"
        case .codex: "CODEX"
        case .cursor: "CURSOR"
        }
    }
}

/// The two accounts per vendor. `primary` is the one normally signed in; `secondary` is the
/// overflow account. Display names come from `TanksConfig`.
enum AccountSlot: String, CaseIterable, Sendable, Codable, Hashable {
    case primary, secondary
}

struct TankAccountID: Hashable, Sendable, Codable, CustomStringConvertible {
    var vendor: Vendor
    var slot: AccountSlot

    var description: String { "\(vendor.rawValue)/\(slot.rawValue)" }
}

/// One account on one vendor, as configured. `label` is what the panel prints (the email's local
/// part), `email` is what the vendor APIs key on.
struct TankAccount: Hashable, Sendable {
    var id: TankAccountID
    var email: String

    var label: String {
        email.split(separator: "@").first.map(String.init) ?? email
    }
}

/// How a tank's numbers print. Percent tanks have `limit == 100`; dollar and credit tanks carry the
/// real cap in `limit`.
enum TankFormat: Sendable, Hashable, Codable {
    case percent
    case dollars
    case credits
}

/// One allowance window: a bar on the panel. `used`/`limit` are in `format`'s unit. `resetsAt` and
/// `periodSeconds` drive the projection; a tank without a reset (a prepaid credit balance) shows
/// no projection.
struct Tank: Sendable, Hashable, Codable {
    /// Stable key inside its account: `5-hour`, `week`, `month`, or a model name for a sub-cap.
    var key: String
    var label: String
    var used: Double
    var limit: Double
    var format: TankFormat
    var resetsAt: Date?
    var periodSeconds: TimeInterval?
    /// When the current window opened, for vendors that state it (Cursor's billing cycle). Rolling
    /// windows leave it nil and `windowStart` derives it from the reset and the period.
    var startsAt: Date?
    /// Paid overflow (Claude extra usage, Cursor on-demand, Codex flex credits): the credits-guard
    /// rule watches these, and the account block prints them under its bars.
    var isPaid: Bool = false
    /// A one-line qualifier under the bar (e.g. "of the 50% share").
    var note: String?

    var fill: Double {
        guard limit > 0 else { return 0 }
        return max(0, used / limit)
    }

    var remainingSeconds: TimeInterval? {
        resetsAt.map { max(0, $0.timeIntervalSinceNow) }
    }

    /// Start of the current window: stated by the source, else reset minus period.
    var windowStart: Date? {
        if let startsAt { return startsAt }
        guard let resetsAt, let periodSeconds, periodSeconds > 0 else { return nil }
        return resetsAt.addingTimeInterval(-periodSeconds)
    }
}

/// What one poll of one account produced.
struct AccountReading: Sendable, Hashable {
    enum Status: Sendable, Hashable {
        case ok
        /// The last good reading is being shown; the latest poll failed for `reason`.
        case stale(reason: String)
        case signedOut(reason: String)
        case error(String)
    }

    var account: TankAccount
    var plan: String?
    var tanks: [Tank]
    /// Per-model spend this cycle (Cursor), printed as a small line under the month bar.
    var byModel: [(model: String, dollars: Double)] = []
    /// A paid meter shared by the whole team (Cursor's team-wide on-demand spend against the team
    /// limit); the vendor column prints it once on its bottom line.
    var teamPaid: Tank?
    var fetchedAt: Date
    var status: Status = .ok

    static func == (lhs: AccountReading, rhs: AccountReading) -> Bool {
        lhs.account == rhs.account && lhs.plan == rhs.plan && lhs.tanks == rhs.tanks
            && lhs.teamPaid == rhs.teamPaid
            && lhs.fetchedAt == rhs.fetchedAt && lhs.status == rhs.status
            && lhs.byModel.map(\.model) == rhs.byModel.map(\.model)
            && lhs.byModel.map(\.dollars) == rhs.byModel.map(\.dollars)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(account)
        hasher.combine(fetchedAt)
    }

    var isLive: Bool {
        if case .ok = status { return true }
        return false
    }

    func tank(_ key: String) -> Tank? {
        tanks.first { $0.key == key }
    }
}

/// Errors a `TankSource` raises. The poller maps `rateLimited` to a per-account backoff and
/// everything else to a stale/error status on the card, never to a panel-wide failure.
enum TankSourceError: Error, LocalizedError, Equatable {
    case notSignedIn(String)
    case rateLimited(retryAfterSeconds: Int?)
    case http(Int)
    case invalidBody(String)
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn(let why): "not signed in: \(why)"
        case .rateLimited(let secs): "rate limited" + (secs.map { ", retry in \($0)s" } ?? "")
        case .http(let code): "HTTP \(code)"
        case .invalidBody(let why): "unexpected response: \(why)"
        case .refreshFailed(let why): "token refresh failed: \(why)"
        }
    }
}

/// One account's data feed. Implementations are value types holding only Sendable clients so the
/// poller can run six of them concurrently off the main actor.
protocol TankSource: Sendable {
    var account: TankAccount { get }
    func fetch() async throws -> AccountReading
}
