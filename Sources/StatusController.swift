import Cocoa
import ServiceManagement

extension UsageLevel {
    /// Colour for the percentage. Labels beside it stay neutral, so the only
    /// thing carrying colour is the number the colour is about.
    var color: NSColor {
        switch self {
        case .low:      return .systemGreen
        case .moderate: return .usageYellow
        case .high:     return .systemOrange
        case .critical: return .systemRed
        }
    }
}

extension NSColor {
    /// systemYellow is tuned for fills; as text on a light menu bar it is
    /// close to invisible. Keep it in dark mode, darken it to a gold in light.
    static let usageYellow = NSColor(name: "usageYellow") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemYellow
            : NSColor(srgbRed: 0.62, green: 0.47, blue: 0.02, alpha: 1)
    }
}

private func gauge(_ percent: Double, width: Int = 12) -> String {
    let filled = Int((percent / 100.0 * Double(width)).rounded())
    let f = max(0, min(width, filled))
    return String(repeating: "█", count: f) + String(repeating: "░", count: width - f)
}

private func pad(_ s: String, _ n: Int) -> String {
    let c = s.count
    return c >= n ? s : s + String(repeating: " ", count: n - c)
}

private func resetText(_ date: Date?) -> String {
    guard let date = date else { return "" }
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "resetting…" }
    let h = secs / 3600, m = (secs % 3600) / 60
    if h >= 24 { return "resets in \(h / 24)d \(h % 24)h" }
    if h > 0 { return "resets in \(h)h \(m)m" }
    return "resets in \(m)m"
}

private func agoText(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 5 { return "just now" }
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
}

final class StatusController: NSObject, NSMenuDelegate {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let barView = UsageBarView()
    private let fetcher = UsageFetcher()
    private let accounts = AccountWatcher()
    private let menu = NSMenu()

    private var timer: Timer?
    private var snapshot: Snapshot?
    private var lastError: UsageError?
    private var inFlight = false

    /// How often we *consider* fetching. Whether we actually go is the pacer's
    /// decision, which lets a backoff push the next call out arbitrarily far
    /// without rescheduling the timer.
    private let tickInterval: TimeInterval = 30

    /// Spacing, backoff and the rules about which triggers may skip them.
    private var pacer = FetchPacer(basePollInterval: 180, maxBackoff: 1800)

    private var compact: Bool {
        get { UserDefaults.standard.bool(forKey: "compactBar") }
        set { UserDefaults.standard.set(newValue, forKey: "compactBar"); render() }
    }

    // MARK: Lifecycle

