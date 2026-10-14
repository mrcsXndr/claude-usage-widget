# Claude Usage Widget: project notes

Claude 5h / 7d / Fable usage as rings on the Windows 11 taskbar, with a per-account list and settings on click.
It's plain PowerShell 5.1 + WPF, with no dependencies. Public repo; each version ships as a GitHub release with an installer.

Status (2026-10-15): **v1.9.2** (patch) fixes self-update: `Invoke-UpdateNow` downloads the zip in a runspace (`Save-UpdateZip`, progress in `$script:updPct`, shown by `Set-UpdStatus` / `Update-UpdateControls` in the Updates tab), checks it with `Get-ZipVersion`, then `Start-UpdateHelper` runs a TEMP copy of `lib\Updater.ps1` which waits for the widget PID, backs up, replaces files, refreshes shortcuts via the staged `install.ps1 -NoLaunch`, starts the widget (`conhost --headless powershell ...`), verifies by CIM polling and rolls back on failure; log: `%APPDATA%\claude-usage-widget\update.log`. `tools\Test-Update.ps1` tests the relaunch headlessly (env hooks `CUW_TEST_ROOT`, `CUW_TEST_UPDATE_URL`). Gotcha: a function returning one CimInstance has no `.Count`; always `@(...).Count`. This agent shell has no interactive desktop (session 0), so only off-screen renders (`-Snapshot`) and headless tests work. New options: `spacing` (tight|normal|wide, `$SpacingPresets`), `names` (left|right|hidden), `innerWindow` (5h|7d, `Get-PieKey`; per-account `pie` overrides), `next` also `resetin` / `resetat`, `hideAtLimit` (`Get-ShownCfgs`), `showLegend`; per-ring hover (`Get-RingTip`); Settings > Accounts uses a chip strip (`AcctChips`) and the details are always open. **v1.9.1** (patch) makes the ring content two independent choices, `inside` (none | initials | percent) and `next` (none | caption | percent), replaces `showPercents` / `showCaptions` (still read as a fallback by `Get-InsideMode` / `Get-NextMode`), adds `size` (compact | normal | large; `$SizePresets` / `Set-SizePreset` drive every dimension, large adds reset times) and `showDividers` (default off; the gap stays the same, only the line is transparent). `-RingCheck` runs all three presets. There is no other flyout to merge: the list popup is the only one and Settings stays its own window. **v1.9.0** fixes the ring arc (round caps made 91% look like 95%: arcs are flat-capped and exact; `-RingCheck` measures them), makes Settings its own resizable window (title bar, tabs, OK / Cancel / Apply; fixed size, so tabs never resize it), enlarges the rings and text for laptops, and stops the widget rebuilding on click/close (`Get-WidgetSig` skips an unchanged rebuild; `Start-Raise` puts the widget back above the taskbar). **v1.8.0** adds Display > Percentages (`showPercents`, default on; off = rings only, Combined turns into inner + outer ring) with per-account initials inside the ring (`short`, else auto from `Get-Shorts`: first letter, two letters on a clash), ring positions + colour key in the hover tooltip, and a legend line under the list. `-Snapshot` also writes `bar-*.png` (taskbar strip at 100/125/150% via `SetRootDpi`) and `widget-nopct.png` for layout checks. **v1.7.1** (patch: auto-find new accounts with Add/Ignore + badge, Settings tabs, reorder, ring centring, PATH refresh). Small fixes are patch bumps from now on. **v1.7.0** saves an approved token at once (Cancel no longer deletes the variable; the account is also written to the Cancel copy and config.json) and offers `xndr-claude add <name> --stdin` first when that command exists. **v1.6.0** adds Add account > Token (paste a setup token; after approval it is saved as user env var `CLAUDE_USAGE_TOKEN_<NAME>`, account `source: env` + `envManaged: true`; `Get-UserEnvToken` reads HKCU\Environment; xndr-claude is offered only when installed). v1.5.0 (self-update: daily GitHub release check, tray notification, "Update available" box, Update now runs the official `install.ps1` URL; state in `state.json` `updateCheckedAt` / `updateVersion` / `notifiedVersion` / `pendingUpdate`, setting `updateCheck` in config). v1.4.0 added Settings: find / add / remove accounts (the Browse folder dialog sets `$script:modal` so the popup's Deactivated handler doesn't close Settings). The project is feature-complete for now; see "Open items" below.

