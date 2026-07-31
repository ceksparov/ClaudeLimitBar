import AppKit

func colorFor(_ pct: Int) -> NSColor {
    if pct >= 80 { return NSColor(red: 1.00, green: 0.231, blue: 0.188, alpha: 1) } // #ff3b30
    if pct >= 50 { return NSColor(red: 1.00, green: 0.624, blue: 0.039, alpha: 1) } // #ff9f0a
    return NSColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1) // #30d158
}

let grayText = NSColor.secondaryLabelColor
let warningColor = NSColor(red: 1.00, green: 0.624, blue: 0.039, alpha: 1) // #ff9f0a

func attributed(_ text: String, color: NSColor, small: Bool = false) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .foregroundColor: color,
        .font: NSFont.menuFont(ofSize: small ? 11 : NSFont.systemFontSize),
    ])
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.image = NSImage(
            systemSymbolName: "bolt.fill", accessibilityDescription: "Claude Kullanım"
        )
        statusItem.button?.imagePosition = .imageLeading
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let now = Date().timeIntervalSince1970 * 1000
        do {
            let samples = try loadHistory()
            renderUsage(samples: samples, now: now)
        } catch {
            renderError(error)
        }
    }

    private func renderUsage(samples: [RawSample], now: Double) {
        let last = samples[samples.count - 1]
        let age = now - last.t
        let stale = age > staleMs
        let headline = last.u[keyPath: limits[0].key]

        statusItem.button?.attributedTitle = attributed(
            " %\(headline)", color: stale ? .disabledControlTextColor : colorFor(headline)
        )

        let menu = NSMenu()
        menu.addItem(withTitle: "Claude Kullanım Limitleri", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        for limit in limits {
            let pct = last.u[keyPath: limit.key]
            let resetAt = estimateReset(samples: samples, key: limit.key, windowMs: limit.windowMs, now: now)
            let reset = resetLabel(pct: pct, resetAt: resetAt, now: now)

            let pctItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            pctItem.attributedTitle = attributed("\(limit.label): %\(pct)", color: colorFor(pct))
            menu.addItem(pctItem)

            let resetItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            resetItem.attributedTitle = attributed("   Sıfırlanma (tahmini): \(reset)", color: grayText, small: true)
            menu.addItem(resetItem)
        }

        menu.addItem(.separator())
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        let clockStr = clock.string(from: Date(timeIntervalSince1970: last.t / 1000))
        let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        updatedItem.attributedTitle = attributed(
            "Veri: \(clockStr) (\(formatDuration(age)) önce)", color: grayText, small: true
        )
        menu.addItem(updatedItem)

        if stale {
            let warnItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            warnItem.attributedTitle = attributed(
                "⚠️ Veri bayat — Claude uygulaması kapalı olabilir", color: warningColor, small: true
            )
            menu.addItem(warnItem)
        }

        appendFooter(to: menu)
        statusItem.menu = menu
    }

    private func renderError(_ error: Error) {
        statusItem.button?.attributedTitle = attributed(" N/A", color: .disabledControlTextColor)

        let menu = NSMenu()
        menu.addItem(withTitle: "Claude kullanım verisi okunamadı", action: nil, keyEquivalent: "")
        let errItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errItem.attributedTitle = attributed("Hata: \(error.localizedDescription)", color: grayText, small: true)
        menu.addItem(errItem)
        menu.addItem(withTitle: "Claude masaüstü uygulamasının kurulu ve en az bir kez açılmış olması gerekir",
                     action: nil, keyEquivalent: "")
        appendFooter(to: menu)
        statusItem.menu = menu
    }

    private func appendFooter(to menu: NSMenu) {
        menu.addItem(.separator())
        let openItem = NSMenuItem(title: "Claude'u Aç", action: #selector(openClaude), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openClaude() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude.app"))
        }
    }
}