    func start() {
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        if let button = item.button {
            button.toolTip = "Claude usage"
            barView.autoresizingMask = [.width, .height]
            button.addSubview(barView)
        }

        accounts.onSwitch = { [weak self] _ in
            guard let self = self else { return }
            // Different account: the numbers on screen belong to someone else,
            // so drop them rather than let them sit there looking current.
            self.snapshot = nil
            self.lastError = nil
            self.render()
            // A switch is not a retry — it must not be held behind the normal
            // polling interval. (A 429 still binds it; the pacer decides.)
            self.refresh(.accountSwitch)
        }

        enableLaunchAtLoginOnFirstRun()
        render()
        refresh(.scheduled)

        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.accounts.recheck()
            self?.refresh(.scheduled)
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Anything that suspends the timer or invalidates the numbers.
        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.accounts.recheck()
                self?.refresh(.wake)
            }
        }
    }

    // MARK: Fetching

    /// Fetches only if we are past `nextFetchAt`. Every caller goes through
    /// here, so a server-instructed wait is respected no matter what triggered
    /// the attempt — timer, wake, menu, or the Refresh item.
    private func refresh(_ trigger: FetchPacer.Trigger) {
        // The account can change between polls, and the header must never name
        // one account while the numbers belong to another.
        accounts.recheck()
        guard !inFlight, pacer.allows(trigger) else { return }
        inFlight = true
        fetcher.fetch { [weak self] result in
            guard let self = self else { return }
            self.inFlight = false
            switch result {
            case .success(let snap):
                self.snapshot = snap
                self.lastError = nil
                self.pacer.recordSuccess()
            case .failure(let err):
                self.lastError = err
                // Keep the last good numbers on screen for a transient failure;
                // drop them entirely once they can no longer be trusted.
                if !err.selfHealing { self.snapshot = nil }
                self.pacer.recordFailure(err)
            }
            self.render()
            if self.item.button?.window?.isVisible == true {
                self.rebuildMenu()
            }
        }
    }

    // MARK: Menu bar rendering

    private func render() {
        guard let button = item.button else { return }
        var groups: [[UsageBarView.Run]] = []

        if let snap = snapshot {
            // Labels are all the same neutral colour; only the percentages are
            // tinted, by their own band. The colour then means one thing —
            // how full that particular window is — instead of also being part
            // of how the label is styled.
            let stale = lastError != nil
            groups = barSegments(snap, compact: compact).map { seg in
                var runs: [UsageBarView.Run] = []
                if let label = seg.label {
                    runs.append(UsageBarView.Run(
                        text: label,
                        color: stale ? .tertiaryLabelColor : .secondaryLabelColor))
                }
                runs.append(UsageBarView.Run(
                    text: seg.value,
                    color: stale ? .tertiaryLabelColor : seg.level.color))
                return runs
            }
            button.toolTip = snap.metrics
                .map { "\($0.longLabel): \(Int($0.percent.rounded()))%" }
                .joined(separator: "\n")
        } else if let err = lastError {
            let short: String
            switch err {
            case .notSignedIn:    short = "claude: sign in"
            case .unauthorized:   short = "claude: auth"
            case .keychainDenied: short = "claude: keychain"
            default:              short = "claude \u{2014}"
            }
            groups = [[UsageBarView.Run(text: short, color: .secondaryLabelColor)]]
            button.toolTip = err.localizedDescription
        } else {
            groups = [[UsageBarView.Run(text: "claude \u{2026}", color: .secondaryLabelColor)]]
            button.toolTip = "Loading Claude usage\u{2026}"
        }

        // The custom view owns the whole readout, so the button must not also
        // draw a title of its own.
        button.title = ""
        button.image = nil

        barView.setGroups(groups)
        item.length = barView.fittingWidth
        let height = button.bounds.height > 0 ? button.bounds.height : NSStatusBar.system.thickness
        barView.frame = NSRect(x: 0, y: 0, width: item.length, height: height)
    }

    // MARK: Dropdown

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Re-read who we are signed in as before drawing the header, so the
        // account shown is never a tick behind what you just did in the CLI.
        accounts.recheck()
        rebuildMenu()
        // Opening the menu is a good moment to be current; the pacer decides
        // whether we are actually allowed to go yet.
        refresh(.menuOpened)
    }

    private func mono(_ s: String, _ color: NSColor = .labelColor, size: CGFloat = 12) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: color,
        ])
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // Header: whose usage this is.
        let acct = accounts.current
        let header = NSMenuItem()
        let who = acct?.displayName ?? "Not signed in"
        let plan = acct?.plan.map { " · \($0)" } ?? ""
        header.attributedTitle = mono("\(who)\(plan)", .secondaryLabelColor, size: 11)
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if let snap = snapshot {
            for m in snap.metrics {
                let mi = NSMenuItem()
                let line = "\(pad(m.longLabel, 21))\(gauge(m.percent)) "
                    + String(format: "%3d%%", Int(m.percent.rounded()))
                    + "   \(resetText(m.resetsAt))"
                let s = NSMutableAttributedString(attributedString: mono(line))
                // Tint just the gauge + number by that metric's own band.
                let gaugeStart = 21
                let gaugeLen = min(12 + 6, max(0, s.length - gaugeStart))
                if gaugeLen > 0 {
                    s.addAttribute(.foregroundColor, value: m.level.color,
                                   range: NSRange(location: gaugeStart, length: gaugeLen))
                }
                mi.attributedTitle = s
                mi.isEnabled = false
                menu.addItem(mi)
            }
            menu.addItem(.separator())

            let updated = NSMenuItem()
            var status = "Updated \(agoText(snap.fetchedAt))"
            if let err = lastError { status += " · \(err.localizedDescription)" }
            if let wait = pacer.waitRemaining() {
                status += " · next try in \(Int(wait.rounded()))s"
            }
            updated.attributedTitle = mono(status, .secondaryLabelColor, size: 11)
            updated.isEnabled = false
            menu.addItem(updated)
        } else {
            let mi = NSMenuItem()
            let text = lastError?.localizedDescription ?? "Loading…"
            mi.attributedTitle = mono(text, .secondaryLabelColor, size: 11)
            mi.isEnabled = false
            menu.addItem(mi)
            menu.addItem(.separator())
        }

        add("Refresh Now", #selector(actionRefresh), key: "r")
        menu.addItem(.separator())

        let compactItem = add("Compact Menu Bar", #selector(actionToggleCompact))
        compactItem.state = compact ? .on : .off

        let loginItem = add("Launch at Login", #selector(actionToggleLaunchAtLogin))
        loginItem.state = launchAtLoginEnabled ? .on : .off

        add("Open Usage on claude.ai", #selector(actionOpenWeb))
        menu.addItem(.separator())
        add("Quit Claude Meter", #selector(actionQuit), key: "q")
    }

    @discardableResult
    private func add(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        mi.isEnabled = true
        menu.addItem(mi)
        return mi
    }

    // MARK: Actions

    @objc private func actionRefresh() {
        // A manual refresh may skip our own pacing, but not a wait the server
        // asked for. The pacer enforces both.
        refresh(.manual)
    }

    @objc private func actionToggleCompact() {
        compact.toggle()
    }

    @objc private func actionOpenWeb() {
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func actionQuit() {
        NSApp.terminate(nil)
    }

    // MARK: Launch at login

    private var launchAtLoginEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    @objc private func actionToggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            // Most often: the user has to approve it in System Settings.
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// The app is meant to be always-on, so register the login item the first
    /// time it runs. Only once — after that the menu toggle is authoritative.
    private func enableLaunchAtLoginOnFirstRun() {
        guard #available(macOS 13.0, *) else { return }
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}
