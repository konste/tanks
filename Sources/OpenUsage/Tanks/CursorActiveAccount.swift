import Foundation

/// Which Cursor account Tanks treats as signed in. The Cursor Admin API has no signal for this
/// (see `TanksConfig.cursorActiveSlot`), so it is konstantin's own say-so: set from the dashboard's
/// "set active" control after he switches Cursor by hand, and it stays there until he changes it
/// again — unlike Claude and Codex, this can be told but never sensed.
enum CursorActiveAccount {
    private static let key = "tanks.cursor.activeSlot"

    static func slot(defaults: UserDefaults = .standard, fallback: AccountSlot) -> AccountSlot {
        defaults.string(forKey: key).flatMap(AccountSlot.init(rawValue:)) ?? fallback
    }

    static func setSlot(_ slot: AccountSlot, defaults: UserDefaults = .standard) {
        defaults.set(slot.rawValue, forKey: key)
    }
}
