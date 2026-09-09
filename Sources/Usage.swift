import Foundation
import Security

// MARK: - Usage level

/// How close one window is to its limit, in four bands.
///
/// Derived from the percentage alone rather than from the `severity` the API
/// also sends, so that the same number always reads as the same colour and the
/// bands stay where they are documented to be.
enum UsageLevel: String, Codable {
    case low        // under 50%
    case moderate   // 50–75%
    case high       // 75–90%
    case critical   // 90% and up

    static func forPercent(_ percent: Double) -> UsageLevel {
        switch percent {
        case ..<50: return .low
        case ..<75: return .moderate
        case ..<90: return .high
        default:    return .critical
        }
    }
}

// MARK: - Model

struct Metric: Codable, Equatable {
    let kind: String        // "session" | "weekly_all" | "weekly_scoped"
    let shortLabel: String  // "5h" | "wk" | "fb"
    let longLabel: String   // "Session (5h)" | "Weekly (all models)" | "Weekly · Fable"
    let percent: Double
    let level: UsageLevel
    let resetsAt: Date?
}

struct Snapshot: Codable, Equatable {
    let metrics: [Metric]
    let fetchedAt: Date
}

// MARK: - Errors

enum UsageError: LocalizedError {
    case notSignedIn
    case keychainDenied
    case keychainFailed(OSStatus)
    case badCredentialPayload
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in — run `claude` and log in"
        case .keychainDenied:
            return "Keychain access denied — allow it in Keychain Access"
        case .keychainFailed(let s):
            return "Keychain error (OSStatus \(s))"
        case .badCredentialPayload:
            return "Unrecognized credential format in Keychain"
        case .unauthorized:
            return "Sign-in expired — open Claude Code to refresh"
        case .rateLimited(let after):
            if let after = after {
                return "Rate limited — retrying in \(Int(after.rounded()))s"
            }
            return "Rate limited — backing off"
        case .http(let code):
            return "Anthropic API returned HTTP \(code)"
        case .network(let m):
            return "Network error: \(m)"
        case .emptyResponse:
            return "No usage windows reported"
        }
    }

    /// True when the condition is expected to clear itself once the user next
    /// runs Claude Code (which rotates the token in the Keychain).
    var selfHealing: Bool {
        switch self {
        case .unauthorized, .notSignedIn, .network, .rateLimited: return true
        default: return false
        }
    }
}

// MARK: - Keychain

/// Reads the OAuth access token Claude Code stores in the login Keychain.
///
/// Security notes:
///  - the token is returned as a local value and is never stored in a property,
///    written to disk, or included in any log or error message;
///  - the item is re-read on every poll rather than cached, so a token that
///    Claude Code refreshes (or an account switch) is picked up automatically;
///  - nothing is ever written back to the Keychain.
enum Credentials {
    static let service = "Claude Code-credentials"

    /// Everything Claude Code stores for the account it is signed into.
    struct Current {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let subscriptionType: String?
    }

    static func loadAccessToken() throws -> String {
        try loadCurrent().accessToken
    }

    static func loadCurrent() throws -> Current {
        // Query by service only. macOS presents its own ACL prompt the first
        // time, because this item belongs to the `claude` binary.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw UsageError.notSignedIn
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw UsageError.keychainDenied
        default:
            throw UsageError.keychainFailed(status)
        }

        guard let data = out as? Data else { throw UsageError.badCredentialPayload }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else {
            throw UsageError.badCredentialPayload
        }
        // expiresAt is milliseconds since the epoch.
        let expiry = (oauth["expiresAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return Current(accessToken: token,
                       refreshToken: oauth["refreshToken"] as? String,
                       expiresAt: expiry,
                       subscriptionType: oauth["subscriptionType"] as? String)
    }
}

// MARK: - Wire format

