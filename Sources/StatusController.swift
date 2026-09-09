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

private func clip(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : String(s.prefix(n - 1)) + "…"
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
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}

final class StatusController: NSObject, NSMenuDelegate {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let barView = UsageBarView()
    private let fetcher = UsageFetcher()
    private let accounts = AccountWatcher()
    private let store = AccountStore()
    private let menu = NSMenu()

    private var timer: Timer?
    private var pacers: [String: FetchPacer] = [:]
    private var errors: [String: UsageError] = [:]
    private var inFlight: Set<String> = []

    private let tickInterval: TimeInterval = 30
    /// The account on the menu bar is worth keeping current; the rest are a
    /// reference you glance at, and every extra account multiplies requests
    /// against a rate-limited endpoint.
    private let foregroundInterval: TimeInterval = 180
    private let backgroundInterval: TimeInterval = 900
    /// Beyond this a reading is shown with its age rather than as current.
    private let freshFor: TimeInterval = 420

    private var compact: Bool {
        get { UserDefaults.standard.bool(forKey: "compactBar") }
        set { UserDefaults.standard.set(newValue, forKey: "compactBar"); render() }
    }

    // MARK: Which account is which

    /// The account Claude Code is signed into. Its token is always read live
    /// and is never refreshed by us.
    private var activeUUID: String? { accounts.current?.uuid }

    /// The account whose numbers appear in the menu bar.
    private var displayedUUID: String? { store.pinnedUUID ?? activeUUID }

    private var displayed: StoredAccount? { displayedUUID.flatMap { store.account($0) } }

    private func isFresh(_ account: StoredAccount) -> Bool {
        guard let at = account.lastFetchedAt else { return false }
        return Date().timeIntervalSince(at) < freshFor
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
            // The signed-in account changed. Capture its credentials and, if
            // the bar is following the signed-in account, get its numbers now
            // rather than at the next scheduled poll.
            self.captureActive()
            self.render()
            self.tick(.accountSwitch)
        }

