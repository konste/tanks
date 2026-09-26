import Foundation

/// The six accounts and where their credentials live. Defaults describe this Mac; an optional
/// `~/.config/tanks/config.json` overrides the emails (same keys as the JSON below).
struct TanksConfig: Sendable, Codable {
    struct AccountConfig: Sendable, Codable {
        var primary: String
        var secondary: String
    }

    var claude: AccountConfig
    var codex: AccountConfig
    var cursor: AccountConfig

    /// Keychain items `claude_account_switch` keeps: the live item for the signed-in account and
    /// one parked copy per account. Which is which follows the marker file below.
    var claudeLiveKeychainService = "Claude Code-credentials"
    var claudeParkedKeychainServices = [
        AccountSlot.primary.rawValue: "Claude Code-credentials-parked-konstantin",
        AccountSlot.secondary.rawValue: "Claude Code-credentials-parked-admin",
    ]
    var claudeActiveMarkerPath = "~/Library/Application Support/Claude-active-account"
    /// `konstantin` / `admin` as the marker file spells them.
    var claudeMarkerNames = [AccountSlot.primary.rawValue: "konstantin", AccountSlot.secondary.rawValue: "admin"]
    var claudeSwitchTool = "~/.chief-data/bin/acc"

    var codexLiveAuthPath = "~/.codex/auth.json"
    /// Tanks' own copies of `auth.json`, one per account; the one whose email is not in the live
    /// file is the parked account. Created by `codex login` under `CODEX_HOME=<dir>`.
    var codexParkedAuthDir = "~/.codex-tanks"
    var codexBinary = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"

    /// Cursor Admin API key (Enterprise): keychain generic password, account = the macOS user.
    var cursorAdminKeyKeychainService = "tanks-cursor-admin-key"
    /// The Cursor account normally used; the Admin API does not say which client is signed in.
    var cursorActiveSlot: AccountSlot = .primary

    var pollInterval: TimeInterval = 60
    var staggerInterval: TimeInterval = 10
    var rateLimitBackoff: TimeInterval = 300

    /// Optional mirror of `~/.chief-data/bin/allowance_probe.py`'s output file. Off until the probe's
    /// launchd job is retired, so two writers never race on the file.
    var allowanceStatePath: String?
    var tanksStatePath = "~/.chief-data/tanks-state.json"

    static let defaults = TanksConfig(
        claude: AccountConfig(primary: "konstantin@trase.ai", secondary: "admin-konstantin@trase.ai"),
        codex: AccountConfig(primary: "konstantin@trase.ai", secondary: "admin-konstantin@trase.ai"),
        cursor: AccountConfig(primary: "konstantin@trase.ai", secondary: "admin-konstantin@trase.ai")
    )

    static func load(files: TextFileAccessing = LocalTextFileAccessor()) -> TanksConfig {
        let path = ("~/.config/tanks/config.json" as NSString).expandingTildeInPath
        guard files.exists(path), let text = try? files.readText(path),
              let data = text.data(using: .utf8)
        else { return .defaults }
        do {
            return try JSONDecoder().decode(TanksConfig.self, from: data)
        } catch {
            AppLog.warn(.config, "tanks config unreadable, using defaults: \(error.localizedDescription)")
            return .defaults
        }
    }

    func account(_ id: TankAccountID) -> TankAccount {
        let pair: AccountConfig
        switch id.vendor {
        case .claude: pair = claude
        case .codex: pair = codex
        case .cursor: pair = cursor
        }
        return TankAccount(id: id, email: id.slot == .primary ? pair.primary : pair.secondary)
    }

    var allAccounts: [TankAccount] {
        Vendor.allCases.flatMap { vendor in
            AccountSlot.allCases.map { account(TankAccountID(vendor: vendor, slot: $0)) }
        }
    }
}

extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
