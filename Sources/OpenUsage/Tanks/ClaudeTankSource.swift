import Foundation

/// Claude Code subscription usage for one account, read with that account's own OAuth token.
///
/// The signed-in account's token is the live `Claude Code-credentials` keychain item; the other
/// account's is the parked copy `claude_account_switch` keeps. Both are read and written through
/// `/usr/bin/security` (the accessor already does this), the one path that never trips a keychain
/// ACL prompt for an ad-hoc-signed dev build. A refreshed token pair is written back to the item it
/// came from, so a later `acc` borrow finds a valid parked credential.
struct ClaudeTankSource: TankSource {
    static let prodConfig = ClaudeOAuthConfig(
        usageURL: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
        refreshURL: URL(string: "https://platform.claude.com/v1/oauth/token")!,
        clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    )

    var account: TankAccount
    var config: TanksConfig
    var keychain: KeychainAccessing = SecurityKeychainAccessor()
    var files: TextFileAccessing = LocalTextFileAccessor()
    var client = ClaudeUsageClient()
    var now: @Sendable () -> Date = Date.init

    /// The marker file `claude_account_switch` maintains (`konstantin` / `admin`).
    func isActive() -> Bool {
        let path = config.claudeActiveMarkerPath.expandingTilde
        let marker = (try? files.readText(path))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return marker == config.claudeMarkerNames[account.id.slot.rawValue]
    }

    var keychainService: String {
        isActive() ? config.claudeLiveKeychainService : (config.claudeParkedKeychainServices[account.id.slot.rawValue] ?? "")
    }

    func fetch() async throws -> AccountReading {
        let service = keychainService
        var credentials = try loadCredentials(service: service)
        guard var oauth = credentials.claudeAiOauth, let token = oauth.accessToken, !token.isEmpty else {
            throw TankSourceError.notSignedIn("empty token in \(service.hasSuffix("credentials") ? "live" : "parked") item")
        }
        if needsRefresh(oauth) {
            oauth = try await refresh(oauth)
            credentials.claudeAiOauth = oauth
            try save(credentials, service: service)
        }

        var response = try await client.fetchUsage(accessToken: oauth.accessToken ?? "", config: Self.prodConfig)
        if response.statusCode == 401 {
            oauth = try await refresh(oauth)
            credentials.claudeAiOauth = oauth
            try save(credentials, service: service)
            response = try await client.fetchUsage(accessToken: oauth.accessToken ?? "", config: Self.prodConfig)
        }
        if response.statusCode == 429 {
            throw TankSourceError.rateLimited(retryAfterSeconds: ClaudeUsageMapper.parseRetryAfterSeconds(response, now: now()))
        }
        guard (200..<300).contains(response.statusCode) else { throw TankSourceError.http(response.statusCode) }
        guard let body = ProviderParse.jsonObject(response.body) else { throw TankSourceError.invalidBody("not JSON") }
        return AccountReading(
            account: account,
            plan: ClaudeUsageMapper.formatPlan(subscriptionType: oauth.subscriptionType, rateLimitTier: oauth.rateLimitTier),
            tanks: Self.tanks(from: body),
            fetchedAt: now()
        )
    }

    // MARK: - Mapping

    static let sessionSeconds: TimeInterval = 5 * 3600
    static let weekSeconds: TimeInterval = 7 * 86400

    static func tanks(from body: [String: Any]) -> [Tank] {
        var tanks: [Tank] = []
        if let t = window(body["five_hour"], key: "5-hour", label: "5-hour", period: sessionSeconds) { tanks.append(t) }
        if let t = window(body["seven_day"], key: "week", label: "week", period: weekSeconds) { tanks.append(t) }
        for entry in body["limits"] as? [Any] ?? [] {
            guard let object = entry as? [String: Any],
                  object["kind"] as? String == "weekly_scoped",
                  let scope = object["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String,
                  let percent = ProviderParse.number(object["percent"])
            else { continue }
            let share = ProviderParse.number(object["share_percent"]).map { " of the \(Int($0))% share" }
            tanks.append(Tank(
                key: name.lowercased(), label: name, used: percent, limit: 100, format: .percent,
                resetsAt: resetDate(object["resets_at"]), periodSeconds: weekSeconds, note: share
            ))
        }
        if let extra = body["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let usedCents = ProviderParse.number(extra["used_credits"]) {
            let limitCents = ProviderParse.number(extra["monthly_limit"]) ?? 0
            tanks.append(Tank(
                key: "credits", label: "credits (paid)", used: usedCents / 100, limit: limitCents / 100,
                format: .dollars, isPaid: true
            ))
        }
        return tanks
    }

    private static func window(_ value: Any?, key: String, label: String, period: TimeInterval) -> Tank? {
        guard let object = value as? [String: Any], let used = ProviderParse.number(object["utilization"]) else { return nil }
        return Tank(key: key, label: label, used: used, limit: 100, format: .percent,
                    resetsAt: resetDate(object["resets_at"]), periodSeconds: period)
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let text = value as? String, let date = OpenUsageISO8601.date(from: text) { return date }
        guard let number = ProviderParse.number(value), number.isFinite else { return nil }
        return Date(timeIntervalSince1970: abs(number) < 1e10 ? number : number / 1000)
    }

    // MARK: - Credentials

    private func loadCredentials(service: String) throws -> ClaudeCredentialsFile {
        guard !service.isEmpty else { throw TankSourceError.notSignedIn("no keychain item configured") }
        guard let text = try keychain.readGenericPassword(service: service, account: NSUserName()),
              let data = text.data(using: .utf8)
        else { throw TankSourceError.notSignedIn("keychain item \(service) missing") }
        do {
            return try JSONDecoder().decode(ClaudeCredentialsFile.self, from: data)
        } catch {
            throw TankSourceError.notSignedIn("keychain item unreadable")
        }
    }

    private func save(_ credentials: ClaudeCredentialsFile, service: String) throws {
        let data = try JSONEncoder().encode(credentials)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try keychain.writeGenericPasswordForCurrentUser(service: service, value: text)
        AppLog.info(.auth, "claude \(account.id): rotated token written back (\(service.hasSuffix("credentials") ? "live" : "parked"))")
    }

    private func needsRefresh(_ oauth: ClaudeOAuth) -> Bool {
        guard let expiresAt = oauth.expiresAt else { return false }
        return expiresAt - now().timeIntervalSince1970 * 1000 <= 5 * 60 * 1000
    }

    private func refresh(_ oauth: ClaudeOAuth) async throws -> ClaudeOAuth {
        guard let refreshToken = oauth.refreshToken, !refreshToken.isEmpty else {
            throw TankSourceError.refreshFailed("no refresh token")
        }
        let response = try await client.refreshToken(refreshToken, config: Self.prodConfig)
        guard (200..<300).contains(response.statusCode) else {
            throw TankSourceError.refreshFailed("HTTP \(response.statusCode)")
        }
        guard let refreshed = try? JSONDecoder().decode(ClaudeRefreshResponse.self, from: response.body) else {
            throw TankSourceError.refreshFailed("undecodable body")
        }
        var updated = oauth
        updated.accessToken = refreshed.accessToken
        if let newRefresh = refreshed.refreshToken, !newRefresh.isEmpty { updated.refreshToken = newRefresh }
        if let expiresIn = refreshed.expiresIn {
            updated.expiresAt = (now().timeIntervalSince1970 + expiresIn) * 1000
        }
        return updated
    }
}
