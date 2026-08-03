# ClaudeLimitBar

A macOS menu bar app that shows your Claude usage limits (current session and
weekly) at a glance — no need to open claude.ai to check.

Not affiliated with or endorsed by Anthropic.

There is a Windows tray app with the same idea in [`windows/`](windows/) — it is a
separate codebase with its own README. The rest of this file describes the macOS app,
which lives in [`macos/`](macos/).

## What it shows

- **Both limit windows** — the 5-hour session and the weekly one, each with a
  meter and the exact time it resets.
- **Recent activity** — how much of the session window the last few minutes
  cost. The period shown stretches between 5 and 20 minutes to match however
  long the usage actually spans, so "+4% last 12 min" means it really did take
  twelve minutes.
- **Today** — the share of your weekly quota spent since midnight.
- **This week, by day** — a chart of the running weekly window, one bar per
  day. Days are measured as a share of the weekly quota, so the bars add up to
  the weekly figure shown above them.

Where a figure can't be worked out honestly — not enough history yet, or usage
that appeared while nothing was recording — the app says so rather than
showing a number it can't stand behind.

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
cd macos
./build-app.sh        # produces ClaudeLimitBar.app
./build-app.sh --zip   # also produces a distributable .zip
```

For the Windows app, see [windows/README.md](windows/README.md).

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

## What it stores

- **Your session key** goes in the macOS Keychain, and nowhere else. It is
  never logged or written to disk in plain text.
- **A small usage record** is kept in the app's own preferences so the daily
  chart survives restarts: one entry per day, holding a date and a
  percentage. Nothing identifying, and no message content — the app never
  sees your conversations.

Both are local to your Mac. The app sends nothing anywhere except its
requests to claude.ai, and it has no analytics of any kind.

Signing out clears the session key; signing in as a different account also
clears the stored usage record, so one account's history never shows up
under another's.

## Contributing

Bug reports, feature requests, and PRs are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md) for how the project is laid out, how to
build and test it, and the code style it follows. Adding a new language is
one of the most useful things you could contribute (see the note in there).

## License

MIT — see [LICENSE](LICENSE).
