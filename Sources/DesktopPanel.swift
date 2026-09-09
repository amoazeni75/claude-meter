import Cocoa

/// A desktop readout.
///
/// Not a WidgetKit widget: that needs an extension, which is sandboxed, which
/// means it cannot reach either Keychain item, which means an App Group, which
/// needs a provisioning profile from a paid developer account. A borderless
/// window the app draws itself has none of those problems and lands in the
/// same place on screen.
final class DesktopPanel: NSPanel {

    private let content = DesktopWidgetView()
    private static let originKey = "desktopWidgetOrigin"

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: DesktopWidgetView.width, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // Present on every Space, and left alone by Mission Control.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let blur = NSVisualEffectView(frame: contentRect(forFrameRect: frame))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        blur.addSubview(content)
        content.autoresizingMask = [.width, .height]
        contentView = blur

        applyLevel()
        restoreOrigin()

        NotificationCenter.default.addObserver(
            self, selector: #selector(saveOrigin),
            name: NSWindow.didMoveNotification, object: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Sitting at desktop level is what makes it a desktop widget, but that
    /// also means any window hides it — so "keep on top" is a real choice, not
    /// a preference for its own sake.
    var keepOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: "desktopWidgetOnTop") }
        set {
            UserDefaults.standard.set(newValue, forKey: "desktopWidgetOnTop")
            applyLevel()
        }
    }

    private func applyLevel() {
        level = keepOnTop
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    func update(accounts: [StoredAccount], activeUUID: String?, stale: (StoredAccount) -> Bool) {
        content.rows = accounts.map {
            DesktopWidgetView.Row(account: $0,
                                  isActive: $0.uuid == activeUUID,
                                  dimmed: stale($0))
        }
        let height = content.fittingHeight
        var f = frame
        // Grow downward from the top-left, so the corner you positioned stays put.
        f.origin.y += f.height - height
        f.size = NSSize(width: DesktopWidgetView.width, height: height)
        setFrame(f, display: true)
        content.needsDisplay = true
    }

    @objc private func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }

    private func restoreOrigin() {
        if let s = UserDefaults.standard.string(forKey: Self.originKey) {
            let p = NSPointFromString(s)
            // Only if it still lands on a screen — displays get unplugged.
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(p) }) {
                setFrameOrigin(p)
                return
            }
        }
        if let visible = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 24,
                                   y: visible.maxY - frame.height - 24))
        }
    }
}

/// Draws the panel's contents: each account, then its windows as bars.
final class DesktopWidgetView: NSView {

    struct Row {
        let account: StoredAccount
        let isActive: Bool
        let dimmed: Bool
    }

    static let width: CGFloat = 268
    private let inset: CGFloat = 14
    private let titleHeight: CGFloat = 26
    private let accountHeight: CGFloat = 20
    private let metricHeight: CGFloat = 30
    private let emptyHeight: CGFloat = 22

    var rows: [Row] = []

    override var isFlipped: Bool { true }

    var fittingHeight: CGFloat {
        var h = titleHeight + inset
        for row in rows {
            h += accountHeight
            h += CGFloat(row.account.lastSnapshot?.metrics.count ?? 0) * metricHeight
            if row.account.lastSnapshot == nil { h += emptyHeight }
            h += 6
        }
        return max(h + inset - 6, titleHeight + inset * 2 + emptyHeight)
    }

    private func text(_ s: String, _ font: NSFont, _ color: NSColor, at p: NSPoint) {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            .draw(at: p)
    }

    private func textRight(_ s: String, _ font: NSFont, _ color: NSColor,
                           maxX: CGFloat, y: CGFloat) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        a.draw(at: NSPoint(x: maxX - a.size().width, y: y))
    }

    override func draw(_ dirtyRect: NSRect) {
        let right = bounds.width - inset
        var y = inset

        text("CLAUDE", .systemFont(ofSize: 10, weight: .bold), .tertiaryLabelColor,
             at: NSPoint(x: inset, y: y))
        y += titleHeight - 6

        if rows.isEmpty {
            text("Not signed in", .systemFont(ofSize: 11), .secondaryLabelColor,
                 at: NSPoint(x: inset, y: y))
            return
        }

        for row in rows {
            let account = row.account
            let worst = account.lastSnapshot?.metrics
                .max(by: { $0.level.rank < $1.level.rank })?.level
            let accent: NSColor = row.dimmed ? .tertiaryLabelColor : (worst?.color ?? .systemGreen)

            let dot = NSRect(x: inset, y: y + 5, width: 7, height: 7)
            accent.setFill()
            NSBezierPath(ovalIn: dot).fill()

            text(account.displayName,
                 .systemFont(ofSize: 11.5, weight: row.isActive ? .semibold : .regular),
                 row.dimmed ? .secondaryLabelColor : .labelColor,
                 at: NSPoint(x: dot.maxX + 7, y: y))

            if let at = account.lastFetchedAt {
                textRight(agoText(at), .systemFont(ofSize: 9.5), .tertiaryLabelColor,
                          maxX: right, y: y + 1.5)
            }
            y += accountHeight

            guard let snapshot = account.lastSnapshot else {
                text("no readings yet", .systemFont(ofSize: 10.5), .tertiaryLabelColor,
                     at: NSPoint(x: inset + 14, y: y))
                y += emptyHeight + 6
                continue
            }

            for metric in snapshot.metrics {
                let x = inset + 14
                text(metric.shortLabel.uppercased(),
                     .systemFont(ofSize: 9.5, weight: .semibold),
                     .tertiaryLabelColor, at: NSPoint(x: x, y: y))
                text(metric.longLabel,
                     .systemFont(ofSize: 10.5), .secondaryLabelColor,
                     at: NSPoint(x: x + 24, y: y))
                textRight("\(Int(metric.percent.rounded()))%",
                          .monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                          row.dimmed ? .tertiaryLabelColor : metric.level.color,
                          maxX: right, y: y)

                let bar = NSRect(x: x, y: y + 16, width: right - x, height: 7)
                let radius = bar.height / 2
                NSColor.quaternaryLabelColor.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()

                let fraction = min(max(metric.percent / 100, 0), 1)
                if fraction > 0 {
                    let w = max(bar.height, bar.width * fraction)
                    (row.dimmed ? NSColor.tertiaryLabelColor : metric.level.color).setFill()
                    NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY,
                                                     width: w, height: bar.height),
                                 xRadius: radius, yRadius: radius).fill()
                }
                y += metricHeight
            }
            y += 6
        }
    }
}
