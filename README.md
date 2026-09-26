# Tanks

A personal macOS menu-bar app showing remaining subscription allowance across Claude Code, OpenAI
Codex and Cursor, for two accounts each, with a projection to the end of every allowance window and
an advisor that says when to move load to the other account.

**Tanks is a fork of [OpenUsage](https://github.com/robinebers/openusage) by Robin Ebers and is
not the official OpenUsage.** The provider clients, auth stores and app shell come from OpenUsage
(MIT); the OpenUsage name, logo and branding are not used here per its
[trademark policy](TRADEMARK.md). What Tanks changes: a fixed 780×430 six-account dashboard with
horizontal tanks and projected usage, a compact menu-bar strip, second-account credential sources
(parked Claude keychain items, a second Codex `auth.json`, the Cursor Admin API), 60-second polling,
switch-now alerts, and no update feed, telemetry or iCloud sync.

Design, mocks and the survey of alternatives: [docs/tanks/design.md](docs/tanks/design.md).

## Build

Swift 6.2+ from Command Line Tools is enough; no Xcode project.

```sh
script/build_and_run.sh          # build, stage dist/Tanks.app, sign, launch
script/build_and_run.sh build    # build and stage only
```

Requires macOS 15 (Sequoia) or later. The upstream XCTest suite needs Xcode's XCTest framework,
which Command Line Tools do not ship; `swift test` runs only with Xcode installed.

## Upstream

OpenUsage's original README, provider docs and architecture notes are under [docs/](docs/); they
describe the inherited code and remain accurate for the provider layer.
