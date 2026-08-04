import AppKit

// The colours the panel is drawn in, carried over from the Windows app so the
// two look like one product rather than two apps that read the same endpoint.
//
// Fixed, not derived from the system's semantic colours. Those adapt to light
// and dark mode, which is the right default for a native panel and the wrong
// one here: this is a deliberate pixel-art idiom, and half of what makes it
// read as one is that the surface underneath is always the same near-black.
// A light-mode variant would be a different look wearing the same shapes.
enum Palette {
    static let background = NSColor(hex: 0x151318)
    static let panel = NSColor(hex: 0x211E24)
    static let border = NSColor(hex: 0x37323B)
    static let text = NSColor(hex: 0xF4F0EC)
    static let muted = NSColor(hex: 0xAAA2AD)

    // Not from the Windows palette — the one colour here that isn't.
    //
    // Windows has a wide gap between `text` and `muted`, and puts everything
    // that isn't a headline figure in `muted`. That works there because its
    // panel sets prose at 8pt on a surface it owns outright. On a Retina menu
    // bar the same grey at a readable size reads as disabled, and the line it
    // renders — the reset time and what the last few minutes cost — is the
    // second most useful thing in the panel, not an aside.
    static let secondary = NSColor(hex: 0xD8D2DB)
    static let accent = NSColor(hex: 0xD67756)
    static let eye = NSColor(hex: 0x000000)

    static let ok = NSColor(hex: 0x58BD88)
    static let warn = NSColor(hex: 0xE4AA43)
    static let bad = NSColor(hex: 0xE35F64)

    // The unfilled part of a bar. Distinct from the panel behind it, or a bar
    // at 0% would be invisible rather than empty.
    static let channel = NSColor(hex: 0x39343E)

    // Thresholds match the Windows app's ColorFor exactly. Somebody running
    // both should never see the same percentage in two different colours.
    static func colorFor(percent: Int) -> NSColor {
        switch percent {
        case ..<50: return ok
        case ..<80: return warn
        default: return bad
        }
    }
}

extension NSColor {
    // The palette is written as hex because that is how it is written on the
    // Windows side too — keeping both in the same notation is what makes it
    // obvious at a glance that they haven't drifted apart.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
