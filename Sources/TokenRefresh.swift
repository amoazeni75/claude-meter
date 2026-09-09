import Foundation

/// Renews an access token from a stored refresh token.
///
/// Uses Claude Code's OAuth client id, which is a public identifier: a native
/// app authenticating with PKCE cannot hold a client secret, so this value is
/// the same in every install and is not a credential.
///
/// SAFETY: refresh tokens rotate, so whoever refreshes last invalidates every
/// other holder. This must therefore only ever be called for accounts Claude
/// Code is *not* signed into — it discards the previous account's credentials
/// on switch, which leaves us the sole holder. Refreshing the active account
/// would log the user out of their CLI. `StatusController` enforces this.
enum TokenRefresh {

    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let endpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    struct Renewed {
        let accessToken: String
        /// Present when the server rotated it; store it or the next refresh fails.
        let refreshToken: String?
        let expiresAt: Date
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let delegate = NoRedirects()
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        return URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }()

    private struct Response: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
    }

    /// Completion is delivered on the main queue.
    static func renew(refreshToken: String,
                      completion: @escaping (Result<Renewed, UsageError>) -> Void) {
        let finish: (Result<Renewed, UsageError>) -> Void = { r in
            DispatchQueue.main.async { completion(r) }
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeMeter/\(appVersion)", forHTTPHeaderField: "User-Agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])

        session.dataTask(with: req) { data, response, error in
            if let error = error {
                finish(.failure(.network((error as NSError).localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                finish(.failure(.network("no response"))); return
            }
            switch http.statusCode {
            case 200:
                guard let data = data,
                      let r = try? JSONDecoder().decode(Response.self, from: data),
                      !r.access_token.isEmpty else {
                    finish(.failure(.badCredentialPayload)); return
                }
                finish(.success(Renewed(
                    accessToken: r.access_token,
                    refreshToken: r.refresh_token,
                    expiresAt: Date().addingTimeInterval(r.expires_in ?? 8 * 3600)
                )))
            case 400, 401, 403:
                // The refresh token is spent or revoked — most likely because
                // the user signed into this account again and Claude Code
                // rotated it. Not retryable; the account needs re-capturing.
                finish(.failure(.unauthorized))
            case 429:
                finish(.failure(.rateLimited(
                    retryAfter: parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After")))))
            default:
                finish(.failure(.http(http.statusCode)))
            }
        }.resume()
    }
}
