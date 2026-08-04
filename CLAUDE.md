# ClaudeLimitBar

A menu bar / tray app showing Claude usage limits (5-hour session + weekly
windows). Two independent native apps, one per platform, sharing nothing but
the idea and the endpoint they read.

Not affiliated with or endorsed by Anthropic.

## Layout

```
macos/     Swift + AppKit, macOS 13+. No third-party dependencies —
           Foundation, AppKit, WebKit, Security, ServiceManagement.
  Sources/ClaudeLimitBar/      the app
  Tests/ClaudeLimitBarTests/   unit tests for the pure logic (no UI tests)
  build-app.sh                 packages the built binary into a .app
  menubar/                     an older xbar/SwiftBar plugin, kept as-is

windows/   .NET 9 WinForms tray app. Only dependency is Microsoft.Web.WebView2.
  ClaudeUsage/
```

The two folders are deliberately separate so neither platform has to touch the
other's files. A change to one should not appear in a diff for the other.

## Build and test

```bash
cd macos
swift build && swift test    # 79 tests, all pure logic
./build-app.sh               # a real .app you can double-click
```

```bash
cd windows/ClaudeUsage
dotnet build && dotnet run
```

`SMAppService` ("Start at Login") and the app icon only work from inside a real
`.app` bundle, so test those with `./build-app.sh` rather than `swift run`.

## Where the data comes from

Both apps read `/api/organizations/{org}/usage` — the endpoint claude.ai's own
usage page calls. **It is not documented or supported by Anthropic** and can
change without notice. macOS falls back to the Claude desktop app's local
history file (`~/Library/Application Support/Claude/plan-usage-history.json`)
when the API is unreachable; that file is only written while that app is
running, so it can be hours stale.

Credentials never leave the OS keystore: macOS keeps the session key in the
Keychain, Windows keeps the login inside WebView2's own profile. Neither writes
it to disk in the clear, and neither is ever logged.

## Conventions

- **English only** — every comment, log line, user-facing string and commit
  message. No exceptions.
- **Comment the *why*, not the *what*.** Self-evident lines need no comment; a
  choice that looks odd without context (a workaround, an ordering that
  matters, an edge case that bit us) is worth writing down. Most comments in
  this codebase explain a decision, and new ones should too.
- Match the formatting already in the file you are editing.
- Prefer a figure the app can stand behind over one it cannot. Where usage
  can't be worked out honestly, the UI says so instead of showing a number —
  keep that property when changing the calculations.

## Working on this repo

`main` is protected: no direct pushes, no force pushes, CI must pass, and a
pull request is required. Branch from an up-to-date `main`, open a PR, let
`test` and `build` go green, then merge.

Two people work here — macOS and Windows are owned separately — so a branch cut
days ago may sit well behind `main`. Sync before assuming a conflict is real:
GitHub reports the folder rename in this repo's history as a conflict more
readily than `git merge` actually hits one.

## Releases

Pushing a tag `vX.Y.Z` builds both platforms and publishes one GitHub Release
carrying a zip for each. The tag is the only place a version is written —
`build-app.sh` derives it and falls back to `0.0.0` outside a tagged build.
Never reintroduce a hardcoded version; that is exactly how a release ends up
titled one number while the app inside it reports another.
