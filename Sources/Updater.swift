import Foundation

/// Version ordering. Tolerates a leading "v" and any number of components, so
/// "v1.2" and "1.2.0" compare equal and "1.10.0" beats "1.9.0".
struct SemVer: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Drop any pre-release or build suffix before comparing.
        let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? s
        let fields = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !fields.isEmpty else { return nil }
        var out: [Int] = []
        for f in fields {
            guard let n = Int(f), n >= 0 else { return nil }
            out.append(n)
        }
        parts = out
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (l: SemVer, r: SemVer) -> Bool {
        let n = max(l.parts.count, r.parts.count)
        for i in 0..<n {
            let a = i < l.parts.count ? l.parts[i] : 0
            let b = i < r.parts.count ? r.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    static func == (l: SemVer, r: SemVer) -> Bool { !(l < r) && !(r < l) }
}

/// Picks the highest release tag from a list of tag names.
func newestTag(_ names: [String]) -> String? {
    let parsed = names.compactMap { name -> (String, SemVer)? in
        SemVer(name).map { (name, $0) }
    }
    return parsed.max(by: { $0.1 < $1.1 })?.0
}

/// Whether `latest` is worth offering over `current`.
func updateAvailable(current: String, latest: String) -> Bool {
    guard let c = SemVer(current), let l = SemVer(latest) else { return false }
    return c < l
}

/// Self-update for a source install.
///
/// The app is distributed by cloning and building, so updating means pulling
/// the repo it was built from and rebuilding — not downloading a binary. That
/// keeps the update path identical to the install path and needs no signing,
/// notarisation or update server.
///
/// Only tagged versions are taken, never whatever happens to be on the branch,
/// and only via fast-forward, so an update can never rewrite or discard local
/// work.
enum Updater {

    /// Stamped into Info.plist by build.sh: where this app was built from.
    static var repoPath: String? {
        (Bundle.main.object(forInfoDictionaryKey: "CMRepoPath") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "owner/name", derived from the origin remote at build time.
    static var repoSlug: String? {
        (Bundle.main.object(forInfoDictionaryKey: "CMRepoSlug") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static var canSelfUpdate: Bool {
        guard let path = repoPath, repoSlug != nil else { return false }
        var isDir: ObjCBool = false
        let git = (path as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: git, isDirectory: &isDir)
    }

    // MARK: Checking

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
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
        c.urlCache = nil
        return URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }()

    private struct Tag: Decodable { let name: String }

    /// Latest published tag, on the main queue. No credentials are sent.
    static func checkLatest(completion: @escaping (Result<String, UsageError>) -> Void) {
        let finish: (Result<String, UsageError>) -> Void = { r in
            DispatchQueue.main.async { completion(r) }
        }
        guard let slug = repoSlug,
              let url = URL(string: "https://api.github.com/repos/\(slug)/tags?per_page=50") else {
            finish(.failure(.network("no repository configured"))); return
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeMeter/\(appVersion)", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: req) { data, response, error in
            if let error = error {
                finish(.failure(.network((error as NSError).localizedDescription))); return
            }
            guard let http = response as? HTTPURLResponse else {
                finish(.failure(.network("no response"))); return
            }
            guard http.statusCode == 200, let data = data else {
                finish(.failure(.http(http.statusCode))); return
            }
            guard let tags = try? JSONDecoder().decode([Tag].self, from: data),
                  let newest = newestTag(tags.map(\.name)) else {
                finish(.failure(.emptyResponse)); return
            }
            finish(.success(newest))
        }.resume()
    }

    // MARK: Applying

    enum UpdateError: LocalizedError {
        case notASourceInstall
        case couldNotStart(String)
        var errorDescription: String? {
            switch self {
            case .notASourceInstall:
                return "This copy wasn't built from a git checkout"
            case .couldNotStart(let m):
                return "Could not start the updater: \(m)"
            }
        }
    }

    static var logPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/ClaudeMeter-update.log")
    }

    /// Writes a detached script and runs it. It outlives this process on
    /// purpose: the build replaces the very app that started it, so the last
    /// thing the script does is relaunch us.
    static func applyUpdate(to tag: String) throws {
        guard let repo = repoPath, canSelfUpdate else { throw UpdateError.notASourceInstall }

        let script = """
        #!/bin/bash
        # Written by Claude Meter. Safe to delete.
        set -uo pipefail
        exec >>"\(logPath)" 2>&1
        echo "=== $(date) updating to \(tag) ==="
        cd "\(repo)" || { echo "repo missing"; exit 1; }

        if [ -n "$(git status --porcelain)" ]; then
          echo "ABORT: working tree has local changes; not touching it."
          exit 1
        fi

        git fetch --tags --quiet origin || { echo "fetch failed"; exit 1; }

        # Fast-forward only: an update can never rewrite or drop local commits.
        if ! git merge --ff-only "\(tag)"; then
          echo "ABORT: cannot fast-forward to \(tag)."
          exit 1
        fi

        ./build.sh --install
        echo "=== done ==="
        """

        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("claude-meter-update.sh")
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [path]
        do { try task.run() } catch {
            throw UpdateError.couldNotStart(error.localizedDescription)
        }
    }
}
