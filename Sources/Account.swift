import Foundation

/// Who Claude Code is currently signed in as.
///
/// Read from ~/.claude.json, which Claude Code rewrites on login/logout, so an
/// account switch on this machine is visible without touching the Keychain.
struct AccountIdentity: Equatable {
    let uuid: String?
    let email: String?
    let organization: String?
    let plan: String?

    var displayName: String {
        email ?? organization ?? "Signed in"
    }

    /// A switch is only meaningful if the account UUID (or, failing that, the
    /// email) actually changed. Everything else in ~/.claude.json churns
    /// constantly and must not count as a switch.
    static func changed(_ a: AccountIdentity?, _ b: AccountIdentity?) -> Bool {
        (a?.uuid ?? a?.email) != (b?.uuid ?? b?.email)
    }

    static func read() -> AccountIdentity? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
        guard
            let data = FileManager.default.contents(atPath: path),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let acct = root["oauthAccount"] as? [String: Any]
        else { return nil }

        return AccountIdentity(
            uuid: acct["accountUuid"] as? String,
            email: acct["emailAddress"] as? String,
            organization: acct["organizationName"] as? String,
            plan: (acct["billingType"] as? String).map(prettyPlan)
        )
    }
}

private func prettyPlan(_ raw: String) -> String {
    // e.g. "claude_max" -> "Max", "claude_pro" -> "Pro"
    let tail = raw.split(separator: "_").last.map(String.init) ?? raw
    return tail.prefix(1).uppercased() + tail.dropFirst()
}

/// Watches a single file for changes, surviving the atomic
/// write-to-temp-then-rename that Claude Code uses (which replaces the inode
/// and would otherwise kill a naive watcher after the first event).
final class FileWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "com.claudemeter.filewatch")
    private var debounce: DispatchWorkItem?
    private var stopped = false

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        queue.async { [weak self] in self?.arm() }
    }

    deinit { stop() }

    func stop() {
        queue.sync {
            stopped = true
            source?.cancel()
            source = nil
        }
    }

    private func arm() {
        guard !stopped else { return }
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File not there yet (fresh machine, or mid-rename). Try again shortly.
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.arm() }
            return
        }

        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: queue
        )

        s.setEventHandler { [weak self] in
            guard let self = self else { return }
            let flags = s.data
            self.fire()
            if flags.contains(.rename) || flags.contains(.delete) {
                // The path now points at a new inode; re-open onto it.
                s.cancel()
                self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.arm() }
            }
        }

        s.setCancelHandler { [fd] in
            if fd >= 0 { close(fd) }
        }

        source = s
        s.resume()
    }

    /// Claude Code touches ~/.claude.json many times per session; collapse
    /// bursts so we re-read at most once per half second.
    private func fire() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.stopped else { return }
            DispatchQueue.main.async { self.onChange() }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

/// Publishes the current account and calls `onSwitch` when it actually changes.
final class AccountWatcher {
    private(set) var current: AccountIdentity?
    private var watcher: FileWatcher?
    var onSwitch: ((AccountIdentity?) -> Void)?

    init() {
        current = AccountIdentity.read()
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
        watcher = FileWatcher(path: path) { [weak self] in self?.recheck() }
    }

    /// Also called from the poll timer, so an account switch is still caught if
    /// the file watcher ever misses an event.
    func recheck() {
        let next = AccountIdentity.read()
        if AccountIdentity.changed(current, next) {
            current = next
            onSwitch?(next)
        } else {
            current = next
        }
    }
}
