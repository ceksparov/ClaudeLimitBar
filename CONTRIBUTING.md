# Contributing to ClaudeLimitBar

Thanks for considering it — this started as a small personal tool, so there's plenty of room to make it better.

## Ways to help

- **Report a bug** — open an issue with the bug report template.
- **Suggest a feature** — open an issue with the feature request template.
- **Fix something / build a feature** — see below.
- **Add a language** — there's no localization infrastructure yet (all
  text is plain English strings in the Swift source). If you'd like to add
  one, open an issue first so we can agree on the approach (most likely
  Apple's String Catalog format, since the project already targets macOS 13+).

## Project layout

```
native-macos/
  Sources/ClaudeLimitBar/   the app itself
  Tests/ClaudeLimitBarTests/ unit tests for the pure logic (no UI tests)
  Resources/                 app icon
  build-app.sh               packages the built binary into a .app
menubar/
  claude-usage.10s.js         an older xbar/SwiftBar plugin with the same idea,
                               kept for anyone who prefers it over a native app
```

The native app has no third-party dependencies — just Foundation, AppKit,
WebKit, Security, and ServiceManagement.

## Building and running

```bash
cd native-macos
swift build              # compile
swift run                 # run directly (no app icon, no "Start at Login" option — see below)
./build-app.sh            # produce a real ClaudeLimitBar.app you can double-click
```

`SMAppService` (the "Start at Login" toggle) only works from inside a real
`.app` bundle, and the icon only shows up once packaged — so if you're
touching either of those, test with `./build-app.sh` and running the
resulting `.app`, not `swift run`.

## Tests

```bash
cd native-macos
swift test
```

Coverage right now is limited to the pure calculation logic in
`UsageData.swift` and `UsageAPI.parseTimestamp` — the stuff that's actually
practical to unit test without a running UI. If you add a new pure
function, a test for it is welcome. UI behavior (the menu, the login
window) is verified by hand for now.

## Code style

- **English only** — every comment, log message, and user-facing string.
  No exceptions, including in commit messages.
- **Comment the *why*, not the *what***. If a line of code is
  self-explanatory, it doesn't need a comment; if a choice looks odd
  without context (a workaround, an ordering that matters, an edge case
  that bit us before), that context is worth writing down.
- Match the formatting already in the file you're editing rather than
  introducing a new style.

## Submitting a change

1. Fork the repo and create a branch off `main`.
2. Make your change, following the style above.
3. Run `swift test` and actually launch the app to check the part you touched.
4. Open a pull request describing what changed and why (the "why" matters
   more than the "what" — the diff already shows what changed).

Small, focused PRs are easier to review than one that touches five things at once.
