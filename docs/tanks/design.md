# Tanks — design (draft 2026-09-26)

Personal macOS menu-bar app: remaining subscription allowance for Claude Code, Codex and Cursor,
two accounts each, with a projection to the end of every window and advice on when to move load.
Mocks: `mock.html` (rendered: `mock-menubar.png`, `mock-panel.png`, `mock-alert.png`).

## Name

**Tanks.** Every allowance window is a fuel tank; a reset refuels it; moving load between accounts
is switching tanks. Confirmed 2026-09-26 after a detour through "Ration" ("I will get used to it").
Alternatives considered: Ration, Quota.

## Build decision: fork OpenUsage

Survey (2026-09-26): CodexBar (steipete, MIT/Swift, v0.67.0 today) covers ~80 providers but the
maintainer's own issue #81 says multi-account per provider is unsolved. OpenUsage (robinebers,
MIT/Swift, 4.3k stars, commits today) already runs on this Mac with BOTH Claude accounts as cards
(`~/Library/Preferences/com.robinebers.openusage.plist`), refreshes Claude tokens itself, reads
Codex from `~/.codex/auth.json` and Cursor from the app's state DB, and has burn-rate colouring.
Nothing surveyed does cross-vendor advice or account switching. ccusage / Claude-Code-Usage-Monitor
are terminal tools; cursor-stats is archived; the TokenBar clones are days old.

So: fork `robinebers/openusage` as Tanks. Keep its provider layer (auth store → usage client →
mapper → `ProviderSnapshot`) untouched so upstream endpoint fixes merge cleanly. Remove: log
scanning and the spend tiles (history is not wanted), round charts, PostHog, Sparkle feed. Add:
the compact strip, the six-account grid, 60-second polling, the projection line to reset, the
advisor, and the switch actions.

What it replaces: the OpenUsage install; `~/.chief-data/bin/allowance_probe.py` and its launchd
job (Tanks writes the same `~/.chief-data/allowance-state.json` schema so `allowance_watch.py`
and `render_allowance_page.py` keep working); opening chatgpt.com and cursor.com/dashboard by hand.

## Data — per vendor, per account (verified on this Mac 2026-09-26)

| Vendor | Source | Windows | Second account |
|---|---|---|---|
| Claude | `GET api.anthropic.com/api/oauth/usage`, bearer = OAuth token, header `anthropic-beta: oauth-2025-04-20` **and `User-Agent: claude-code/<ver>`** (without it the call lands in a 429 bucket — the probe hit `rate_limit_error` at 13:23 today) | `five_hour`, `seven_day`, `seven_day_opus`/`_sonnet` (sub-caps), `extra_usage` (credits: monthly_limit, used_credits) | token of the parked account: keychain `Claude Code-credentials-parked-admin` / `-parked-konstantin` (owned by `claude_account_switch`) |
| Codex | `GET chatgpt.com/backend-api/wham/usage`, bearer from `~/.codex/auth.json` + `ChatGPT-Account-Id` | `rate_limit` {used_percent, limit_window_seconds, reset_at}; `spend_control.individual_limit` {used, limit, remaining, reset_at} (monthly); `credits`; plan from id_token (`self_serve_business_prolite`) | a second `auth.json` kept by Tanks (`~/.codex-tanks/admin/auth.json`), refreshed through `auth.openai.com` |
| Cursor | POST `cursor.com/api/dashboard/get-aggregated-usage-events`, `get-hard-limit`, `get-monthly-invoice` — cookie `WorkosCursorSessionToken=<sub>::<jwt>` from `state.vscdb` + header `Origin: https://cursor.com` (403 without it). `get-user-usage-summary` returns HTML today. | per-model cents this cycle incl. the Auto pool, hard limit ($285), cycle start/end | **Enterprise Admin API** `api.cursor.com/teams/{spend,daily-usage-data,members}` with an admin key from the admin account — per-member spend for both accounts in one documented call, no cookie |

