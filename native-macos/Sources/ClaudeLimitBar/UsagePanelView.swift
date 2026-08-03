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
        static let width: CGFloat = 296
        static let padX: CGFloat = 16
        static let padTop: CGFloat = 10
        static let padBottom: CGFloat = 12

        static let headlineRow: CGFloat = 22
        static let meterHeight: CGFloat = 6
        static let meterGap: CGFloat = 7
        static let detailRow: CGFloat = 16
        static let windowGap: CGFloat = 14

        static let dividerGap: CGFloat = 12
        static let chartHeader: CGFloat = 18
        static let chartValueRow: CGFloat = 13
        static let chartBars: CGFloat = 54
        // Includes the gap between a bar's foot and its weekday label.
        static let chartLabelRow: CGFloat = 18
        static let unrecordedGap: CGFloat = 6
        static let unrecordedRow: CGFloat = 16
    }

    private var model: UsagePanelModel

    // Supporting lines sit between the system's secondary and primary label
    // colours. Plain secondaryLabelColor is tuned for text on an opaque
    // surface; over a menu's translucent background at this size it washes
    // out to the point of being hard to read, which is exactly what these
    // lines must not be — they carry the reset time and the recent figures.
    private var detailColor: NSColor {
        NSColor.labelColor.withAlphaComponent(0.75)
    }

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

        let block = Metrics.headlineRow + Metrics.meterGap + Metrics.meterHeight
            + Metrics.meterGap + Metrics.detailRow
        height += CGFloat(model.windows.count) * block
        height += CGFloat(max(0, model.windows.count - 1)) * Metrics.windowGap

        if !model.days.isEmpty {
            height += Metrics.windowGap + 1 + Metrics.dividerGap
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
        let content = NSRect(
            x: Metrics.padX, y: Metrics.padTop,
            width: bounds.width - Metrics.padX * 2, height: bounds.height
        )
        var y = content.minY

        for (index, window) in model.windows.enumerated() {
            y = drawWindow(window, in: content, at: y)
            if index < model.windows.count - 1 { y += Metrics.windowGap }
        }

        guard !model.days.isEmpty else { return }

        y += Metrics.windowGap
        NSColor.separatorColor.setFill()
        NSRect(x: content.minX, y: y, width: content.width, height: 1).fill()
        y += 1 + Metrics.dividerGap

        drawChart(in: content, at: y)
    }

    // MARK: - Sections

    private func drawWindow(_ window: UsagePanelModel.Window, in content: NSRect, at top: CGFloat) -> CGFloat {
        var y = top

        draw(
            window.title, font: .systemFont(ofSize: 12, weight: .medium), color: .labelColor,
            in: NSRect(x: content.minX, y: y + 3, width: content.width, height: Metrics.headlineRow)
        )
        draw(
            "\(window.percent)%", font: .systemFont(ofSize: 17, weight: .semibold),
            color: colorFor(window.percent), alignment: .right,
            in: NSRect(x: content.minX, y: y, width: content.width, height: Metrics.headlineRow)
        )
        y += Metrics.headlineRow + Metrics.meterGap

        drawMeter(
            percent: window.percent,
            in: NSRect(x: content.minX, y: y, width: content.width, height: Metrics.meterHeight)
        )
        y += Metrics.meterHeight + Metrics.meterGap

        draw(
            window.detail, font: .systemFont(ofSize: 12), color: detailColor,
            in: NSRect(x: content.minX, y: y, width: content.width, height: Metrics.detailRow)
        )
        return y + Metrics.detailRow
    }

    private func drawMeter(percent: Int, in rect: NSRect) {
        let radius = rect.height / 2

        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        // A sliver of fill for any non-zero value: a meter that reads as
        // completely empty at 1% is telling the user the wrong thing.
        let fraction = min(max(Double(percent) / 100, 0), 1)
        guard fraction > 0 else { return }
        let filled = max(rect.height, rect.width * fraction)

        colorFor(percent).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX, y: rect.minY, width: filled, height: rect.height),
            xRadius: radius, yRadius: radius
        ).fill()
    }

    private func drawChart(in content: NSRect, at top: CGFloat) {
        var y = top

        draw(
            "This week", font: .systemFont(ofSize: 12, weight: .medium), color: .labelColor,
            in: NSRect(x: content.minX, y: y, width: content.width, height: Metrics.chartHeader)
        )
        if let weekTotal = model.weekTotal {
            draw(
                "\(weekTotal)% total", font: .systemFont(ofSize: 12), color: detailColor,
                alignment: .right,
                in: NSRect(x: content.minX, y: y + 1, width: content.width, height: Metrics.chartHeader)
            )
        }
        y += Metrics.chartHeader

        let columnWidth = content.width / CGFloat(max(model.days.count, 1))
        let barWidth = min(22, columnWidth - 10)
        // Bars are scaled against the busiest day rather than against 100%,
        // so a quiet week still shows shape instead of four flat stubs.
        let peak = model.days.compactMap(\.percent).max() ?? 0

        let baseline = y + Metrics.chartValueRow + Metrics.chartBars

        for (index, day) in model.days.enumerated() {
            let columnX = content.minX + columnWidth * CGFloat(index)
            let barX = columnX + (columnWidth - barWidth) / 2

            // A stub of a bar for days with nothing recorded, in the muted
            // track colour rather than the accent: an empty column would read
            // as a measured zero, and a coloured one as real usage.
            let height = day.percent.map { percent in
                peak > 0 ? max(3, Metrics.chartBars * CGFloat(percent) / CGFloat(peak)) : 3
            } ?? 3
            let bar = NSRect(x: barX, y: baseline - height, width: barWidth, height: height)

            // The accent colour, not the green/amber/red scale used above:
            // those say "how close to the limit", which a single day isn't.
            (day.percent == nil ? NSColor.quaternaryLabelColor : NSColor.controlAccentColor).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()

            // Sitting the value on top of its own bar rather than on a shared
            // row keeps short bars from floating far below their number.
            draw(
                day.percent.map { "\($0)%" } ?? "–",
                font: .systemFont(ofSize: 11, weight: .medium),
                color: day.percent == nil ? .tertiaryLabelColor : detailColor,
                alignment: .center,
                in: NSRect(
                    x: columnX, y: bar.minY - Metrics.chartValueRow,
                    width: columnWidth, height: Metrics.chartValueRow
                )
            )
            drawDayLabel(day, columnX: columnX, columnWidth: columnWidth, y: y)
        }
        y += Metrics.chartValueRow + Metrics.chartBars + Metrics.chartLabelRow

        if model.unrecorded > 0 {
            draw(
                "+\(model.unrecorded)% while the app wasn't running",
                font: .systemFont(ofSize: 11), color: .secondaryLabelColor,
                in: NSRect(
                    x: content.minX, y: y + Metrics.unrecordedGap,
                    width: content.width, height: Metrics.unrecordedRow
                )
            )
        }
    }

    private func drawDayLabel(_ day: UsagePanelModel.Day, columnX: CGFloat, columnWidth: CGFloat, y: CGFloat) {
        draw(
            day.label,
            font: .systemFont(ofSize: 11, weight: day.isToday ? .semibold : .regular),
            color: day.isToday ? .labelColor : .secondaryLabelColor, alignment: .center,
            in: NSRect(
                x: columnX, y: y + Metrics.chartValueRow + Metrics.chartBars + 3,
                width: columnWidth, height: Metrics.chartLabelRow
            )
        )
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
