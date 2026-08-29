# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Harness** wraps the web workbench of [DeepSeek Harness](https://github.com/deepseek-ai/dsh) (`dsh`) in a native macOS app: launching the app starts the `dsh web` service, quitting stops it. Pure SwiftUI + AppKit + WKWebView, no Electron. SwiftPM package `DSHWeb` (executable target), no external dependencies.

The service is not bundled — it runs as `node <dsh>/lib/bin.js web`, resolved at runtime from Node and the npx cache on the user's machine.

## Commands

```bash
swift build                                  # debug build
swift test                                   # all unit tests (swift-testing, not XCTest)
swift test --filter WebViewNavigationTests   # one suite
swift test --filter externalLinkOpensInBrowser  # one test

./scripts/build.sh                # universal (arm64 + x86_64) → dist/Harness.app → ~/Applications
ARCHS=arm64 ./scripts/build.sh    # single-arch, much faster for local iteration
NO_INSTALL=1 ./scripts/build.sh   # build only, skip install (CI uses this)
```

`build.sh` env vars: `VERSION`, `BUILD` (default: derived from `git describe` + commit count), `ARCHS`, `NO_INSTALL`, `CODESIGN_IDENTITY` (default `Harness Local Signing`; falls back to ad-hoc). Prefer the stable self-signed identity — ad-hoc signatures change every build, which makes macOS re-prompt for TCC folder permissions each time.

**Gotcha:** the `.build*` directories cache absolute module-cache paths. If the repo is moved, `swift build`/`swift test` fails with `missing required module 'SwiftShims'`. Fix: `rm -rf .build .build-arm64 .build-x86_64`.

## Architecture

### Manual AppKit entry, deliberately
`main.swift` creates `NSApplication` + `AppDelegate` directly instead of using the SwiftUI `App` protocol. Reason: SwiftUI continuously rebuilds the default main menu and clobbers the custom bilingual menu bar. Consequences that must be preserved:

- `MenuBuilder.rebuild()` sets the menu twice (immediately + on the next main-queue tick) to cover both override timings.
- `MenuBuilder.startGuard()` runs a 1 s `Timer` that compares `NSApp.mainMenu` against `lastMenu` and rebuilds when SwiftUI has replaced it.
- Windows are created by hand (`NSWindow` + `NSHostingView`); the settings panel and log window are AppKit singletons (`SettingsPanel`, `LogPanel`) rather than SwiftUI `Settings`/`WindowGroup` scenes, so menu actions can open them repeatedly.
- `MenuBuilder.dumpMenuState` appends diagnostics to `/tmp/menu-state.log` on every rebuild and every third guard tick. It is live debug instrumentation, not dead code.

### State ownership
Three `@MainActor @Observable` singletons, all read directly by views (`@State private var x = X.shared`):

- `ServerManager.shared` — service process, log buffer, state machine.
- `AppState.shared` — UI state shared between menu and views (`showLogs`), plus the long-lived `WebViewController` (must survive SwiftUI view refreshes, so it lives here, not in a view).
- `MenuActions.shared` / `MenuBuilder` — `NSObject` targets for AppKit menu selectors.

### Service lifecycle (`ServerManager`, the core of the app)
State machine: `starting → running(port) | external(port) | failed(message)`.