private struct APIResponse: Decodable {
    struct ModelRef: Decodable {
        let id: String?
        let display_name: String?
    }
    struct Scope: Decodable {
        let model: ModelRef?
    }
    struct Limit: Decodable {
        let kind: String?
        let group: String?
        let percent: Double?
        let severity: String?
        let resets_at: String?
        let scope: Scope?
        let is_active: Bool?
    }
    /// Legacy top-level windows, kept as a fallback if `limits` ever disappears.
    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    let limits: [Limit]?
    let five_hour: Window?
    let seven_day: Window?
}

// MARK: - Parsing helpers

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// The API sends microsecond precision ("…:59.644994+00:00"), which
/// ISO8601DateFormatter will not accept. Trim to milliseconds first.
func parseTimestamp(_ raw: String?) -> Date? {
    guard var s = raw else { return nil }
    if let dot = s.firstIndex(of: ".") {
        let start = s.index(after: dot)
        var end = start
        while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
        let digits = s[start..<end]
        if digits.count > 3 {
            let keep = String(digits.prefix(3))
            s.replaceSubrange(start..<end, with: keep)
        }
    }
    return isoFractional.date(from: s) ?? isoPlain.date(from: s)
}

/// `Retry-After` is either a delay in seconds or an HTTP date. Honouring it is
/// the difference between waiting out a 429 and extending it.
func parseRetryAfter(_ raw: String?) -> TimeInterval? {
    guard let v = raw?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
    if let seconds = TimeInterval(v) { return max(0, seconds) }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "GMT")
    for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz"] {
        f.dateFormat = format
        if let date = f.date(from: v) { return max(0, date.timeIntervalSinceNow) }
    }
    return nil
}

/// "Fable" -> "fb". Unknown names fall back to their first two letters, so a
/// model Anthropic ships after this app was written still renders sensibly.
func abbreviate(_ displayName: String) -> String {
    let known = ["fable": "fb", "opus": "op", "sonnet": "so", "haiku": "ha"]
    let lower = displayName.lowercased()
    if let hit = known[lower] { return hit }
    let letters = lower.filter { $0.isLetter }
    return String(letters.prefix(2))
}

func makeSnapshot(from data: Data) throws -> Snapshot {
    let r = try JSONDecoder().decode(APIResponse.self, from: data)

    var session: Metric?
    var weekly: Metric?
    var scoped: [Metric] = []

    for l in r.limits ?? [] {
        guard let pct = l.percent else { continue }
        let level = UsageLevel.forPercent(pct)
        let at = parseTimestamp(l.resets_at)

        switch l.kind {
        case "session":
            session = Metric(kind: "session", shortLabel: "5h",
                             longLabel: "Session (5h)",
                             percent: pct, level: level, resetsAt: at)
        case "weekly_all":
            weekly = Metric(kind: "weekly_all", shortLabel: "wk",
                            longLabel: "Weekly (all models)",
                            percent: pct, level: level, resetsAt: at)
        case "weekly_scoped":
            let name = l.scope?.model?.display_name ?? "Model"
            scoped.append(Metric(kind: "weekly_scoped", shortLabel: abbreviate(name),
                                 longLabel: "Weekly · \(name)",
                                 percent: pct, level: level, resetsAt: at))
        default:
            continue
        }
    }

    if session == nil, let u = r.five_hour?.utilization {
        session = Metric(kind: "session", shortLabel: "5h", longLabel: "Session (5h)",
                         percent: u, level: UsageLevel.forPercent(u),
                         resetsAt: parseTimestamp(r.five_hour?.resets_at))
    }
    if weekly == nil, let u = r.seven_day?.utilization {
        weekly = Metric(kind: "weekly_all", shortLabel: "wk", longLabel: "Weekly (all models)",
                        percent: u, level: UsageLevel.forPercent(u),
                        resetsAt: parseTimestamp(r.seven_day?.resets_at))
    }

    scoped.sort { $0.percent > $1.percent }
    let ordered = [session, weekly].compactMap { $0 } + scoped
    guard !ordered.isEmpty else { throw UsageError.emptyResponse }
    return Snapshot(metrics: ordered, fetchedAt: Date())
}