## Layout

| Path | What it does |
| --- | --- |
| `ClaudeUsageWidget.ps1` | UI: taskbar widget window, popup (account list), Settings window, timers, snapshot renderer. Params: `-Once` (JSON, no UI), `-Demo` (fake data, config untouched), `-Snapshot <dir>` (renders `widget.png` + `settings.png`, tab shots at 100/150%, `bar-known-*.png` with 91/50/25/100/0%), `-RingCheck` (measures arc sweeps; exit 1 on a miss) |
| `lib/Usage.ps1` | No UI. Config (`%APPDATA%\claude-usage-widget\config.json`), account discovery, token sources, usage reads, `$AppVersion`, `New-LauncherShortcut` |
| `install.ps1` / `Install.cmd` / `uninstall.ps1` | Per-user install to `%LOCALAPPDATA%\Programs\ClaudeUsageWidget`; Start menu + Startup shortcuts; HKCU Uninstall entry (Settings > Apps) |
| `tools/Build-Release.ps1` | Builds `dist\ClaudeUsageWidget.zip` + `dist\install.ps1` from HEAD |
| `tools/Build-Icon.ps1` | Renders `assets\icon.ico` / `icon.png` |
| `docs/*.png` | README images, rendered with `-Snapshot docs` (demo accounts only; never real account names) |

## How usage is read (lib/Usage.ps1)

- **Usage API (free):** `GET api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`. It needs the `user:profile` scope, so it only works for Claude Code logins (`~/.claude*/.credentials.json`). Fable comes from `limits[]` entries with `kind == weekly_scoped` and `scope.model.display_name` matching Fable.
- **Probe:** setup-tokens get a 403 `oauth_scope_insufficient` from the usage API, which Anthropic won't change (anthropics/claude-code#81015, closed as not planned).
  - The widget sends a `max_tokens: 1` request and reads `anthropic-ratelimit-unified-{5h,7d}-{utilization,reset}` (0-1 fraction, unix seconds).
  - It probes **Fable** (`claude-fable-5-1`) because only then does the reply include the Fable bucket header `7d_oi`. Non-Haiku models need the Claude Code system prompt with OAuth tokens. If Fable fails, it falls back to Haiku.
  - `MethodCache` remembers which accounts must use the probe.
- **Plan label:** `GET /api/oauth/profile` (`organization.rate_limit_tier` like `default_claude_max_20x`, `organization_type` like `claude_max`) on each refresh for tokens with `user:profile`; the last good answer is cached in `MethodCache["<name>:plan"]`. Setup-tokens get a 403 there and no probe header carries the plan (checked 2026-10-10), so the account's `plan` config field (the Settings picker; empty = Auto) is the fallback. The API value always wins.
- Claude Code logins are **read-only**: never refresh them, because refresh-token rotation would log Claude Code out. An expired login shows "open Claude Code to renew".
- Token sources: `claude-code` (+`dir`), `xndr-claude` (`xndr-claude token <name>`), `command`, `env`. Tokens are never logged, written or passed as arguments.

## Gotchas (learned the hard way)

- **Keep source ASCII-only.** PS 5.1 reads BOM-less files as ANSI. Use `[char]0x2026` etc. for symbols (check with `grep -nP '[^\x00-\x7F]'`).
- **PowerShell variables are case-insensitive.** A local `$w` shadows a global `$W`, and callee functions see the caller's locals. That's why the UI globals are named `$WidgetEls`, `$PopupEls`, `$Theme`, `$Colors`.
- **Expressions in arguments are always evaluated,** even when the called function does nothing with them. `[int]` of ms since `DateTime.MinValue` overflowed and crashed the app (the `Write-Trace` line). Use `[int64]`.
- **Popup rendering:**
  - The popup is a fixed-size, full-work-area-height transparent window with the card pinned to the taskbar edge, so it never resizes; transparent pixels are click-through. It only shows the account list.
  - Windows re-shows a layered window's **last drawn frame**. So Hide-Popup sets opacity 0 and hides 80 ms later (`$hideTimer`); nothing is rebuilt on the way out.
  - Content and position are set while the window is transparent, then it fades in.
