# claude-usage-widget

Your Claude 5-hour and 7-day usage as two small rings on the Windows 11 taskbar. Click them for a list of every account you've set up.

```
taskbar:   (11) 5h  (30) 7d

click:     Claude usage                       ⟳
           Updated 11:46 · every 30 min
           Personal  Max 20x
             5h ██████████████░░░░  76%   in 3m
             7d ████████░░░░░░░░░░  43%   Wed 13:00
           Njord  Max 5x              on taskbar
             5h ██░░░░░░░░░░░░░░░░  11%   in 4h 42m
             7d █████░░░░░░░░░░░░░  30%   Mon 00:00
```

- Rings turn green, amber at 70% and red at 90%. Hover them for reset times.
- The numbers refresh every 30 minutes, when you click ⟳, or from the right-click menu. After the PC wakes from sleep they catch up within a minute.
- The widget hides while a full-screen app is in front.
- It's plain PowerShell and WPF, so there's nothing to install or build. It runs on the Windows PowerShell 5.1 that ships with Windows.

## Install

```powershell
git clone https://github.com/mrcsXndr/claude-usage-widget
cd claude-usage-widget
wscript launch.vbs
```

Then right-click the rings and tick **Start with Windows**.

Hold **Ctrl** and drag the rings to move them along the taskbar. The position is remembered. The widget is a small always-on-top window that sits on the taskbar, because Windows 11 has no taskbar toolbars or deskbands any more. It works the same with the stock taskbar and with Start11. It uses the primary screen's taskbar, at the bottom or the top.

## Accounts

The first run writes `%APPDATA%\claude-usage-widget\config.json`. Right-click the rings and choose **Edit accounts…** to open it. Changes are picked up on the next refresh.

```json
{
  "refreshMinutes": 30,
  "accounts": [
    { "name": "personal", "label": "Personal", "plan": "Max 20x", "source": "xndr-claude" },
    { "name": "claude-code", "label": "Claude Code login", "source": "claude-code" },
    { "name": "work", "label": "Work", "source": "command", "command": "op read op://Private/claude-work/token" },
    { "name": "ci", "label": "CI", "source": "env", "env": "CLAUDE_CI_TOKEN" }
  ]
}
```

Each account says where its token comes from:

| `source` | Token |
| --- | --- |
| `xndr-claude` | `xndr-claude token <name>` from [xndr-claude](https://github.com/mrcsXndr/xndr-claude). Set `"account"` if the name there is different. |
| `claude-code` | Claude Code's own login in `~/.claude/.credentials.json` (or `%CLAUDE_CONFIG_DIR%`). The widget only reads it and never refreshes it, because a refresh would log Claude Code out. When it expires, running `claude` renews it. |
| `command` | Whatever the command prints to stdout, for example a password manager CLI. It runs through `cmd /c`. |
| `env` | An environment variable. |

If [xndr-claude](https://github.com/mrcsXndr/xndr-claude) is installed, the first run imports its accounts. That runs `xndr-claude usage --json` once, which sends one probe per account (see below). A Claude Code login is also added when it's current, or when nothing else was found.

The account on the taskbar is the one you last clicked in the list. Until you click one, it's the account xndr-claude last launched, or the first account. Right-click the rings and choose **Show last-used account** to go back to that default.

## How usage is read

There are two ways, and each account tries the free one first:

1. **Usage API (free).** `GET https://api.anthropic.com/api/oauth/usage` returns `five_hour` and `seven_day` utilization and reset times. It needs a token with the `user:profile` scope, which is what `claude login` gives Claude Code.
2. **Probe (a few tokens).** A request to Haiku with `max_tokens: 1`. The reply carries the same numbers in its `anthropic-ratelimit-unified-5h-*` / `-7d-*` headers, even when the reply is a 429. Tokens from `claude setup-token` are inference-only and get a 403 from the usage API ([anthropics/claude-code#81015](https://github.com/anthropics/claude-code/issues/81015), closed as not planned), so the probe is the only way to read them. It costs about a dozen input tokens and one output token per account per refresh.

When the usage API answers with a scope error, that account uses the probe for the rest of the session. If the usage API returns a 429 (it rate-limits hard), that one refresh uses the probe instead. Hover an account in the list to see which method it used.

## Privacy

- Tokens stay in memory only for the one request. They're never written to disk, logged, shown or passed as a command-line argument. A failing token command reports its stderr only, never its stdout.
- Requests go only to `api.anthropic.com`.
- `-Once` prints usage as JSON with no UI, which is useful for scripts and debugging. The output never includes tokens:

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .\ClaudeUsageWidget.ps1 -Once
  ```

## Files

| Path | What |
| --- | --- |
| `ClaudeUsageWidget.ps1` | The widget (WPF) |
| `lib/Usage.ps1` | Config, token sources and the usage API / probe calls, with no UI |
| `launch.vbs` | Starts the widget without a console window. **Start with Windows** points at it. |
| `%APPDATA%\claude-usage-widget\` | `config.json` (accounts), `state.json` (position and pinned account), `widget.log` (errors) |

## Uninstall

Right-click the rings, untick **Start with Windows**, then choose **Exit**. Delete the folder and `%APPDATA%\claude-usage-widget`.

## License

MIT
