# Claude Usage Widget: project notes

Claude 5h / 7d / Fable usage as rings on the Windows 11 taskbar, with a per-account list and settings on click.
It's plain PowerShell 5.1 + WPF, with no dependencies. Public repo; each version ships as a GitHub release with an installer.

Status (2026-09-29): **v1.2.2 released**. The project is feature-complete for now; see "Open items" below.

## Layout

| Path | What it does |
| --- | --- |
| `ClaudeUsageWidget.ps1` | UI: taskbar widget window, popup (list + settings), timers, snapshot renderer. Params: `-Once` (JSON, no UI), `-Demo` (fake data, config untouched), `-Snapshot <dir>` (renders `widget.png` + `settings.png`) |
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
- Claude Code logins are **read-only**: never refresh them, because refresh-token rotation would log Claude Code out. An expired login shows "open Claude Code to renew".
- Token sources: `claude-code` (+`dir`), `xndr-claude` (`xndr-claude token <name>`), `command`, `env`. Tokens are never logged, written or passed as arguments.

## Gotchas (learned the hard way)

- **Keep source ASCII-only.** PS 5.1 reads BOM-less files as ANSI. Use `[char]0x2026` etc. for symbols (check with `grep -nP '[^\x00-\x7F]'`).
- **PowerShell variables are case-insensitive.** A local `$w` shadows a global `$W`, and callee functions see the caller's locals. That's why the UI globals are named `$WidgetEls`, `$PopupEls`, `$Theme`, `$Colors`.
- **Expressions in arguments are always evaluated,** even when the called function does nothing with them. `[int]` of ms since `DateTime.MinValue` overflowed and crashed the app (the `Write-Trace` line). Use `[int64]`.
- **Popup rendering:**
  - The popup is a fixed-size, full-work-area-height transparent window with the card pinned to the taskbar edge, so it never resizes; transparent pixels are click-through.
  - Windows re-shows a layered window's **last drawn frame**. So Hide-Popup switches to the list at opacity 0 and hides 80 ms later (`$hideTimer`).
  - Content and position are set while the window is transparent, then it fades in.
- **Settings edits are in memory** (live preview) until Save. `Save-UiConfig` is a no-op while `$script:editing`, and a refresh finishing mid-edit must not `Import-UiConfig`.
- **XAML rows are parsed separately,** so use `{DynamicResource ...}` for keyed styles (StaticResource fails at parse time).
- **The widget re-asserts TOPMOST every 750 ms,** because the taskbar rises above it when clicked. It hides while a full-screen app is in front.
- **Launch uses `conhost.exe --headless powershell.exe ...`** (no VBScript; VBScript is being deprecated).

## Debugging

- `CUW_DEBUG=1` logs popup open/close decisions to `%APPDATA%\claude-usage-widget\widget.log`. Errors are always logged there.
- Run a visible copy with errors captured: `powershell -STA -File ClaudeUsageWidget.ps1 -Demo` (redirect stderr).
- **UI tests:** drive the widget with Windows UI Automation (window name `Claude usage`; the gear is named `[char]0xE713`; buttons are named `Save` / `Cancel`).
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
- Multi-monitor: the widget uses the primary screen's taskbar only.
- Git Credential Manager hung once on push on the owner's PC (see step 3 of the release process).
