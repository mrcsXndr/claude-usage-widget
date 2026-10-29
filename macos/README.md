# Claude Usage for macOS

**Your Claude 5-hour, 7-day and Fable limits as small rings in the Mac menu bar.** A native Swift port of the Windows widget in this repo, reading the same numbers the same way.

## Features (first version)

- **Rings in the menu bar.** One ring per limit, green below 70%, amber below 90%, red from 90%, with the percentage inside. Hover for the numbers and reset countdowns.
- **All limits in one click.** Click the rings for every account's 5-hour window, 7-day window and Fable weekly limit, each with a bar, "Resets in 2h 14m" and the reset time.
- **Several Claude Code logins.** It finds the login in `~/.claude` and every other `~/.claude*` folder (one per account via `CLAUDE_CONFIG_DIR`). Tick the accounts you want in the menu bar; with more than one, each group of rings gets the account's initials.
- **Stays out of the way.** Refreshes every 30 minutes by default (5 at the most frequent), at most once a minute by hand, catches up after sleep, follows a light or dark menu bar, and has no Dock icon.
- **Launch at login.** On from the first run; turn it off from the gear menu or the right-click menu.

Not in this version yet: a Settings window, the Combined dial, size/caption options, setup-token and command token sources, self-update.

## Install

You need macOS 13 (Ventura) or later and the Xcode Command Line Tools. If `swift --version` doesn't work in Terminal, run `xcode-select --install` first.

```bash
git clone https://github.com/mrcsXndr/claude-usage-widget.git
cd claude-usage-widget/macos
./scripts/install.sh
```

That builds **Claude Usage.app**, copies it to `~/Applications` and starts it. Running the script again updates it and keeps your settings.

There is no prebuilt download: build it with the script above (an app built on your own Mac isn't quarantined by macOS).

**On a MacBook with a notch,** macOS hides menu bar items that don't fit to the left of the notch, without telling you. If the rings don't appear, quit an app with a menu bar icon, or hold ⌘ and drag other icons out of the menu bar to make room.

## Use

| | |
| --- | --- |
| **Click** the rings | Open the account list |
| **Tick** an account | Show it in the menu bar |
| **⟳** | Refresh now (at most once a minute) |
| **⚙** | Scan for accounts · Launch at login · Open config file · Open log · Quit |
| **Right-click** the rings | The same, as a menu |
| **⌘ + drag** | Move the rings along the menu bar (a macOS feature) |

## Accounts

On first run the app looks for Claude Code logins. On a Mac, Claude Code keeps its login in the **login Keychain**, not in a file:

| Config folder | Keychain item (service) |
| --- | --- |
| `~/.claude` (default) | `Claude Code-credentials` |
| any other folder set with `CLAUDE_CONFIG_DIR` | `Claude Code-credentials-<first 8 hex of SHA-256 of the folder path>` |

The app reads these with Apple's `security` tool, the same tool Claude Code uses to save them, so macOS normally doesn't ask for your password. If it does, choose **Always Allow**. A `.credentials.json` file in the folder is used when there's no Keychain item. Accounts are named after the email in `.claude.json`.

Signed in to another account later? Click the gear and choose **Scan for accounts**.

## Config file

`~/Library/Application Support/claude-usage-widget/config.json` (gear → **Open config file…**). Changes are picked up at the next refresh.

```json
{
  "refreshMinutes": 30,
  "inside": "percent",
  "accounts": [
    { "name": "claude-code", "label": "me@personal.com", "source": "claude-code", "menuBar": true },
    { "name": "claude-code-work", "label": "me@work.com", "source": "claude-code",
      "dir": "/Users/me/.claude-work", "menuBar": true, "limits": ["5h", "7d"], "short": "W" }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `refreshMinutes` | How often it refreshes; 5 at the lowest |
| `inside` | `"percent"` (default) or `"none"` for plain rings |
| `menuBar` | Show this account's rings in the menu bar |
| `dir` | The account's Claude Code config folder (leave out for `~/.claude`) |
| `limits` | Which rings to draw in the menu bar: any of `"5h"`, `"7d"`, `"fable"` |
| `short` | 1-2 letters shown before the rings when several accounts are shown |
| `hidden` | `true` leaves the account out of the list and the menu bar |
| `fable` | `false` skips the Fable probe for this account |

## How it works

Exactly like the Windows widget: for each account it calls `GET api.anthropic.com/api/oauth/usage` (free, doesn't touch your allowance). If that endpoint is rate-limited, it sends a 1-token probe and reads the limits from the rate-limit headers (about 35 tokens). The plan label comes from `/api/oauth/profile`.

**Claude Code logins expire.** The app only reads the login and never renews it, because renewing would sign Claude Code out. If you see "Login expired", run Claude Code once.

## Privacy

- Tokens are held in memory only for one request. They're never written to disk, logged, or passed on a command line.
- The only network calls go to `api.anthropic.com`.
- Settings live in `~/Library/Application Support/claude-usage-widget`.

## Uninstall

```bash
./scripts/uninstall.sh            # add --keep-settings to keep config.json
```

## For developers

```bash
swift build          # debug build
swift test           # parsing, Keychain naming and config tests
swift run            # runs from the terminal (Launch at login only works from the .app)
./scripts/build-app.sh
```

| Path | What it does |
| --- | --- |
| `Sources/UsageCore` | No UI: config, Claude Code logins (Keychain), usage API, probe, formatting |
| `Sources/ClaudeUsageBar` | The menu bar app: status item, ring drawing, SwiftUI dropdown, timers, launch at login |
| `Tests/UsageCoreTests` | Unit tests for `UsageCore` |
| `scripts/` | Build, install and uninstall |
