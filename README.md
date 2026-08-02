# ClaudeLimitBar

A macOS menu bar app that shows your Claude usage limits (current session and
weekly) at a glance — no need to open claude.ai to check.

Not affiliated with or endorsed by Anthropic.

## Requirements

- macOS 13 or later

## Install

1. Download the latest `.zip` from [Releases](../../releases), unzip it, and
   drag `ClaudeLimitBar.app` to `/Applications`.
2. **First launch**: macOS will likely warn that the developer can't be
   verified (this app isn't notarized by Apple). Either:
   - Control-click the app → **Open**, or
   - go to **System Settings → Privacy & Security** and click **Open Anyway**
     next to the blocked-app message.

   You only need to do this once.
3. Click the menu bar icon → **Sign In with Claude…**.

## Building from source

```bash
cd native-macos
./build-app.sh        # produces ClaudeLimitBar.app
./build-app.sh --zip   # also produces a distributable .zip
```

## How it gets your usage data

- **Signed in**: the app talks to the same internal endpoint claude.ai's own
  web usage page uses (`/api/organizations/{org}/usage`). **This is not an
  official, documented Anthropic API** — it's what the browser calls
  internally, and it can change or break without notice. To get past
  claude.ai's bot-detection layer, requests are sent with a normal browser
  User-Agent string. If this ever gets your account rate-limited or flagged,
  that's why — use at your own judgment.
- **Not signed in / API unreachable**: falls back to reading the local usage
  history file the official Claude desktop app writes to
  `~/Library/Application Support/Claude/plan-usage-history.json`, and
  estimates reset times from it.

Your session key is stored only in the macOS Keychain, never logged or
written to disk in plain text.

## License

MIT — see [LICENSE](LICENSE).