- **Port is chosen by the app, never assumed.** `PortStrategy.defaultPort` (3080) is only dsh's composed default (`port: !!js ctx.webStartup.port ?? 3080`), so the app picks the first bindable port from 3080 upward (`PortStrategy.firstAvailable` + `LocalPort.isFree`, scan limit 32) and passes it explicitly with `--port`. Availability is a real `bind()` test, not an HTTP probe — dsh listens tens of seconds before it answers HTTP, so HTTP probing reports a starting server as a free port.
- **Startup attaches to an existing server only after verifying identity.** `DSHProcessIdentity` resolves the port's listeners (`lsof -t`) and checks each command line: it must be a `node` process whose args contain `@deepseek-ai/dsh` or an npm-generated `dsh` bin link. Confirmed dsh + answers HTTP → `.external`. Anything else (a stranger's server, or a dsh that isn't responding yet) → leave it alone and spawn our own on the next free port. Never load an unverified responder into the WebView.
- **Node resolution** (`resolveNode`): newest-mtime nvm version → `/opt/homebrew` → `/usr/local` → `/usr/bin`. `MenuBuilder.resolveNodePath` duplicates this for the language-sync path; keep the two in sync.
- **dsh resolution** (`resolveBootJS`): scans `~/.npm/_npx/*/node_modules/@deepseek-ai/dsh/lib/bin.js` and takes the newest. Found → spawn immediately (saves 3–5 s). Missing → `npx --yes @deepseek-ai/dsh --version` with a 180 s timeout, then re-resolve. Caveat: this means the dsh version drifts with whatever npx last cached, and `~/.dsh` is shared state that a newer dsh (e.g. the Electron DSH Desktop app's vendored runtime) can write in a format an older cached dsh refuses to boot against.
- **Spawning** runs `node <bootJS> --profile web --port <chosen>` as a *direct* child with a minimal environment (`HOME`, `PATH` = node bin + system dirs, `TERM`, `LANG`). Use the `--profile web` form, not the `dsh web` subcommand: `web` is an alias of `--profile web` and rejects parent flags (`web takes none of parent --profile, --patch, …`), and `--patch` is how config overlays get in. Direct-child is the whole point: `applicationShouldTerminate` / `applicationWillTerminate` call `stop()` so no orphaned server survives the app.
- **Readiness is detected two ways**, whichever wins: the log line `dsh web: http://127.0.0.1:<port>` (in `ingest`), or a successful HTTP probe (`probePort`, accepts 200–499). The probe path exists so the UI appears in ~2 s instead of waiting 20–30 s for dsh's full init; the dsh frontend renders its own loading state. Hard deadline 90 s.
- **Restart (`⌘⇧R`)** is intentionally heavy so plugin/config changes take effect: stop own process → poll up to 5 s for the port to be bindable → if still held, `SIGTERM` **only** listeners whose command line verifies as dsh (`terminateVerifiedDSHListeners`; unverified holders are logged and left running) → poll 3 s → relaunch, falling forward to another port if the old one is still taken.
- **Logging**: stdout and stderr share one pipe, drained on the `dsh-web.log` background queue, split on newlines, hopped to the main actor via `ingest`, timestamped, capped at 5000 lines. Entering `.failed` auto-expands the log sidebar (`ContentView.onChange(of: server.state)`).
- **Log persistence** (`LogFileSink` + `LogRotation`): the same already-masked line that goes into the in-memory buffer is also appended to `~/Library/Logs/Harness/harness-<date>[.<segment>].log`. `LogFileSink` confines all mutable state to a private *serial* `DispatchQueue` — deliberately not an actor, because unstructured Tasks on an actor are not FIFO and out-of-order log lines invert cause and effect while debugging. Rotation only ever *adds* segments (never renames), so `chronological` must sort by (stamp, segment): lexicographic order is wrong here (`harness-D.1.log` < `harness-D.log`). Two safety properties are locked by tests: `LogRotation.isOwnedLogFile` gates deletion, so foreign files in the directory are neither counted toward the 16 MB ceiling nor removed; and the segment currently being written is never evicted. Every I/O failure degrades silently to not-logging — a read-only log directory must never take down the service. Directory-ceiling enforcement runs only at rotation moments, because a `contentsOfDirectory` + per-file `stat` on every line would stall writes during dsh's streaming output. `AppDelegate` calls `closeLogFile()` from both termination hooks.
- **Diagnostics export** (`DiagnosticsReport`, 「文件 → 导出诊断信息…」): pure renderer, all environment facts injected by `ServerManager.diagnosticsReport()` so the format is unit-testable. It runs `SecretMasker.mask` over its *final rendered output* even though the log tail is already masked — the report is the artifact that gets pasted into issues, so it gets a last-line-of-defense pass. nil Node/boot paths render as the literal `未解析` rather than blank, because "not resolved" is itself the most common failure diagnosis.
- **Secret masking** (`SecretMasker.mask`) runs in `ServerManager.log(_:)` — the single funnel every line passes through, including the app's own messages — and again on the `.failed` message text, because that string is rendered in the UI. It is an ordered list of `NSRegularExpression` rules, pure and unit-tested: structural matches (Cookie/Authorization headers, URL userinfo, sensitive query params, named JSON/YAML/CLI fields) collapse to `****`; shape-based guesses (`sk-` keys, `Bearer`/`Basic`, alphanumeric runs ≥32) keep a 3-char prefix so two runs of the same value stay comparable. Two deliberate asymmetries, both locked by tests: bare `code`/`key`/`auth` are *not* treated as secrets outside URL query strings (`exit code: 1` and `--port 3080` must survive), and the header rule masks to end of line, which over-masks inline header objects — that is the intended direction, since Cookie values contain their own `;`/`=` separators. The `(?!\*\*\*\*)` assertions make masking idempotent; note the header rule's assertion sits *before* the separator group, because after it the regex backtracks `\s*` to dodge it and eats the space.

### WebView (`WebViewController`)
Navigation policy lives in the pure static `shouldStayInWebView(url:isUserInitiated:opensNewWindow:appHost:)` specifically so it is unit-testable — the delegate method only adapts `WKNavigationAction` to it. Rules: new window → external; user-clicked cross-origin → external; same-origin or programmatic (including cross-origin redirects like OAuth callbacks) → stay.

A `linkBridgeScript` user script also patches `window.open` and captures clicks in the capture phase, because the dsh frontend `preventDefault`s external links before WebKit's delegate ever sees them; it posts to the `openExternal` message handler, which validates the scheme is http/https before calling `NSWorkspace.open`.

Two performance mitigations for input lag during agent streaming (WebKit's compositor is less independent than Chromium's): `wantsLayer = true`, and `beginUserActivity()` holding a `ProcessInfo` activity token to prevent App Nap throttling. `⌘⇧O` (open in Chrome/default browser) is the escape hatch when streaming still stutters. **Never set private `WKPreferences` values such as `threadedScrollingEnabled`** — they throw `NSInvalidArgumentException` on macOS 26 and crash at launch.

### Language switching
Two hand-written menu trees (`buildMenu(language:)`), preference in `UserDefaults` under `appLanguage`, default `.zh`. Switching in Settings also writes `locale.preference` into `~/.dsh/settings.yaml` so the dsh web UI matches — done by shelling out to `node -e` with dsh's own bundled `yaml` module (`~/.dsh/profiles/web/node_modules/yaml/dist/index.js`) and `parseDocument`/`setIn`, which preserves the rest of the file. Applying the change restarts the app via `sh -c "sleep 1 && open <bundle>"`, because `open` on a still-running instance only activates it.

## Conventions

- Swift 6 strict concurrency: `@MainActor` isolation throughout; `nonisolated(unsafe)` only for the deliberate `MenuBuilder.lastMenu` case.
- One feature per file, ≤800 lines. Prefer immutable values; return copies rather than mutating.
- All user-visible strings need both Chinese and English in `MenuBuilder`. Repo docs, code comments, and commit bodies are written in Chinese.
- Colors/icons via SF Symbols and AppKit standard controls; the only hardcoded color is the dark window fallback in `WindowChrome`.
- Tests use swift-testing (`@Test`, `#expect`). `ServiceLanguageSyncTests` exercises real `node` + real `yaml`, and returns early when `~/.dsh/profiles/web` is absent (CI runners have no dsh profile) — keep that guard.
- Conventional Commits (`feat:`/`fix:`/`refactor:`/`docs:`/`test:`/`chore:`/`perf:`/`ci:`).

## Release

`git tag` is the single source of truth for versions. Pushing to `main` triggers `auto-release.yml`, which auto-bumps the patch version, pushes the tag, and calls `release.yml` in the same run (test → universal build → zip + SHA256 → GitHub Release with notes from the matching `CHANGELOG.md` entry plus the commit list). Commits whose subject starts with `docs:` or `chore:` are skipped, so use those prefixes to avoid cutting a release. Add a `## [x.y.z]` entry to `CHANGELOG.md` before landing a release-worthy change, otherwise the release notes contain only the commit list.
