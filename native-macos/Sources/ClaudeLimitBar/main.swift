// This file is the app's entry point — it's the first thing that runs when
// the program starts (like main() in C/JS, except in Swift, top-level code
// in this file is automatically treated as "main" — no separate func main() needed).

import AppKit

let app = NSApplication.shared

let delegate = AppDelegate()
app.delegate = delegate

// This line puts the program into an indefinite run loop: it waits here
// until the user clicks the menu bar icon, until time passes, etc. — this
// is what keeps the program running.
app.run()
