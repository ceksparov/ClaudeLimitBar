import AppKit

// The top of the menu, drawn as one custom view rather than a stack of menu
// rows.
//
// Menu rows can only really offer one thing: a line of text. Everything that
// makes usage readable at a glance — a filled meter you can judge without
// reading the number, a chart with proportional bars, a clear split between
// the headline figure and its supporting detail — has to be drawn. So the
// display half of the menu is this view, and the parts you can actually click
// (sign in, quit) stay as ordinary menu items below it.
//
// It is drawn in the Windows app's pixel-art idiom: square corners, block
// bars, pixel digits, a fixed near-black surface and hard edges throughout.
// The two apps read the same endpoint and ship from the same tag, and looking
// like one product is most of what makes that legible to anyone using both.
//
// One thing does not carry over. On Windows the panel is a borderless window
// the app owns outright, so it can draw its own heavy square frame. Here it is
// a view inside an NSMenu, which draws its own rounded, translucent chrome
// underneath and would clip any frame's corners. So the panel paints its own
// opaque surface and separates sections with the same dotted rules, but does
// not attempt a border it cannot own the corners of.
struct UsagePanelModel {
    struct Window {
        let title: String
        let percent: Int
        let detail: String
    }

    struct Day {
        let label: String
        let percent: Int?
        let isToday: Bool
    }

    let windows: [Window]
    let days: [Day]
    let weekTotal: Int?
    let unrecorded: Int
}

final class UsagePanelView: NSView {
    private enum Metrics {
        static let width: CGFloat = 320
        static let padX: CGFloat = 16
        static let padTop: CGFloat = 12
        static let padBottom: CGFloat = 14

        // Header: the mascot, and the app's name beside it.
        static let petCell: CGFloat = 2
        static let headerHeight: CGFloat = 34
        static let headerGap: CGFloat = 12

        static let labelRow: CGFloat = 15       // uppercase section label
        // The headline figure has to dominate its own row. Windows draws it
        // about twice the height of the text beside it; matching that ratio
        // matters more than matching the pixel size, since the fonts either
        // side of it are not the same.
        static let percentCell: CGFloat = 4     // pixel-digit cell size
        static let valueRow: CGFloat = 30       // pixel digits plus room beneath
        static let barHeight: CGFloat = 10
        static let barSegments = 20             // one block per 5%
        static let barGap: CGFloat = 2
        static let windowGap: CGFloat = 18

        static let ruleGap: CGFloat = 14
        static let chartHeader: CGFloat = 16
        static let chartValueRow: CGFloat = 12
        static let chartBars: CGFloat = 52
        static let chartLabelRow: CGFloat = 16
        static let unrecordedGap: CGFloat = 8
        static let unrecordedRow: CGFloat = 14
    }

    private var model: UsagePanelModel

