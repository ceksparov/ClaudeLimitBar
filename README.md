# ClaudeLimitBar

Your Claude usage limits (current session and weekly) at a glance, without
opening claude.ai to check — in the macOS menu bar, or the Windows
notification area.

Not affiliated with or endorsed by Anthropic.

Each platform is its own native app, written against its own toolkit and
sharing no code with the other: [`macos/`](macos/) is Swift and AppKit,
[`windows/`](windows/) is C# and WinForms. They read the same endpoint and are
released together from the same tag, so a given version means the same thing on
both. The Windows app has [its own README](windows/README.md) covering what is
specific to it.

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

The Windows app adds a couple of things of its own — an optional always-on-top
overlay and a reminder when the 5-hour window hasn't been started yet. See
[windows/README.md](windows/README.md).

## Install

Every release carries a zip per platform. Take the one matching your machine
from [Releases](../../releases): `…-macos.zip` or `…-windows.zip`.

### macOS

Requires macOS 13 or later.

1. Unzip and drag `ClaudeLimitBar.app` to `/Applications`.
2. **First launch**: macOS will warn that the developer can't be verified —
   the app is signed, but not with a paid Apple Developer certificate, so it
   isn't notarized. Either:
   - Control-click the app → **Open**, or
   - go to **System Settings → Privacy & Security** and click **Open Anyway**
     next to the blocked-app message.

   You only need to do this once.
3. Click the menu bar icon → **Sign In with Claude…**.

### Windows

Requires Windows 10 or later, and the
[Microsoft Edge WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)
— already present on current Windows 11; the app tells you if it's missing.

1. Unzip and put `ClaudeUsage.exe` wherever you keep such things. Nothing is
   installed and no .NET runtime is needed; it is a single self-contained
   executable.
2. **First launch**: SmartScreen will show "Windows protected your PC", for the
   same reason as above — the executable isn't signed with a paid code-signing
   certificate. Click **More info** → **Run anyway**.
3. Right-click the tray icon → **Sign in**.

Neither warning means anything is wrong with the download; both say the same
thing, which is that nobody has paid a certificate authority to vouch for it.
If you'd rather not take that on trust, build from source — the instructions
are below and neither app has meaningful dependencies.

## Building from source

```bash
cd macos
./build-app.sh         # produces ClaudeLimitBar.app
./build-app.sh --zip   # also produces a distributable .zip
```

```bash
cd windows/ClaudeUsage
dotnet build           # compile
dotnet run             # run it — the icon appears in the notification area
dotnet publish -c Release   # a self-contained single-file executable
```

## How it gets your usage data

Both apps read the same internal endpoint claude.ai's own web usage page uses
(`/api/organizations/{org}/usage`). **This is not an official, documented
Anthropic API** — it's what the browser calls internally, and it can change or
break without notice.

They reach it differently, because each platform's easiest honest route
differs:

- **macOS** sends the request itself, carrying the session key from the
  Keychain. To get past claude.ai's bot-detection layer it uses a normal
  browser User-Agent string. If this ever gets your account rate-limited or
  flagged, that's why — use at your own judgment.
- **Windows** issues the request with `fetch()` inside the signed-in WebView2
  page itself and reads the result back over the message bridge, so the session
  cookie never leaves the browser profile.

When macOS can't reach the API, it falls back to the local usage history file
the official Claude desktop app writes to
`~/Library/Application Support/Claude/plan-usage-history.json` and estimates
reset times from it. That file is only written while that app is running, so it
can be hours old — the menu says where the figures came from and how old they
are.

Neither app touches Claude Desktop's own installation: nothing is injected into
its process, its `app.asar` is not patched, and its cookie database is never
read.

## What it stores

Everything is local to your machine. Neither app sends anything anywhere except
its requests to claude.ai, and neither has analytics of any kind.

**Your credentials never leave the operating system's own keystore.** On macOS
the session key goes in the Keychain and nowhere else; on Windows the session
stays inside the app's WebView2 profile under `%APPDATA%\ClaudeUsage\WebView2`
and is never read into the app's own code. Neither is ever logged or written to
disk in the clear.

Alongside that, each keeps a small record so the display survives a restart: a
date and a percentage per day, plus preferences like refresh interval and
window position. Nothing identifying, and no message content — neither app ever
sees your conversations.

Signing out clears the session. On macOS, signing in as a different account
also clears the stored usage record, so one account's history never shows up
under another's.

## Contributing

Bug reports, feature requests, and PRs are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md) for how the project is laid out, how to
build and test it, and the code style it follows. Adding a new language is
one of the most useful things you could contribute (see the note in there).

## License

MIT — see [LICENSE](LICENSE).
