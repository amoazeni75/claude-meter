import Cocoa

/// Custom rows for the dropdown.
///
/// NSMenu can only style text, so the gauges were block characters in a
/// monospaced font — legible, but obviously a text menu. These are real views:
/// drawn bars with rounded caps, a typographic hierarchy, and their own hover
/// state, which is how a menu-bar app gets to look like a product rather than
/// a terminal.
enum MenuMetrics {
    static let width: CGFloat = 348
    static let inset: CGFloat = 14
    static var content: CGFloat { width - inset * 2 }
}

/// Shared behaviour for a row that lives inside an NSMenuItem: hover highlight
/// and forwarding a click to the item's action, since a custom view gets
/// neither for free.
class MenuRow: NSView {

    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    var isClickable = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { if isClickable { isHovered = true } }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        guard isClickable, let item = enclosingMenuItem, item.isEnabled else { return }
        item.menu?.cancelTracking()
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }

    /// The rounded highlight AppKit would have drawn for a plain item.
    func drawHoverBackground() {
        guard isHovered else { return }
        let r = bounds.insetBy(dx: 5, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
    }
}

// MARK: - Drawing helpers

private func drawText(_ text: String, _ font: NSFont, _ color: NSColor, at point: NSPoint) {
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        .draw(at: point)
}

/// Right-aligned within `maxX`.
private func drawRight(_ text: String, _ font: NSFont, _ color: NSColor,
                       maxX: CGFloat, y: CGFloat) {
    let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    s.draw(at: NSPoint(x: maxX - s.size().width, y: y))
}

private func drawTrack(_ rect: NSRect, fraction: CGFloat, color: NSColor) {
    let radius = rect.height / 2
    NSColor.quaternaryLabelColor.withAlphaComponent(0.5).setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

    let clamped = min(max(fraction, 0), 1)
    guard clamped > 0 else { return }
    // Never narrower than the cap, or the rounded ends collapse into a wedge.
    let w = max(rect.height, rect.width * clamped)
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: w, height: rect.height),
                 xRadius: radius, yRadius: radius).fill()
}

/// A small rounded label, for the plan name.
private func drawPill(_ text: String, at x: CGFloat, centerY: CGFloat) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    let s = NSAttributedString(string: text.uppercased(), attributes: [
        .font: font,
        .foregroundColor: NSColor.secondaryLabelColor,
        .kern: 0.4,
    ])
    let size = s.size()
    let box = NSRect(x: x, y: centerY - 7.5, width: size.width + 11, height: 15)
    NSColor.quaternaryLabelColor.withAlphaComponent(0.55).setFill()
    NSBezierPath(roundedRect: box, xRadius: 4.5, yRadius: 4.5).fill()
    s.draw(at: NSPoint(x: box.minX + 5.5, y: box.midY - size.height / 2))
    return box.maxX
}

// MARK: - Section header

final class SectionHeaderView: MenuRow {
    private let title: String

    init(_ title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 22))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let s = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.8,
        ])
        s.draw(at: NSPoint(x: MenuMetrics.inset, y: bounds.midY - s.size().height / 2))
    }
}

// MARK: - Account header

final class AccountHeaderView: MenuRow {
    private let name: String
    private let plan: String?
    private let status: String
    private let accent: NSColor
    private let selected: Bool
    private let dimmed: Bool

    init(name: String, plan: String?, status: String,
         accent: NSColor, selected: Bool, dimmed: Bool) {
        self.name = name
        self.plan = plan
        self.status = status
        self.accent = accent
        self.selected = selected
        self.dimmed = dimmed
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 30))
        isClickable = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        drawHoverBackground()
        let midY = bounds.midY

        // A filled dot for the account the menu bar follows, a hollow ring for
        // the others — so which one is on the bar reads at a glance.
        let dot = NSRect(x: MenuMetrics.inset, y: midY - 4, width: 8, height: 8)
        let ring = NSBezierPath(ovalIn: dot)
        if selected {
            accent.setFill()
            ring.fill()
        } else {
            accent.withAlphaComponent(0.55).setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }

        var x = dot.maxX + 9
        let nameFont = NSFont.systemFont(ofSize: 12.5, weight: selected ? .semibold : .regular)
        let nameColor: NSColor = dimmed ? .secondaryLabelColor : .labelColor
        let nameString = NSAttributedString(string: name,
                                            attributes: [.font: nameFont, .foregroundColor: nameColor])
        nameString.draw(at: NSPoint(x: x, y: midY - nameString.size().height / 2))
        x += nameString.size().width + 7

        if let plan = plan, !plan.isEmpty {
            x = drawPill(plan, at: x, centerY: midY)
        }

        drawRight(status, NSFont.systemFont(ofSize: 10.5, weight: .regular),
                  .tertiaryLabelColor,
                  maxX: bounds.width - MenuMetrics.inset,
                  y: midY - 6.5)
    }
}

// MARK: - Metric row

final class MetricRowView: MenuRow {
    private let label: String
    private let percent: Double
    private let detail: String
    private let color: NSColor
    private let dimmed: Bool

    init(label: String, percent: Double, detail: String, color: NSColor, dimmed: Bool) {
        self.label = label
        self.percent = percent
        self.detail = detail
        self.color = color
        self.dimmed = dimmed
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 34))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let left = MenuMetrics.inset + 17     // indented under its account
        let right = bounds.width - MenuMetrics.inset

        // Top line: name on the left, the number on the right.
        let topY = bounds.maxY - 17
        drawText(label, .systemFont(ofSize: 11.5, weight: .regular),
                 dimmed ? .tertiaryLabelColor : .secondaryLabelColor,
                 at: NSPoint(x: left, y: topY))

        drawRight("\(Int(percent.rounded()))%",
                  .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                  dimmed ? .tertiaryLabelColor : color,
                  maxX: right, y: topY - 1)

        // Bottom line: the bar, with the reset time trailing it.
        let detailFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let detailWidth = detail.isEmpty ? 0 : NSAttributedString(
            string: detail, attributes: [.font: detailFont]).size().width
        let barRight = detail.isEmpty ? right : right - detailWidth - 9
        let bar = NSRect(x: left, y: bounds.minY + 8, width: max(40, barRight - left), height: 5)
        drawTrack(bar, fraction: percent / 100,
                  color: dimmed ? NSColor.tertiaryLabelColor : color)

        if !detail.isEmpty {
            drawRight(detail, detailFont, .tertiaryLabelColor, maxX: right, y: bounds.minY + 4)
        }
    }
}

// MARK: - Footer note

final class NoteRowView: MenuRow {
    private let text: String
    private let indented: Bool

    init(_ text: String, indented: Bool = true) {
        self.text = text
        self.indented = indented
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 18))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        s.draw(at: NSPoint(x: MenuMetrics.inset + (indented ? 17 : 0),
                           y: bounds.midY - s.size().height / 2))
    }
}