// MARK: - Fetcher

/// Refuses every redirect. The bearer token is only ever sent to the exact
/// origin we dialled; a redirect to any other host would leak it.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class UsageFetcher {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let delegate = NoRedirects()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }()

    private let queue = DispatchQueue(label: "com.claudemeter.fetch", qos: .utility)

    /// Fetches using whatever token Claude Code currently holds. Completion is
    /// always delivered on the main queue.
    func fetch(completion: @escaping (Result<Snapshot, UsageError>) -> Void) {
        let finish: (Result<Snapshot, UsageError>) -> Void = { r in
            DispatchQueue.main.async { completion(r) }
        }
        // The Keychain read can block on a user prompt, so keep it off the main thread.
        queue.async { [weak self] in
            let token: String
            do {
                token = try Credentials.loadAccessToken()
            } catch let e as UsageError {
                finish(.failure(e)); return
            } catch {
                finish(.failure(.badCredentialPayload)); return
            }
            self?.fetch(token: token, completion: completion)
        }
    }

    /// Fetches for one specific account's token. Completion is always
    /// delivered on the main queue.
    func fetch(token: String, completion: @escaping (Result<Snapshot, UsageError>) -> Void) {
        let finish: (Result<Snapshot, UsageError>) -> Void = { r in
            DispatchQueue.main.async { completion(r) }
        }

        queue.async { [session] in
            var req = URLRequest(url: UsageFetcher.endpoint)
            req.httpMethod = "GET"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("ClaudeMeter/\(appVersion)", forHTTPHeaderField: "User-Agent")

            session.dataTask(with: req) { data, response, error in
                if let error = error {
                    finish(.failure(.network((error as NSError).localizedDescription)))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    finish(.failure(.network("no response")))
                    return
                }
                switch http.statusCode {
                case 200:
                    guard let data = data else {
                        finish(.failure(.emptyResponse)); return
                    }
                    do {
                        finish(.success(try makeSnapshot(from: data)))
                    } catch let e as UsageError {
                        finish(.failure(e))
                    } catch {
                        finish(.failure(.emptyResponse))
                    }
                case 401, 403:
                    finish(.failure(.unauthorized))
                case 429:
                    let header = http.value(forHTTPHeaderField: "Retry-After")
                    finish(.failure(.rateLimited(retryAfter: parseRetryAfter(header))))
                default:
                    finish(.failure(.http(http.statusCode)))
                }
            }.resume()
        }
    }
}

// MARK: - Menu bar layout

/// One metric in the menu bar: a neutral label and the value that carries the
/// colour. They are separate because only the number is coloured — the label
/// beside it stays the same for all three.
///
/// Pure and AppKit-free so the layout can be tested without a UI. Separators
/// are not part of this: the view draws a rule between segments rather than
/// spacing them with characters.
struct BarSegment {
    let label: String?      // nil in compact mode, where labels are dropped
    let value: String
    let level: UsageLevel

    /// Flat form, for tooltips and tests.
    var text: String {
        guard let label = label else { return value }
        return "\(label) \(value)"
    }
}

func barSegments(_ snapshot: Snapshot, compact: Bool) -> [BarSegment] {
    snapshot.metrics.map { m in
        let pct = Int(m.percent.rounded())
        return BarSegment(label: compact ? nil : m.shortLabel,
                          value: compact ? "\(pct)" : "\(pct)%",
                          level: m.level)
    }
}

/// Flat text form of the same layout, for tooltips and tests.
func barText(_ snapshot: Snapshot, compact: Bool) -> String {
    barSegments(snapshot, compact: compact)
        .map(\.text)
        .joined(separator: compact ? "\u{00B7}" : "  ")
}