- **Settings is a separate normal window (`$settings`).** Its controls live in `$PopupEls` too (`SList`, `SNewAcctBox`, `Tab_*`, `Opt*`...). It is only ever hidden (Closing is cancelled and treated as Cancel, except while exiting). It shares the popup's styles through `Card.Resources`. Rows come from `New-AccountRow $cfg $shown $edit`.
- **Settings edits are in memory** (live preview) until OK / Apply. `Save-UiConfig` is a no-op while `$script:editing`, and a refresh finishing mid-edit must not `Import-UiConfig` (`Update-All` rebuilds Settings only on `$script:forcePopup` and not while a text box has focus). `Save-Editing` is Apply.
- **Ring arcs use flat caps.** Round caps stick out half a stroke width at both ends and read as a larger percentage. After touching `Set-Ring` or the ring XAML run `-RingCheck`.
- **`Update-Widget` skips the rebuild when `Get-WidgetSig` is unchanged** (rebuilding on every call flashed the widget); it only refreshes tooltips then. Anything new that changes how the rings look must be part of that signature.
- This box's agent session has no interactive desktop (UIA root is empty), so real-window screenshots and click tests need the owner's session; `-Snapshot` renders off-screen instead.
- **XAML rows are parsed separately,** so use `{DynamicResource ...}` for keyed styles (StaticResource fails at parse time).
- **The widget re-asserts TOPMOST every 750 ms,** because the taskbar rises above it when clicked. It hides while a full-screen app is in front.
- **Launch uses `conhost.exe --headless powershell.exe ...`** (no VBScript; VBScript is being deprecated).

## Debugging

- `CUW_DEBUG=1` logs popup open/close decisions to `%APPDATA%\claude-usage-widget\widget.log`. Errors are always logged there.
- Run a visible copy with errors captured: `powershell -STA -File ClaudeUsageWidget.ps1 -Demo` (redirect stderr).
- **UI tests:** drive the widget with Windows UI Automation (window name `Claude usage`; the gear is named `[char]0xE713`).
  - Settings is its own window named `Claude Usage Widget - Settings` (buttons `OK`, `Cancel`, `Apply`; tabs `Accounts`, `Display`, `Captions`, `Updates`).
  - Find the widget's rectangle via UIA instead of hard-coding coordinates.
  - To "click away", click the **empty taskbar just left of the widget**, never a spot on the user's screen: a blind click once hit a browser link.

## Release process

1. Bump `$AppVersion` in `lib/Usage.ps1` and add a `CHANGELOG.md` entry.
2. `.\ClaudeUsageWidget.ps1 -Snapshot docs` if the UI changed.
3. Commit and push. If Git Credential Manager hangs, use `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push`.
4. `.\tools\Build-Release.ps1`
5. `gh release create vX.Y.Z dist\ClaudeUsageWidget.zip dist\install.ps1 --title "Claude Usage Widget X.Y.Z" --notes-file <notes>`
6. Verify with `irm https://github.com/mrcsXndr/claude-usage-widget/releases/latest/download/install.ps1 | iex`.

The installers download `releases/latest`, so users only get tagged versions. **Ask the owner before pushing or releasing.**

## Open items

- Untested: double-clicking `Install.cmd` from a downloaded ZIP on a fresh PC (SmartScreen / mark-of-the-web behaviour).
- Untested end to end: "Update now" (needs a release newer than the installed copy) and the tray balloon's on-screen look (checked headless only).
- Multi-monitor: the widget uses the primary screen's taskbar only.
- Git Credential Manager hung once on push on the owner's PC (see step 3 of the release process).
