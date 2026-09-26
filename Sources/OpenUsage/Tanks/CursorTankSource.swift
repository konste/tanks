import Foundation

/// Cursor per-member spend from the Enterprise Admin API (`POST /teams/spend`, Basic auth with the
/// admin key as the username). One call covers both accounts, so `CursorAdminFeed` fetches once and
/// serves each account's source from a short cache instead of doubling the request rate against the
/// 20 requests/minute cap.
actor CursorAdminFeed {
    struct MemberSpend: Sendable {
        var email: String
        var spendCents: Double
        var limitDollars: Double?
        var cycleStart: Date?
        var totalPercent: Double?
        var autoPercent: Double?
        var apiPercent: Double?
        var tier: String?
    }

    static let spendURL = URL(string: "https://api.cursor.com/teams/spend")!

    private let keychainService: String
    private let keychain: KeychainAccessing
    private let http: any HTTPClient
    private let ttl: TimeInterval
    private var cached: (at: Date, members: [MemberSpend])?
    private var inFlight: Task<[MemberSpend], Error>?

    init(keychainService: String, keychain: KeychainAccessing = SecurityKeychainAccessor(),
         http: any HTTPClient = URLSessionHTTPClient(), ttl: TimeInterval = 45) {
        self.keychainService = keychainService
        self.keychain = keychain
        self.http = http
        self.ttl = ttl
    }

    func members(now: Date = Date()) async throws -> [MemberSpend] {
        if let cached, now.timeIntervalSince(cached.at) < ttl { return cached.members }
        if let inFlight { return try await inFlight.value }
        let task = Task<[MemberSpend], Error> { try await self.load() }
        inFlight = task
        defer { inFlight = nil }
        let members = try await task.value
        cached = (now, members)
        return members
    }

    private func load() async throws -> [MemberSpend] {
        guard let key = try keychain.readGenericPassword(service: keychainService, account: NSUserName()),
              !key.isEmpty
        else {
            throw TankSourceError.notSignedIn("no admin key in keychain item '\(keychainService)'")
        }
        let basic = Data("\(key):".utf8).base64EncodedString()
        let response = try await http.send(HTTPRequest(
            method: "POST", url: Self.spendURL,
            headers: ["Authorization": "Basic \(basic)", "Content-Type": "application/json", "Accept": "application/json"],
            body: Data("{}".utf8), timeout: 15
        ))
        if response.statusCode == 429 { throw TankSourceError.rateLimited(retryAfterSeconds: 60) }
        if response.statusCode == 401 || response.statusCode == 403 { throw TankSourceError.notSignedIn("admin key rejected (HTTP \(response.statusCode))") }
        guard (200..<300).contains(response.statusCode) else { throw TankSourceError.http(response.statusCode) }
        guard let body = ProviderParse.jsonObject(response.body) else { throw TankSourceError.invalidBody("not JSON") }
        return Self.parse(body)
    }

    static func parse(_ body: [String: Any]) -> [MemberSpend] {
        let cycleStart = ProviderParse.number(body["subscriptionCycleStart"]).map {
            Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0)
        }
        let rows = body["teamMemberSpend"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let email = row["email"] as? String else { return nil }
            let limit = ProviderParse.number(row["hardLimitOverrideDollars"])
                ?? ProviderParse.number(row["effectivePerUserLimitDollars"])
                ?? ProviderParse.number(row["monthlyLimitDollars"])
            return MemberSpend(
                email: email,
                spendCents: ProviderParse.number(row["spendCents"]) ?? 0,
                limitDollars: limit.flatMap { $0 > 0 ? $0 : nil },
                cycleStart: cycleStart,
                totalPercent: ProviderParse.number(row["totalPercentUsed"]),
                autoPercent: ProviderParse.number(row["autoPercentUsed"]),
                apiPercent: ProviderParse.number(row["apiPercentUsed"]),
                tier: row["billingTier"] as? String
            )
        }
    }
}

struct CursorTankSource: TankSource {
    var account: TankAccount
    var config: TanksConfig
    var feed: CursorAdminFeed
    var now: @Sendable () -> Date = Date.init

    func isActive() -> Bool { account.id.slot == config.cursorActiveSlot }

    func fetch() async throws -> AccountReading {
        let members = try await feed.members(now: now())
        guard let me = members.first(where: { $0.email.lowercased() == account.email.lowercased() }) else {
            throw TankSourceError.notSignedIn("\(account.email) is not on the team's spend list")
        }
        let cycleEnd = me.cycleStart.flatMap { Calendar.current.date(byAdding: .month, value: 1, to: $0) }
        // The allowance is the percent fields: `totalPercentUsed` is the share of the seat's included
        // monthly usage consumed, split into the auto-mode and API pools. Dollars are the paid line.
        var tanks: [Tank] = []
        if let total = me.totalPercent {
            tanks.append(Tank(key: "month", label: "month", used: total, limit: 100, format: .percent,
                              resetsAt: cycleEnd, periodSeconds: 30 * 86400))
        }
        if let auto = me.autoPercent {
            tanks.append(Tank(key: "auto", label: "auto", used: auto, limit: 100, format: .percent,
                              resetsAt: cycleEnd, periodSeconds: 30 * 86400))
        }
        if let api = me.apiPercent {
            tanks.append(Tank(key: "api", label: "api", used: api, limit: 100, format: .percent,
                              resetsAt: cycleEnd, periodSeconds: 30 * 86400))
        }
        tanks.append(Tank(
            key: "spend", label: "spend", used: me.spendCents / 100, limit: me.limitDollars ?? 0,
            format: .dollars, resetsAt: cycleEnd, periodSeconds: 30 * 86400, isPaid: true,
            note: me.limitDollars == nil ? "no limit" : nil
        ))
        let plan = me.tier.map { $0.replacingOccurrences(of: "TIER_", with: "tier ") } ?? "Enterprise"
        return AccountReading(account: account, plan: plan, tanks: tanks, fetchedAt: now())
    }
}
