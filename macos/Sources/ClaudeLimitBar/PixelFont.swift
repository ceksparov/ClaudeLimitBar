import AppKit

// 3x5 pixel digits, the same glyph table the Windows app draws from.
//
// Percentages are built from blocks rather than set in a system font for the
// same reason the bars are square: a pixel-art panel stops reading as one the
// moment its largest element is a smoothly antialiased typeface. Only the
// headline figures use this — labels and reset times stay in the system font,
// exactly as on Windows, because five-pixel-tall prose is unreadable.
enum PixelFont {
    private static let glyphWidth = 3
    private static let glyphHeight = 5
    private static let spacing = 1  // letter spacing, in cells

    private static let glyphs: [Character: [String]] = [
        "0": ["XXX", "X.X", "X.X", "X.X", "XXX"],
        "1": ["..X", "..X", "..X", "..X", "..X"],
        "2": ["XXX", "..X", "XXX", "X..", "XXX"],
        "3": ["XXX", "..X", "XXX", "..X", "XXX"],
        "4": ["X.X", "X.X", "XXX", "..X", "..X"],
        "5": ["XXX", "X..", "XXX", "..X", "XXX"],
        "6": ["XXX", "X..", "XXX", "X.X", "XXX"],
        "7": ["XXX", "..X", "..X", "..X", "..X"],
        "8": ["XXX", "X.X", "XXX", "X.X", "XXX"],
        "9": ["XXX", "X.X", "XXX", "..X", "XXX"],
        "%": ["X.X", "..X", ".X.", "X..", "X.X"],
        ".": ["...", "...", "...", "...", "..X"],
        ",": ["...", "...", "...", "..X", ".X."],
        "$": [".X.", "XXX", "XX.", ".XX", "XXX"],
        "+": ["...", ".X.", "XXX", ".X.", "..."],
        "-": ["...", "...", "XXX", "...", "..."],
        " ": ["...", "...", "...", "...", "..."],
    ]

    static func height(cell: CGFloat) -> CGFloat { CGFloat(glyphHeight) * cell }

    static func width(_ text: String, cell: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let count = CGFloat(text.count)
        return count * CGFloat(glyphWidth) * cell + (count - 1) * CGFloat(spacing) * cell
    }

    // Draws top-down from (x, y), which is why the view this lives in is
    // flipped. An unknown character advances the cursor without drawing, so a
    // string the table doesn't fully cover still lines up.
    static func draw(_ text: String, at point: NSPoint, cell: CGFloat, color: NSColor) {
        color.setFill()
        var cursor = point.x

        for character in text {
            guard let glyph = glyphs[character] else {
                cursor += CGFloat(glyphWidth + spacing) * cell
                continue
            }

            for (rowIndex, row) in glyph.enumerated() {
                for (columnIndex, pixel) in row.enumerated() where pixel == "X" {
                    NSRect(
                        x: cursor + CGFloat(columnIndex) * cell,
                        y: point.y + CGFloat(rowIndex) * cell,
                        width: cell, height: cell
                    ).fill()
                }
            }

            cursor += CGFloat(glyphWidth + spacing) * cell
        }
    }
}
