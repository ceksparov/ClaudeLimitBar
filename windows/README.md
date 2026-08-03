# ClaudeLimitBar for Windows

The Windows counterpart of the macOS menu bar app: a tray icon that shows your Claude
usage limits without opening claude.ai.

Not affiliated with or endorsed by Anthropic.

## What it shows

- **The pet in the notification area.** Left-click it for a drawn panel listing every
  limit window the API reports — the 5-hour session, the weekly windows, and the
  per-model ones — each with a block bar, a percentage and the time it resets.
- **An optional on-screen overlay.** A small always-on-top pet with a single bar for
  the limit you care about. Drag it anywhere; the position is remembered.
- **A reminder when the 5-hour window hasn't started.** The window only begins on your
  first message, so the app points out that you can start it deliberately and line the
  reset up with the hours you actually plan to work. It is shown once per unused cycle.

## Requirements

- Windows 10 or later
- [.NET 9 SDK](https://dotnet.microsoft.com/download/dotnet/9.0) to build from source
- [Microsoft Edge WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)
  — preinstalled on current Windows 11; the app tells you if it's missing

## Building and running

```bash
cd windows/ClaudeUsage
dotnet build        # compile
dotnet run          # run it — the icon appears in the notification area
```

A self-contained single-file executable:

```bash
dotnet publish -c Release
```

To check the reminder window's layout without waiting for an unused limit cycle:

```bash
dotnet run -- --preview-notification
```

## How it gets your usage data

The app signs you in to claude.ai inside an embedded WebView2 window and keeps that
session in its own WebView2 profile under `%APPDATA%\ClaudeUsage\WebView2`.

Usage comes from the same internal endpoint claude.ai's own usage page calls,
`/api/organizations/{org}/usage`. **This is not an official, documented Anthropic API** —
it's what the browser calls internally, and it can change or break without notice.

The request is issued by `fetch()` **inside the signed-in page itself**, and the result
comes back over WebView2's message bridge. The session cookie is never read into managed
code and never handed to another HTTP client.

Claude Desktop's own installation is left completely alone: nothing is injected into its
process, its `app.asar` is not patched, and its cookie database is never read.

## What it stores

Everything is local, in `%APPDATA%\ClaudeUsage`:

- `settings.json` — refresh interval, overlay position and visibility, whether the
  reminder was already shown for the current cycle, and the last organization UUID that
  worked (so a restart doesn't switch you to a different account). No session key.
- `error.log` — diagnostics, capped at 256 KB.
- `WebView2\` — the browser profile holding the session.

The session cookie lives only in that WebView2 profile. Signing out clears it, along
with the rest of the browsing data for that profile.

"Start with Windows" writes a single value under
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, and removes it when unchecked.

The app sends nothing anywhere except its requests to claude.ai, and has no analytics.

## Layout

```text
windows/ClaudeUsage/
  Program.cs                 entry point, single-instance guard
  TrayAppContext.cs          tray icon, menu, refresh loop
  ClaudeClient.cs            organization discovery and the usage call
  WebViewHost.cs             the persistent WebView2 session and the fetch bridge
  LoginWindow.cs             the sign-in window
  UsageModels.cs             API DTOs, palette, formatting
  UsagePanel.cs              the drawn usage panel
  UsageOverlay.cs            the on-screen overlay
  LimitResetNotification.cs  the unused-window reminder
  PetSprite.cs               the mascot, shared by every surface
  PixelFont.cs               3x5 pixel digits
  TrayIconRenderer.cs        icon drawing plus GDI handle lifetime
  Settings.cs                settings file and the startup registry entry
```