Admin-side extras that do NOT exist: Anthropic's org usage report returns API records only
(claude-code#27780, open since Feb); OpenAI's Compliance API is an audit log, Enterprise-only.
So Claude and Codex are read per account with that account's own token; Cursor is the one vendor
where the admin account buys a better source.

## Polling and projection (his rule: current state to the minute, no history UI)

- Poll every 60 s per account, six accounts staggered 10 s apart; the signed-in Claude account
  every 120 s and accounts not in use every 10 min (his ruling 2026-09-26). Claude's endpoint
  admits about one read per two minutes per token, and only with a `claude-code/<version>`
  User-Agent: measured 2026-09-26, 25 s apart on both tokens, every `claude-code/…` call answered
  200 and every `claude-cli/…`, `curl/…` or other agent answered 429 `Retry-After: 0`. If it still
  429s, back off that account for its own cadence (Retry-After is always 0) and mark the tank stale
  (grey hatch), never the whole panel.
- Keep an in-memory ring of samples per tank (last 60 min for 5-hour windows, last 12 h for
  weekly/monthly) purely to compute a slope; it is never shown. Slope = least-squares over the
  ring, floored at 0, dropping the segment that spans a reset.
- Projection at reset = used + slope × time-to-reset, drawn as the hatched extension. Crossing
  100% before the reset gives the red tick and a "100% at HH:MM" label; the time is the one the
  advisor quotes.
- Colour: green on course; amber = projected to land in the last 10% or fill ≥ 80%; red =
  projected to cross 100% or fill ≥ 92% (the probe's tiers).

## Advisor (rule-based, every rule names its two numbers)

1. **Switch now** — active account's window is projected to cross 100% before reset and the
   other account's same window has ≥ 30% headroom; fires when fill ≥ 90% or time-to-100% < 20
   min. Strip goes to state C, panel promotes the recommendation with a button.
2. **Switch later** — same condition but > 1 h away: "switch at HH:MM" with a scheduled reminder
   (or, opt-in, run the switch at that time; `acc` still asks for Touch ID, so only while present).
3. **Spare capacity** — a ration projected to reach reset with > 30% unused: named as a place to
   send work. Cross-vendor advice is this rule read across vendors.
4. **Credits guard** — paid overflow (Claude credits, Codex spend control, Cursor hard limit) ≥ 80%
   of its monthly cap: red regardless of window state, because past 100% every turn bills.

Recommendations expire when their condition clears; a dismissed one stays quiet for its window.

## Switch actions

- Claude: button runs `acc admin` / `acc konstantin` (existing tool, Touch ID gate, relaunches
  the app and rearms Remote Control). Tanks never holds the gate itself.
- Codex: swap `~/.codex/auth.json` with the parked copy, verify with `codex login status`
  (binary at `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex`). The ChatGPT desktop app shares that
  file; whether it needs a restart is the first thing to test.
- Cursor: no supported swap. Recommended: a second Cursor instance with its own `--user-data-dir`
  signed in as admin; Tanks then says which one to use. Column shows "manual" until then.

## Alerts

Menu-bar state C (a solid knock-out "!" badge next to the bold percentage; the image stays a template so macOS tints it to the bar — the earlier red-in-colour version was illegible on his dark-blue bar, 2026-09-26) plus a macOS notification for rule 1 and rule 4 only. The glyph's tank and percentage are the worst projected fill among the active accounts' capped tanks (percent and credit; dollar tanks are uncapped and excluded). Email stays available as
an option, off by default. (This contradicts the 2026-09-19 "email only" policy — needs his call.)

## Risks

- **Token refresh of the parked Claude account.** Anthropic's refresh may rotate the refresh
  token; if Tanks refreshes and does not write back to the parked keychain item, the next `acc`
  borrow falls back to a full SSO. Tanks becomes the single writer of the parked item; first test
  is a refresh followed by a switch.
- All three usage endpoints are undocumented; upstream OpenUsage patches them same-day, which is
  the reason the provider layer stays unmodified.
- Cursor Admin API needs an admin key created in the admin account's dashboard (Settings →
  Cursor Admin API Keys, Enterprise plan — the team is `Trase Systems`, id 7238493).

## Panel shape (revised 2026-09-26, his instruction: no scrolling, landscape, width > height)

`mock2.html` (rendered: `panel-dark.png`, `panel-light.png`, `panel-alert.png`). A fixed
1040 × 600 px popover (the 780 × 430 design scaled by 4/3 on 2026-09-26, his ask: "1/3 larger in both directions", plus 20 design points for advice lines that wrap; every size in `TanksDashboardView` is a design literal times `S`), ratio ~1.7:1, nothing scrolls. The panel is draggable by any non-interactive area (header included) and reopens where it was left, clamped to the screen; first open is pinned to the left screen edge under the menu bar (his ask the same day). Right-click menu: Reset Panel Position. Advice lines wrap to two lines with the burn detail trailing in the dim style; the full text is the tooltip. Three vendor columns side by side, each
with the active account on top and the other account below it, one bar per window, the paid
line pinned to the column's bottom. Advice strip across the top (at most two lines), legend in
the footer. Everything that was vertical in the first mock is now horizontal, which is what took
the height from 600+ px to ~430.

Appearance follows the system (`prefers-color-scheme`, SwiftUI `@Environment(\.colorScheme)`):
one token set per theme, same layout, same colours for states (green / amber / red / blue for
"not signed in"); light mode darkens the hatch and the state colours so they hold on the pale
track. Both renders are in the PNGs above.
