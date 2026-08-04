import AppKit

// The mascot, carried over pixel for pixel from the Windows app.
//
// One source of truth for both places it appears — the panel header and the
// menu bar icon — so the two can never drift apart.
enum PetSprite {
    // A 16x11 map. "X" is body, "O" is eye, "." is transparent.
    static let rows = [
        "..XXXXXXXXXXXX..",
        "..XXXXXXXXXXXX..",
        "..XXOXXXXXXOXX..",
        "..XXOXXXXXXOXX..",
        "XXXXXXXXXXXXXXXX",
        "XXXXXXXXXXXXXXXX",
        "..XXXXXXXXXXXX..",
        "..XXXXXXXXXXXX..",
        "..XXXXXXXXXXXX..",
        "...X.X....X.X...",
        "...X.X....X.X...",
    ]

    static let columns = 16
    static let lines = 11

    static func size(cell: CGFloat) -> NSSize {
        NSSize(width: CGFloat(columns) * cell, height: CGFloat(lines) * cell)
    }

    // Draws top-down from (x, y); the panel view is flipped, so this matches
    // how everything else in it is placed.
    static func draw(at point: NSPoint, cell: CGFloat, body: NSColor, eye: NSColor) {
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, pixel) in row.enumerated() where pixel != "." {
                (pixel == "O" ? eye : body).setFill()
                NSRect(
                    x: point.x + CGFloat(columnIndex) * cell,
                    y: point.y + CGFloat(rowIndex) * cell,
                    width: cell, height: cell
                ).fill()
            }
        }
    }

    // The menu bar wants an image, not a draw call. Sized in points; AppKit
    // renders it at whatever backing scale the display has, and nearest-
    // neighbour keeps the blocks hard-edged rather than blurring them.
    static func image(cell: CGFloat, body: NSColor, eye: NSColor) -> NSImage {
        let size = size(cell: cell)
        let image = NSImage(size: size, flipped: true) { _ in
            NSGraphicsContext.current?.imageInterpolation = .none
            NSGraphicsContext.current?.shouldAntialias = false
            draw(at: .zero, cell: cell, body: body, eye: eye)
            return true
        }
        // Not a template image: a template is recoloured by the system to a
        // flat black or white, which would throw away the one thing the
        // mascot carries — its colour. The trade is that it no longer inverts
        // with the menu bar's appearance, which is the price of matching
        // Windows.
        image.isTemplate = false
        return image
    }
}