    // Segoe UI is what the Windows panel sets its prose in; the nearest thing
    // present on every Mac is the system font. Only labels and reset times use
    // it — the figures are pixel glyphs (see PixelFont).
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .bold)
    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .bold)
    private static let detailFont = NSFont.systemFont(ofSize: 12)
    private static let smallFont = NSFont.systemFont(ofSize: 11)

    // Drawing top-down is far easier to follow than AppKit's default
    // bottom-up origin, and this view is a stack of sections.
    override var isFlipped: Bool { true }

    init(model: UsagePanelModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: 0))
        frame.size.height = Self.height(for: model)
        setAccessibilityLabel(Self.accessibilityLabel(for: model))
    }

    required init?(coder: NSCoder) { nil }

    // Redraws with newer figures without rebuilding the menu around it.
    // Reassigning statusItem.menu is what would close the menu under the
    // user's cursor; repainting a view already inside it doesn't, so an open
    // panel can stay current instead of showing whatever was true when it
    // opened (most visibly "measuring recent usage", which otherwise sits
    // there long after the figure it's waiting for has arrived).
    //
    // Returns false when the new model wouldn't fit the same height — a
    // window appearing or the chart gaining a row would mean resizing a menu
    // that's already on screen, which is the jarring case this is meant to
    // avoid. That redraw waits for the menu to close.
    func update(model: UsagePanelModel) -> Bool {
        guard Self.height(for: model) == frame.size.height else { return false }
        self.model = model
        setAccessibilityLabel(Self.accessibilityLabel(for: model))
        needsDisplay = true
        return true
    }

    private static func height(for model: UsagePanelModel) -> CGFloat {
        var height = Metrics.padTop + Metrics.padBottom
        height += Metrics.headerHeight + Metrics.headerGap

        let block = Metrics.labelRow + Metrics.valueRow + Metrics.barHeight
        height += CGFloat(model.windows.count) * block
        height += CGFloat(max(0, model.windows.count - 1)) * Metrics.windowGap

        if !model.days.isEmpty {
            height += Metrics.windowGap + 2 + Metrics.ruleGap
            height += Metrics.chartHeader + Metrics.chartValueRow + Metrics.chartBars
                + Metrics.chartLabelRow
            if model.unrecorded > 0 { height += Metrics.unrecordedGap + Metrics.unrecordedRow }
        }
        return height
    }

    // A menu item drawn as a custom view is invisible to VoiceOver unless it
    // says what it shows, so the whole panel reads out as one sentence.
    private static func accessibilityLabel(for model: UsagePanelModel) -> String {
        model.windows.map { "\($0.title): \($0.percent) percent. \($0.detail)." }
            .joined(separator: " ")
    }

    override func draw(_ dirtyRect: NSRect) {
        // Pixel art: nothing smoothed, nothing interpolated. Without this the
        // blocks acquire soft grey edges and the whole idiom falls apart.
        NSGraphicsContext.current?.shouldAntialias = false
        NSGraphicsContext.current?.imageInterpolation = .none

        // The menu's own background is translucent and follows the system
        // appearance. Painting over it is what makes the surface the fixed
        // near-black the rest of the palette is built against.
        Palette.panel.setFill()
        bounds.fill()

        let content = NSRect(
            x: Metrics.padX, y: Metrics.padTop,
            width: bounds.width - Metrics.padX * 2, height: bounds.height
        )
        var y = content.minY

        drawHeader(in: content, at: y)
        y += Metrics.headerHeight + Metrics.headerGap

        for (index, window) in model.windows.enumerated() {
            y = drawWindow(window, in: content, at: y)
            if index < model.windows.count - 1 { y += Metrics.windowGap }
        }

        guard !model.days.isEmpty else { return }

        y += Metrics.windowGap
        drawDottedRule(in: content, at: y)
        y += 2 + Metrics.ruleGap

        drawChart(in: content, at: y)
    }

    // MARK: - Sections

    private func drawHeader(in content: NSRect, at top: CGFloat) {
        let petSize = PetSprite.size(cell: Metrics.petCell)
        PetSprite.draw(
            at: NSPoint(x: content.minX, y: top),
            cell: Metrics.petCell, body: Palette.accent, eye: Palette.eye
        )

        draw(
            "CLAUDE USAGE", font: Self.titleFont, color: Palette.text,
            in: NSRect(
                x: content.minX + petSize.width + 10, y: top + 4,
                width: content.width, height: 18
            )
        )
    }

    // A run of pixels rather than a solid rule — a hairline would be the one
    // smooth edge in a panel built entirely from blocks.
    private func drawDottedRule(in content: NSRect, at y: CGFloat) {
        Palette.border.setFill()
        var x = content.minX
        while x < content.maxX {
            NSRect(x: x, y: y, width: 2, height: 2).fill()
            x += 4
        }
    }

    private func drawWindow(
        _ window: UsagePanelModel.Window, in content: NSRect, at top: CGFloat
    ) -> CGFloat {
        var y = top

        draw(
            window.title.uppercased(), font: Self.labelFont, color: Palette.secondary,
            in: NSRect(x: content.minX, y: y, width: content.width, height: Metrics.labelRow)
        )
        y += Metrics.labelRow

        let color = Palette.colorFor(percent: window.percent)
        PixelFont.draw(
            "\(window.percent)%", at: NSPoint(x: content.minX, y: y),
            cell: Metrics.percentCell, color: color
        )

        // The detail sits on the baseline of the pixel digits, right-aligned,
        // exactly as the reset text does on Windows.
        let digitsHeight = PixelFont.height(cell: Metrics.percentCell)
        draw(
            window.detail, font: Self.detailFont, color: Palette.secondary, alignment: .right,
            in: NSRect(
                x: content.minX, y: y + digitsHeight - 16,
                width: content.width, height: 16
            )
        )
        y += Metrics.valueRow

        drawBar(
            percent: window.percent, color: color,
            in: NSRect(x: content.minX, y: y, width: content.width, height: Metrics.barHeight)
        )
        return y + Metrics.barHeight
    }

    // The block bar: no rounded caps, just twenty 5% squares.
    private func drawBar(percent: Int, color: NSColor, in rect: NSRect) {
        let fraction = min(max(Double(percent), 0), 100) / 100
        var filled = Int((Double(Metrics.barSegments) * fraction).rounded())
        // Anything above zero should show something; a bar that reads as empty
        // at 1% is telling the user the wrong thing.
        if percent > 0 && filled == 0 { filled = 1 }

        for index in 0..<Metrics.barSegments {
            // Each block's edges are rounded on their own, or the error
            // accumulates into a visible drift by the right-hand end.
            let left = rect.minX + (rect.width * CGFloat(index) / CGFloat(Metrics.barSegments)).rounded()
            let right = rect.minX
                + (rect.width * CGFloat(index + 1) / CGFloat(Metrics.barSegments)).rounded()

            (index < filled ? color : Palette.channel).setFill()
            NSRect(
                x: left, y: rect.minY,
                width: max(1, right - left - Metrics.barGap), height: rect.height
            ).fill()
        }
    }

    private func drawChart(in content: NSRect, at top: CGFloat) {
        var y = top

        draw(
            "THIS WEEK", font: Self.labelFont, color: Palette.secondary,
            in: NSRect(x: content.minX, y: y, width: content.width, height: Metrics.chartHeader)
        )
        if let weekTotal = model.weekTotal {
            draw(
                "\(weekTotal)% TOTAL", font: Self.labelFont, color: Palette.secondary,
                alignment: .right,
                in: NSRect(x: content.minX, y: y, width: content.width, height: Metrics.chartHeader)
            )
        }
        y += Metrics.chartHeader

        let columnWidth = content.width / CGFloat(max(model.days.count, 1))
        let barWidth = min(24, columnWidth - 8)
        // Bars are scaled against the busiest day rather than against 100%, so
        // a quiet week still shows shape instead of a row of flat stubs.
        let peak = model.days.compactMap(\.percent).max() ?? 0
        let baseline = y + Metrics.chartValueRow + Metrics.chartBars

        for (index, day) in model.days.enumerated() {
            let columnX = content.minX + columnWidth * CGFloat(index)
            let barX = (columnX + (columnWidth - barWidth) / 2).rounded()

            let height = day.percent.map { percent in
                peak > 0 ? max(3, (Metrics.chartBars * CGFloat(percent) / CGFloat(peak)).rounded()) : 3
            } ?? 3

            // A stub in the channel colour for days with nothing recorded: an
            // empty column would read as a measured zero, and an accent one as
            // real usage.
            (day.percent == nil ? Palette.channel : Palette.accent).setFill()
            NSRect(x: barX, y: baseline - height, width: barWidth, height: height).fill()

            draw(
                day.percent.map { "\($0)%" } ?? "–",
                font: Self.smallFont,
                color: day.percent == nil ? Palette.muted : Palette.secondary,
                alignment: .center,
                in: NSRect(
                    x: columnX, y: baseline - height - Metrics.chartValueRow,
                    width: columnWidth, height: Metrics.chartValueRow
                )
            )

            draw(
                day.label.uppercased(),
                font: day.isToday ? Self.labelFont : Self.smallFont,
                color: day.isToday ? Palette.text : Palette.secondary,
                alignment: .center,
                in: NSRect(
                    x: columnX, y: baseline + 4,
                    width: columnWidth, height: Metrics.chartLabelRow
                )
            )
        }
        y = baseline + Metrics.chartLabelRow

        if model.unrecorded > 0 {
            draw(
                "+\(model.unrecorded)% WHILE THE APP WASN'T RUNNING",
                font: Self.smallFont, color: Palette.secondary,
                in: NSRect(
                    x: content.minX, y: y + Metrics.unrecordedGap,
                    width: content.width, height: Metrics.unrecordedRow
                )
            )
        }
    }

    // MARK: - Text

    private func draw(
        _ text: String, font: NSFont, color: NSColor,
        alignment: NSTextAlignment = .left, in rect: NSRect
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        ).draw(in: rect)
    }
}
