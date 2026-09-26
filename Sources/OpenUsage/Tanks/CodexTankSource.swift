import Foundation

/// Codex (ChatGPT) usage for one account from an `auth.json`: the live `~/.codex/auth.json` for
/// the signed-in account, or Tanks' own copy under `~/.codex-tanks/<slot>/auth.json` for the
/// other one. Refreshed tokens are written back to the file they came from.
struct CodexTankSource: TankSource {
    var account: TankAccount
    var config: TanksConfig
    var files: TextFileAccessing = LocalTextFileAccessor()
    var client = CodexUsageClient()
    var now: @Sendable () -> Date = Date.init

    var liveAuthPath: String { config.codexLiveAuthPath.expandingTilde }
    var parkedAuthPath: String { "\(config.codexParkedAuthDir)/\(account.id.slot.rawValue)/auth.json".expandingTilde }

    /// The live file belongs to this account when its id_token carries this account's email.
    func isActive() -> Bool {
        guard let auth = Self.readAuth(at: liveAuthPath, files: files) else { return false }
        return Self.email(of: auth)?.lowercased() == account.email.lowercased()
    }

    func fetch() async throws -> AccountReading {
        let path = isActive() ? liveAuthPath : parkedAuthPath
        guard var auth = Self.readAuth(at: path, files: files) else {
            let hint = path == liveAuthPath ? "live auth.json" : "parked copy missing — run `CODEX_HOME=\((parkedAuthPath as NSString).deletingLastPathComponent) codex login`"
            throw TankSourceError.notSignedIn(hint)
        }
        guard var tokens = auth.tokens, let access = tokens.accessToken, !access.isEmpty else {
            throw TankSourceError.notSignedIn("auth.json has no access token")
        }
        if let exp = Self.expiry(access), exp.timeIntervalSince(now()) <= 5 * 60 {
            tokens = try await refresh(tokens)
            auth.tokens = tokens
            try save(auth, at: path)
        }
        var response = try await client.fetchUsage(accessToken: tokens.accessToken ?? "", accountID: tokens.accountID)
        if response.statusCode == 401 {
            tokens = try await refresh(tokens)
            auth.tokens = tokens
            try save(auth, at: path)
            response = try await client.fetchUsage(accessToken: tokens.accessToken ?? "", accountID: tokens.accountID)
        }
        if response.statusCode == 429 { throw TankSourceError.rateLimited(retryAfterSeconds: nil) }
        guard (200..<300).contains(response.statusCode) else { throw TankSourceError.http(response.statusCode) }
        guard let body = ProviderParse.jsonObject(response.body) else { throw TankSourceError.invalidBody("not JSON") }
        return AccountReading(
            account: account,
            plan: (body["plan_type"] as? String).map(Self.planLabel),
            tanks: Self.tanks(from: body),
            fetchedAt: now()
        )
    }

    // MARK: - Mapping

    static func tanks(from body: [String: Any]) -> [Tank] {
        var tanks: [Tank] = []
        if let rate = body["rate_limit"] as? [String: Any] {
            for key in ["primary_window", "secondary_window"] {
                guard let window = rate[key] as? [String: Any],
                      let used = ProviderParse.number(window["used_percent"])
                else { continue }
                let period = ProviderParse.number(window["limit_window_seconds"]) ?? 0
                let label = windowLabel(period)
                tanks.append(Tank(
                    key: label, label: label, used: used, limit: 100, format: .percent,
                    resetsAt: ProviderParse.number(window["reset_at"]).map { Date(timeIntervalSince1970: $0) },
                    periodSeconds: period > 0 ? period : nil
                ))
            }
        }
        if let spend = body["spend_control"] as? [String: Any],
           let individual = spend["individual_limit"] as? [String: Any],
           let limit = ProviderParse.number(individual["limit"]), limit > 0 {
            let used = ProviderParse.number(individual["used"]) ?? 0
            let resets = ProviderParse.number(individual["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            let unit = (individual["unit"] as? String) ?? "credit"
            tanks.append(Tank(
                key: "month", label: "month", used: used, limit: limit,
                format: unit == "credit" ? .credits : .dollars,
                resetsAt: resets, periodSeconds: 30 * 86400,
                note: "spend control, \(unit)s"
            ))
        }
        if let credits = body["credits"] as? [String: Any], let balance = ProviderParse.number(credits["balance"]) {
            tanks.append(Tank(key: "flex", label: "flex credits", used: 0, limit: balance * 0.04, format: .dollars, isPaid: true,
                              note: "\(Int(balance)) credits"))
        }
        return tanks
    }

    static func windowLabel(_ seconds: Double) -> String {
        switch seconds {
        case 0: "window"
        case ..<(6 * 3600): "\(Int((seconds / 3600).rounded()))-hour"
        case ..<(2 * 86400): "day"
        case ..<(8 * 86400): "week"
        default: "month"
        }
    }

    static func planLabel(_ raw: String) -> String {
        raw.replacingOccurrences(of: "self_serve_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }

    // MARK: - Auth file

    static func readAuth(at path: String, files: TextFileAccessing) -> CodexAuth? {
        guard files.exists(path), let text = try? files.readText(path) else { return nil }
        return CodexAuthStore.parseAuth(text)
    }

    static func email(of auth: CodexAuth) -> String? {
        guard let idToken = auth.tokens?.idToken, let claims = ProviderParse.jwtPayload(idToken) else { return nil }
        return claims["email"] as? String
    }

    static func expiry(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private func save(_ auth: CodexAuth, at path: String) throws {
        var auth = auth
        auth.lastRefresh = OpenUsageISO8601.string(from: now())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(auth)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try files.writeText(path, text)
        AppLog.info(.auth, "codex \(account.id): rotated token written back")
    }

    private func refresh(_ tokens: CodexTokens) async throws -> CodexTokens {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw TankSourceError.refreshFailed("no refresh token")
        }
        do {
            let refreshed = try await client.refreshToken(refreshToken)
            var updated = tokens
            updated.accessToken = refreshed.accessToken
            if let r = refreshed.refreshToken, !r.isEmpty { updated.refreshToken = r }
            if let id = refreshed.idToken, !id.isEmpty { updated.idToken = id }
            return updated
        } catch {
            throw TankSourceError.refreshFailed(error.localizedDescription)
        }
    }
}
