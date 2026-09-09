import Foundation
import Security

// MARK: - Severity

enum Severity: String {
    case normal, warning, critical

    var rank: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    /// Trust the server's own severity when it sends one; otherwise fall back to
    /// the same thresholds Claude Code uses for its warnings.
    static func derive(percent: Double, server: String?) -> Severity {
        if let s = server, let v = Severity(rawValue: s.lowercased()) { return v }
        if percent >= 90 { return .critical }
        if percent >= 75 { return .warning }
        return .normal
    }
}

// MARK: - Model

struct Metric {
    let kind: String        // "session" | "weekly_all" | "weekly_scoped"
    let shortLabel: String  // "5h" | "wk" | "fb"
    let longLabel: String   // "Session (5h)" | "Weekly (all models)" | "Weekly · Fable"
    let percent: Double
    let severity: Severity
    let resetsAt: Date?
}

struct Snapshot {
    let metrics: [Metric]
    let fetchedAt: Date

    var worst: Severity {
        metrics.map(\.severity).max(by: { $0.rank < $1.rank }) ?? .normal
    }
}

// MARK: - Errors

enum UsageError: LocalizedError {
    case notSignedIn
    case keychainDenied
    case keychainFailed(OSStatus)
    case badCredentialPayload
    case unauthorized
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
        case .unauthorized, .notSignedIn, .network: return true
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

    static func loadAccessToken() throws -> String {
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
        return token
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
        let sev = Severity.derive(percent: pct, server: l.severity)
        let at = parseTimestamp(l.resets_at)

        switch l.kind {
        case "session":
            session = Metric(kind: "session", shortLabel: "5h",
                             longLabel: "Session (5h)",
                             percent: pct, severity: sev, resetsAt: at)
        case "weekly_all":
            weekly = Metric(kind: "weekly_all", shortLabel: "wk",
                            longLabel: "Weekly (all models)",
                            percent: pct, severity: sev, resetsAt: at)
        case "weekly_scoped":
            let name = l.scope?.model?.display_name ?? "Model"
            scoped.append(Metric(kind: "weekly_scoped", shortLabel: abbreviate(name),
                                 longLabel: "Weekly · \(name)",
                                 percent: pct, severity: sev, resetsAt: at))
        default:
            continue
        }
    }

    if session == nil, let u = r.five_hour?.utilization {
        session = Metric(kind: "session", shortLabel: "5h", longLabel: "Session (5h)",
                         percent: u, severity: Severity.derive(percent: u, server: nil),
                         resetsAt: parseTimestamp(r.five_hour?.resets_at))
    }
    if weekly == nil, let u = r.seven_day?.utilization {
        weekly = Metric(kind: "weekly_all", shortLabel: "wk", longLabel: "Weekly (all models)",
                        percent: u, severity: Severity.derive(percent: u, server: nil),
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

    /// Completion is always delivered on the main queue.
    func fetch(completion: @escaping (Result<Snapshot, UsageError>) -> Void) {
        let finish: (Result<Snapshot, UsageError>) -> Void = { r in
            DispatchQueue.main.async { completion(r) }
        }

        // The Keychain read can block on a user prompt, so keep it off the main thread.
        queue.async { [session] in
            let token: String
            do {
                token = try Credentials.loadAccessToken()
            } catch let e as UsageError {
                finish(.failure(e)); return
            } catch {
                finish(.failure(.badCredentialPayload)); return
            }

            var req = URLRequest(url: UsageFetcher.endpoint)
            req.httpMethod = "GET"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("ClaudeMeter/1.0", forHTTPHeaderField: "User-Agent")

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
                default:
                    finish(.failure(.http(http.statusCode)))
                }
            }.resume()
        }
    }
}

// MARK: - Menu bar layout

/// One number in the menu bar, plus the severity that should colour it.
/// Pure and AppKit-free so the layout can be tested without a UI. Separators
/// are not part of this: the view draws a rule between runs rather than
/// spacing them with characters.
struct BarSegment {
    let text: String
    let severity: Severity
}

func barSegments(_ snapshot: Snapshot, compact: Bool) -> [BarSegment] {
    snapshot.metrics.map { m in
        let pct = Int(m.percent.rounded())
        return BarSegment(text: compact ? "\(pct)" : "\(m.shortLabel) \(pct)%",
                          severity: m.severity)
    }
}

/// Flat text form of the same layout, for tooltips and tests.
func barText(_ snapshot: Snapshot, compact: Bool) -> String {
    barSegments(snapshot, compact: compact)
        .map(\.text)
        .joined(separator: compact ? "\u{00B7}" : "  ")
}
