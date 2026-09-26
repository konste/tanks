import Foundation

/// The "switch" buttons. Claude hands off to `acc` (Touch ID, detached, relaunches the app); Codex
/// swaps `~/.codex/auth.json` with Tanks' parked copy and verifies with `codex login status`;
/// Cursor has no supported swap and reports that.
struct SwitchActions: Sendable {
    var config: TanksConfig
    var files: TextFileAccessing = LocalTextFileAccessor()
    var runner: ProcessRunning = SystemProcessRunner()

    enum Outcome: Sendable, Equatable {
        case started(String)
        case done(String)
        case unsupported(String)
        case failed(String)
    }

    func switchTo(_ id: TankAccountID) async -> Outcome {
        switch id.vendor {
        case .claude: return switchClaude(to: id.slot)
        case .codex: return switchCodex(to: id.slot)
        case .cursor: return .unsupported("Cursor has no account swap; use the second Cursor instance signed in as \(config.account(id).label).")
        }
    }

    private func switchClaude(to slot: AccountSlot) -> Outcome {
        let tool = config.claudeSwitchTool.expandingTilde
        guard files.exists(tool) else { return .failed("\(tool) not found") }
        let target = config.claudeMarkerNames[slot.rawValue] ?? slot.rawValue
        // `acc` re-executes itself detached and returns at once; the Touch ID sheet comes from the child.
        do {
            let result = try runner.run(executable: tool, arguments: [target], environment: [:], timeout: 30)
            return result.succeeded ? .started("acc \(target) started — Touch ID will ask") : .failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func switchCodex(to slot: AccountSlot) -> Outcome {
        let live = config.codexLiveAuthPath.expandingTilde
        let incoming = "\(config.codexParkedAuthDir)/\(slot.rawValue)/auth.json".expandingTilde
        let outgoingSlot: AccountSlot = slot == .primary ? .secondary : .primary
        let outgoing = "\(config.codexParkedAuthDir)/\(outgoingSlot.rawValue)/auth.json".expandingTilde
        guard files.exists(incoming) else {
            return .failed("no parked copy at \(incoming) — run `CODEX_HOME=\((incoming as NSString).deletingLastPathComponent) codex login` once")
        }
        do {
            let liveText = try files.readText(live)
            let incomingText = try files.readText(incoming)
            try files.writeText(outgoing, liveText)
            try files.writeText(live, incomingText)
        } catch {
            return .failed("swap failed: \(error.localizedDescription)")
        }
        let codex = config.codexBinary.expandingTilde
        guard files.exists(codex) else { return .done("auth.json swapped; codex binary not found to verify") }
        do {
            let result = try runner.run(executable: codex, arguments: ["login", "status"], environment: [:], timeout: 20)
            let line = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return result.succeeded ? .done("codex: \(line)") : .failed("codex login status: \(line)")
        } catch {
            return .done("auth.json swapped; verify failed: \(error.localizedDescription)")
        }
    }
}
