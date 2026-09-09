import Cocoa

/// Draws the readout as a rounded chip: a hairline border around the whole
/// group, with a faint vertical rule between each number.
///
/// This is a custom view rather than an attributed title because a status item
/// title can't draw a border or a rule. Everything uses semantic colours and is
/// drawn in `draw(_:)`, so it follows the menu bar between light and dark.
final class UsageBarView: NSView {

    struct Run {
        let text: String
        let color: NSColor
    }

    // Geometry. Tweak these to taste; widths recompute from them automatically.
    private let outerMarginX: CGFloat = 2   // breathing room from neighbouring items
    private let outerMarginY: CGFloat = 3   // inset of the chip from the bar height
    private let padX: CGFloat = 7           // inside the border, before the first number
    private let gap: CGFloat = 6            // each side of a divider
    private let labelGap: CGFloat = 4       // between a label and its value
    private let dividerWidth: CGFloat = 1
    private let dividerHeightRatio: CGFloat = 0.5   // "small": half the chip height
    private let cornerRadius: CGFloat = 5.5

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    /// Each group is drawn as one unit — a label and its value — with a rule
    /// between groups but not inside them.
    private var groups: [[Run]] = []

    func setGroups(_ groups: [[Run]]) {
        self.groups = groups
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    // MARK: Sizing

    private func attributed(_ run: Run) -> NSAttributedString {
        NSAttributedString(string: run.text, attributes: [
            .font: font,
            .foregroundColor: run.color,
        ])
    }

    /// Width the status item needs to show everything without clipping.
    var fittingWidth: CGFloat {
        guard !groups.isEmpty else { return 0 }
        let text = groups.flatMap { $0 }.reduce(CGFloat(0)) { $0 + attributed($1).size().width }
        let inner = groups.reduce(CGFloat(0)) { $0 + CGFloat(max(0, $1.count - 1)) * labelGap }
        let rules = CGFloat(groups.count - 1) * (gap * 2 + dividerWidth)
        return (outerMarginX + padX) * 2 + text + inner + rules
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: fittingWidth, height: NSView.noIntrinsicMetric)
    }

    /// Let clicks fall through to the status item button underneath, so the
    /// menu still opens.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !groups.isEmpty else { return }

        let chip = NSRect(
            x: outerMarginX,
            y: outerMarginY,
            width: max(0, bounds.width - outerMarginX * 2),
            height: max(0, bounds.height - outerMarginY * 2)
        )

        // Half-point inset keeps the 1pt stroke crisp instead of straddling
        // two device pixels.
        let border = NSBezierPath(
            roundedRect: chip.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        border.lineWidth = 1
        NSColor.tertiaryLabelColor.setStroke()
        border.stroke()

        let ruleHeight = (chip.height * dividerHeightRatio).rounded()
        var x = chip.minX + padX

        for (i, group) in groups.enumerated() {
            if i > 0 {
                x += gap
                NSColor.quaternaryLabelColor.setFill()
                NSRect(x: x.rounded(),
                       y: (chip.midY - ruleHeight / 2).rounded(),
                       width: dividerWidth,
                       height: ruleHeight).fill()
                x += dividerWidth + gap
            }
            for (j, run) in group.enumerated() {
                if j > 0 { x += labelGap }
                let text = attributed(run)
                let size = text.size()
                text.draw(at: NSPoint(x: x, y: chip.midY - size.height / 2))
                x += size.width
            }
        }
    }
}