        enableLaunchAtLoginOnFirstRun()
        render()
        captureActive()
        tick(.scheduled)

        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.captureActive()
            self?.tick(.scheduled)
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.captureActive()
                self?.tick(.wake)
            }
        }
    }

    // MARK: Capture

    /// Mirrors Claude Code's current credential into our store, so this account
    /// stays queryable once the user signs into a different one.
    private func captureActive() {
        accounts.recheck()
        guard let identity = accounts.current, let uuid = identity.uuid else { return }
        // The Keychain read can block on a prompt; keep it off the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let current = try? Credentials.loadCurrent() else { return }
            DispatchQueue.main.async {
                self?.store.upsert(uuid: uuid,
                                   email: identity.email,
                                   org: identity.organization,
                                   plan: identity.plan ?? current.subscriptionType?.capitalized,
                                   accessToken: current.accessToken,
                                   refreshToken: current.refreshToken,
                                   expiresAt: current.expiresAt)
            }
        }
    }

    // MARK: Fetching

    private func tick(_ trigger: FetchPacer.Trigger) {
        let displayedID = displayedUUID
        for account in store.accounts {
            let foreground = account.uuid == displayedID
            var pacer = pacers[account.uuid]
                ?? FetchPacer(basePollInterval: foregroundInterval, maxBackoff: 1800)
            pacer.basePollInterval = foreground ? foregroundInterval : backgroundInterval
            pacers[account.uuid] = pacer
            guard pacer.allows(trigger) else { continue }
            fetch(account)
        }
    }

    private func fetch(_ account: StoredAccount) {
        let uuid = account.uuid
        guard inFlight.insert(uuid).inserted else { return }

        let done: (Result<Snapshot, UsageError>) -> Void = { [weak self] result in
            guard let self = self else { return }
            self.inFlight.remove(uuid)
            var pacer = self.pacers[uuid] ?? FetchPacer(basePollInterval: self.foregroundInterval)
            switch result {
            case .success(let snapshot):
                self.store.recordSnapshot(snapshot, for: uuid)
                self.errors[uuid] = nil
                pacer.recordSuccess()
            case .failure(let error):
                self.errors[uuid] = error
                pacer.recordFailure(error)
            }
            self.pacers[uuid] = pacer
            self.render()
            if self.item.button?.window?.isVisible == true { self.rebuildMenu() }
        }

        // The signed-in account: always Claude Code's live token. We neither
        // use our stored copy nor refresh it — refreshing rotates the token
        // and would log the user out of their CLI.
        if uuid == activeUUID {
            fetcher.fetch(completion: done)
            return
        }

        if account.hasLiveToken(), let token = account.accessToken {
            fetcher.fetch(token: token, completion: done)
            return
        }

        // Expired, and this account is not the signed-in one, so Claude Code no
        // longer holds its credentials and we are the only holder. Safe to renew.
        guard let refreshToken = account.refreshToken else {
            done(.failure(.unauthorized))
            return
        }
        TokenRefresh.renew(refreshToken: refreshToken) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let renewed):
                self.store.upsert(uuid: uuid,
                                  accessToken: renewed.accessToken,
                                  refreshToken: renewed.refreshToken,
                                  expiresAt: renewed.expiresAt)
                self.fetcher.fetch(token: renewed.accessToken, completion: done)
            case .failure(let error):
                // A spent refresh token can't be recovered from here; the user
                // has to sign into that account again for us to re-capture it.
                if case .unauthorized = error { self.store.forgetCredentials(uuid) }
                done(.failure(error))
            }
        }
    }

    // MARK: Menu bar

    private func render() {
        guard let button = item.button else { return }
        var groups: [[UsageBarView.Run]] = []

        if let account = displayed, let snapshot = account.lastSnapshot {
            let stale = !isFresh(account)
            groups = barSegments(snapshot, compact: compact).map { segment in
                var runs: [UsageBarView.Run] = []
                if let label = segment.label {
                    runs.append(UsageBarView.Run(
                        text: label,
                        color: stale ? .tertiaryLabelColor : .secondaryLabelColor))
                }
                runs.append(UsageBarView.Run(
                    text: segment.value,
                    color: stale ? .tertiaryLabelColor : segment.level.color))
                return runs
            }
            var tip = account.displayName
            if stale, let at = account.lastFetchedAt { tip += " · \(agoText(at))" }
            tip += "\n" + snapshot.metrics
                .map { "\($0.longLabel): \(Int($0.percent.rounded()))%" }
                .joined(separator: "\n")
            button.toolTip = tip
        } else if let error = displayedUUID.flatMap({ errors[$0] }) ?? errors.values.first {
            let short: String
            switch error {
            case .notSignedIn:    short = "claude: sign in"
            case .unauthorized:   short = "claude: auth"
            case .keychainDenied: short = "claude: keychain"
            case .rateLimited:    short = "claude: wait"
            default:              short = "claude —"
            }
            groups = [[UsageBarView.Run(text: short, color: .secondaryLabelColor)]]
            button.toolTip = error.localizedDescription
        } else {
            groups = [[UsageBarView.Run(text: "claude …", color: .secondaryLabelColor)]]
            button.toolTip = "Loading Claude usage…"
        }

        button.title = ""
        button.image = nil
        barView.setGroups(groups)
        item.length = barView.fittingWidth
        let height = button.bounds.height > 0 ? button.bounds.height : NSStatusBar.system.thickness
        barView.frame = NSRect(x: 0, y: 0, width: item.length, height: height)
    }

    // MARK: Dropdown

    func menuNeedsUpdate(_ menu: NSMenu) {
        accounts.recheck()
        rebuildMenu()
        tick(.menuOpened)
    }

    private func mono(_ s: String, _ color: NSColor = .labelColor, size: CGFloat = 12) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: color,
        ])
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let all = store.accounts
        let activeID = activeUUID
        let displayedID = displayedUUID

        // --- Accounts -------------------------------------------------------
        let header = NSMenuItem()
        header.attributedTitle = mono(all.count > 1 ? "ACCOUNTS" : "ACCOUNT",
                                      .tertiaryLabelColor, size: 10)
        header.isEnabled = false
        menu.addItem(header)

        if all.isEmpty {
            let mi = NSMenuItem()
            mi.attributedTitle = mono("Not signed in — run `claude`", .secondaryLabelColor, size: 11)
            mi.isEnabled = false
            menu.addItem(mi)
        }

        for (i, account) in all.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            addRows(for: account, activeID: activeID, displayedID: displayedID)
        }

        menu.addItem(.separator())
        add("Refresh Now", #selector(actionRefresh), key: "r")

        if all.count > 1 || store.pinnedUUID != nil {
            let follow = add("Follow Signed-in Account", #selector(actionFollowActive))
            follow.state = store.pinnedUUID == nil ? .on : .off
        }

        // --- Adding and removing --------------------------------------------
        add("Add Another Account…", #selector(actionAddAccount))
        if !all.isEmpty {
            let remove = NSMenuItem(title: "Forget Account", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for account in all {
                let mi = NSMenuItem(title: account.displayName,
                                    action: #selector(actionForget(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = account.uuid
                sub.addItem(mi)
            }
            remove.submenu = sub
            menu.addItem(remove)
        }

        menu.addItem(.separator())
        let compactItem = add("Compact Menu Bar", #selector(actionToggleCompact))
        compactItem.state = compact ? .on : .off
        let loginItem = add("Launch at Login", #selector(actionToggleLaunchAtLogin))
        loginItem.state = launchAtLoginEnabled ? .on : .off
        add("Open Usage on claude.ai", #selector(actionOpenWeb))
        menu.addItem(.separator())
        add("Quit Claude Meter", #selector(actionQuit), key: "q")
    }

    /// One account: a selectable header naming it, then its own usage gauges.
    /// Every account gets the full readout, so the window answers "where am I
    /// on each of these" without having to switch between them.
    private func addRows(for account: StoredAccount, activeID: String?, displayedID: String?) {
        let stale = !isFresh(account)
        let nameWidth = 40

        // The checkmark marks which account the menu bar follows. That is a
        // different thing from which one is signed in, so the right-hand
        // column says that separately.
        let head = NSMenuItem(title: "", action: #selector(actionSelectAccount(_:)), keyEquivalent: "")
        head.target = self
        head.representedObject = account.uuid
        head.state = account.uuid == displayedID ? .on : .off

        var name = clip(account.displayName, 30)
        if let plan = account.plan { name += " \u{00B7} \(plan)" }

        var status = account.lastFetchedAt.map(agoText) ?? "no data"
        if account.uuid == activeID { status = "signed in \u{00B7} " + status }

        head.attributedTitle = NSAttributedString(
            string: pad(name, nameWidth) + status,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: stale ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ])
        head.isEnabled = true
        menu.addItem(head)

        if let snapshot = account.lastSnapshot {
            for metric in snapshot.metrics {
                let mi = NSMenuItem()
                let indent = "   "
                let line = indent + pad(metric.longLabel, 21)
                    + gauge(metric.percent) + " "
                    + String(format: "%3d%%", Int(metric.percent.rounded()))
                    + "   " + resetText(metric.resetsAt)
                let s = NSMutableAttributedString(attributedString: mono(line))
                if stale {
                    s.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                                   range: NSRange(location: 0, length: s.length))
                } else {
                    let start = indent.count + 21
                    let length = min(18, max(0, s.length - start))
                    if length > 0 {
                        s.addAttribute(.foregroundColor, value: metric.level.color,
                                       range: NSRange(location: start, length: length))
                    }
                }
                mi.attributedTitle = s
                mi.isEnabled = false
                menu.addItem(mi)
            }
        } else {
            let mi = NSMenuItem()
            let text = errors[account.uuid]?.localizedDescription ?? "no readings yet"
            mi.attributedTitle = mono("   " + text, .tertiaryLabelColor, size: 11)
            mi.isEnabled = false
            menu.addItem(mi)
        }

        // Anything this account is struggling with sits under its own rows,
        // rather than in one global status line that cannot say which.
        var notes: [String] = []
        if account.lastSnapshot != nil, let error = errors[account.uuid] {
            notes.append(error.localizedDescription)
        }
        if let wait = pacers[account.uuid]?.waitRemaining(), wait > 60 {
            notes.append("next try in \(Int(wait.rounded()))s")
        }
        if !notes.isEmpty {
            let mi = NSMenuItem()
            mi.attributedTitle = mono("   " + notes.joined(separator: " \u{00B7} "),
                                      .tertiaryLabelColor, size: 11)
            mi.isEnabled = false
            menu.addItem(mi)
        }
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
        captureActive()
        tick(.manual)
    }

    @objc private func actionSelectAccount(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        // Pinning the signed-in account is the same as following it.
        store.pinnedUUID = (uuid == activeUUID) ? nil : uuid
        render()
        tick(.manual)
    }

    @objc private func actionFollowActive() {
        store.pinnedUUID = nil
        render()
        tick(.manual)
    }

    @objc private func actionForget(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        store.remove(uuid)
        pacers[uuid] = nil
        errors[uuid] = nil
        render()
    }

    /// Adding an account means signing into it in Claude Code once; we capture
    /// its credentials the moment it becomes the signed-in account.
    @objc private func actionAddAccount() {
        let alert = NSAlert()
        alert.messageText = "Add another account"
        alert.informativeText = """
        Claude Meter reads whichever account Claude Code is signed into, so to \
        track another one, sign into it once:

            claude auth login

        Claude Meter picks it up within a few seconds and keeps it up to date \
        from then on, even after you switch back.
        """
        alert.addButton(withTitle: "Open Terminal")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let script = "tell application \"Terminal\" to do script \"claude auth login\""
            if let apple = NSAppleScript(source: "tell application \"Terminal\" to activate\n\(script)") {
                apple.executeAndReturnError(nil)
            }
        }
    }

    @objc private func actionToggleCompact() { compact.toggle() }

    @objc private func actionOpenWeb() {
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func actionQuit() { NSApp.terminate(nil) }

    // MARK: Launch at login

    private var launchAtLoginEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    @objc private func actionToggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func enableLaunchAtLoginOnFirstRun() {
        guard #available(macOS 13.0, *) else { return }
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}
