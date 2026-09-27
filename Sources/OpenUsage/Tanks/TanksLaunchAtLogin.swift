import Foundation

/// Tanks registers itself as a login item the first time a live instance runs, so the app is back
/// after every login without a visit to System Settings. The upstream Launch at Login switch sits on
/// a settings screen the Tanks panel never shows, so the footer carries its own switch; turning it
/// off there is remembered (`seededKey`) and never re-seeded on a later launch.
///
/// `SMAppService.mainApp` registers the running bundle by path, so the item points at
/// `dist/Tanks.app`, which every rebuild overwrites in place — the item survives updates.
@MainActor
enum TanksLaunchAtLogin {
    static let seededKey = "tanks.launchAtLogin.seeded"

    /// Register once per install. Snapshot instances never touch it: they are the same bundle, but a
    /// fixture render is not the moment to change a login item.
    static func seedOnce(_ setting: LaunchAtLoginSetting, defaults: UserDefaults = .standard) {
        guard !TanksSnapshot.isRequested else { return }
        guard !defaults.bool(forKey: seededKey) else { return }
        defaults.set(true, forKey: seededKey)
        guard !setting.isEnabled else { return }
        setting.update(to: true)
        AppLog.info(.lifecycle, "launch at login: registered on first run (\(setting.isEnabled ? "enabled" : setting.errorMessage ?? "status unchanged"))")
    }
}
