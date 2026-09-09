import Foundation
import Security

/// One Claude account the app knows about.
///
/// Credentials live here only for accounts Claude Code is *not* currently
/// signed into. The active account is always read live from Claude Code's own
/// keychain item instead, so we never hold a stale copy of the one credential
/// the CLI is actively using.
struct StoredAccount: Codable, Equatable {
    var uuid: String
    var email: String?
    var org: String?
    var plan: String?

    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?

    var addedAt: Date
    var lastFetchedAt: Date?
    var lastSnapshot: Snapshot?

    /// Readings per window kind, feeding the burn-rate projection.
    var history: [String: [Sample]] = [:]
    /// Highest threshold already announced for each window, cleared when the
    /// window rolls over so the next cycle can alert again.
    var notified: [String: Double] = [:]

    var displayName: String { email ?? org ?? String(uuid.prefix(8)) }

    /// Usable without a refresh. A minute of slack avoids racing the expiry.
    func hasLiveToken(now: Date = Date()) -> Bool {
        guard accessToken?.isEmpty == false, let exp = expiresAt else { return false }
        return exp.timeIntervalSince(now) > 60
    }

    var canRefresh: Bool { refreshToken?.isEmpty == false }
}

struct AccountsFile: Codable {
    var version: Int = 1
    /// Which account drives the menu bar. nil means "whichever is signed in".
    var pinnedUUID: String?
    var accounts: [StoredAccount] = []

    /// One window that just crossed a threshold worth interrupting someone for.
    struct Alert: Equatable {
        let kind: String
        let label: String
        let percent: Double
        let threshold: Double
    }

    /// Files a reading and reports what is worth announcing.
    ///
    /// Kept pure and on the file rather than the store so the alerting rule —
    /// the part that can wake someone up — is testable without a Keychain.
    mutating func record(_ snapshot: Snapshot, for uuid: String) -> [Alert] {
        guard let i = accounts.firstIndex(where: { $0.uuid == uuid }) else { return [] }
        var account = accounts[i]
        var alerts: [Alert] = []

        for metric in snapshot.metrics {
            let previous = account.lastSnapshot?.metrics
                .first { $0.kind == metric.kind }?.percent

            if let previous = previous,
               resetsNotifications(previousPercent: previous, currentPercent: metric.percent) {
                account.notified[metric.kind] = nil
            }

            if let hit = thresholdCrossed(percent: metric.percent,
                                          alreadyNotified: account.notified[metric.kind]) {
                account.notified[metric.kind] = hit
                alerts.append(Alert(kind: metric.kind, label: metric.longLabel,
                                    percent: metric.percent, threshold: hit))
            }

            account.history[metric.kind] = HistoryPolicy.append(
                Sample(at: snapshot.fetchedAt, percent: metric.percent),
                to: account.history[metric.kind] ?? [])
        }

        account.lastSnapshot = snapshot
        account.lastFetchedAt = snapshot.fetchedAt
        accounts[i] = account
        return alerts
    }
}

/// Persists accounts in a Keychain item this app owns.
///
/// The Keychain rather than a plist because these are credentials, and
/// `ThisDeviceOnly` so nothing syncs to iCloud. The app created the item, so
/// reading it back never prompts.
final class AccountStore {

    private static let service = "ClaudeMeter-accounts"
    private static let key = "v1"

    private(set) var file: AccountsFile

    init() {
        file = AccountStore.load() ?? AccountsFile()
    }

    // MARK: Queries

    var accounts: [StoredAccount] {
        file.accounts.sorted { $0.addedAt < $1.addedAt }
    }

    func account(_ uuid: String) -> StoredAccount? {
        file.accounts.first { $0.uuid == uuid }
    }

    var pinnedUUID: String? {
        get { file.pinnedUUID }
        set { file.pinnedUUID = newValue; save() }
    }

    // MARK: Mutation

    /// Records what we know about an account, merging rather than replacing so
    /// a metadata-only update cannot wipe stored credentials.
    func upsert(uuid: String,
                email: String? = nil,
                org: String? = nil,
                plan: String? = nil,
                accessToken: String? = nil,
                refreshToken: String? = nil,
                expiresAt: Date? = nil) {
        if let i = file.accounts.firstIndex(where: { $0.uuid == uuid }) {
            var a = file.accounts[i]
            if let email = email { a.email = email }
            if let org = org { a.org = org }
            if let plan = plan { a.plan = plan }
            if let t = accessToken { a.accessToken = t }
            if let t = refreshToken { a.refreshToken = t }
            if let e = expiresAt { a.expiresAt = e }
            file.accounts[i] = a
        } else {
            file.accounts.append(StoredAccount(
                uuid: uuid, email: email, org: org, plan: plan,
                accessToken: accessToken, refreshToken: refreshToken,
                expiresAt: expiresAt, addedAt: Date()
            ))
        }
        save()
    }

    /// Returns the windows that just crossed an alert threshold.
    @discardableResult
    func recordSnapshot(_ snapshot: Snapshot, for uuid: String) -> [AccountsFile.Alert] {
        let alerts = file.record(snapshot, for: uuid)
        save()
        return alerts
    }

    func remove(_ uuid: String) {
        file.accounts.removeAll { $0.uuid == uuid }
        if file.pinnedUUID == uuid { file.pinnedUUID = nil }
        save()
    }

    /// Drops stored credentials but keeps the account and its last numbers.
    func forgetCredentials(_ uuid: String) {
        guard let i = file.accounts.firstIndex(where: { $0.uuid == uuid }) else { return }
        file.accounts[i].accessToken = nil
        file.accounts[i].refreshToken = nil
        file.accounts[i].expiresAt = nil
        save()
    }

    // MARK: Keychain

    private static func load() -> AccountsFile? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(AccountsFile.self, from: data)
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(file) else { return }

        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AccountStore.service,
            kSecAttrAccount as String: AccountStore.key,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(match as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
