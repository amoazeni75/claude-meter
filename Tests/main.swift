import Foundation

// A dependency-free assertion harness. Run with Tests/run.sh.

var failures = 0
var checks = 0

func check(_ label: String, _ actual: String, _ expected: String) {
    checks += 1
    if actual == expected {
        print("  ok   \(label)  ->  \(actual)")
    } else {
        failures += 1
        print("  FAIL \(label)\n         expected: \(expected)\n         actual:   \(actual)")
    }
}

func check(_ label: String, _ actual: Int, _ expected: Int) {
    check(label, String(actual), String(expected))
}

func check(_ label: String, _ condition: Bool) {
    checks += 1
    if condition { print("  ok   \(label)") }
    else { failures += 1; print("  FAIL \(label)") }
}

func bar(_ snap: Snapshot, compact: Bool = false) -> String {
    barText(snap, compact: compact)
}

func load(_ name: String) -> Data {
    let path = (fixtureDir as NSString).appendingPathComponent(name)
    guard let d = FileManager.default.contents(atPath: path) else {
        print("  FAIL missing fixture \(path)"); failures += 1; return Data("{}".utf8)
    }
    return d
}

let fixtureDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("Tests/fixtures")

// ---------------------------------------------------------------- current API

print("\ncurrent API shape (limits[])")
do {
    let snap = try makeSnapshot(from: load("current.json"))
    check("three metrics", snap.metrics.count == 3)
    check("order + labels", snap.metrics.map(\.shortLabel).joined(separator: ","), "5h,wk,fb")
    check("long labels",
          snap.metrics.map(\.longLabel).joined(separator: " | "),
          "Session (5h) | Weekly (all models) | Weekly · Fable")
    check("labeled bar", bar(snap), "5h 76%  wk 92%  fb 61%")
    check("compact bar", bar(snap, compact: true), "76·92·61")
    check("segments are values only, dividers are drawn",
          barSegments(snap, compact: false).map(\.text).joined(separator: "|"),
          "5h 76%|wk 92%|fb 61%")
    check("bands from percentage",
          snap.metrics.map { $0.level.rawValue }.joined(separator: ","),
          "high,critical,moderate")
    check("label and value are separate runs",
          barSegments(snap, compact: false)
              .map { "\($0.label ?? "-")/\($0.value)" }.joined(separator: " "),
          "5h/76% wk/92% fb/61%")
    check("compact drops labels entirely",
          barSegments(snap, compact: true).allSatisfy { $0.label == nil })
    check("microsecond timestamp parsed", snap.metrics[0].resetsAt != nil)
    let ts = snap.metrics[0].resetsAt.map { Int($0.timeIntervalSince1970) } ?? 0
    check("timestamp value", "\(ts)", "1788968999")
} catch {
    failures += 1; print("  FAIL threw \(error)")
}

// --------------------------------------------------- legacy top-level windows

print("\nlegacy fallback (no limits[])")
do {
    let snap = try makeSnapshot(from: load("legacy.json"))
    check("two metrics", snap.metrics.count == 2)
    check("labeled bar", bar(snap), "5h 12%  wk 48%")
    check("bands on the legacy shape",
          snap.metrics.map { $0.level.rawValue }.joined(separator: ","),
          "low,low")
} catch {
    failures += 1; print("  FAIL threw \(error)")
}

// ------------------------------------------------------------- forward compat

print("\nunknown future model + threshold fallback")
do {
    let snap = try makeSnapshot(from: load("future.json"))
    check("unknown model abbreviates", snap.metrics.map(\.shortLabel).joined(separator: ","),
          "5h,wk,qu,op")
    check("scoped sorted by percent desc",
          snap.metrics.map { Int($0.percent.rounded()) }.map(String.init).joined(separator: ","),
          "3,50,88,20")
    check("88 is high", snap.metrics[2].level == .high)
    check("50 is moderate", snap.metrics[1].level == .moderate)
    check("3.4 is low", snap.metrics[0].level == .low)
    check("20 is low", snap.metrics[3].level == .low)
    check("bar", bar(snap), "5h 3%  wk 50%  qu 88%  op 20%")
} catch {
    failures += 1; print("  FAIL threw \(error)")
}

// -------------------------------------------------------------- degenerate

print("\ndegenerate input")
do {
    _ = try makeSnapshot(from: Data("{\"limits\":[]}".utf8))
    failures += 1; print("  FAIL empty limits should throw")
} catch {
    checks += 1; print("  ok   empty limits throws")
}
do {
    _ = try makeSnapshot(from: Data("not json".utf8))
    failures += 1; print("  FAIL garbage should throw")
} catch {
    checks += 1; print("  ok   garbage throws")
}
do {
    // A limit with no percent must be skipped, not crash or render as 0.
    let json = #"{"limits":[{"kind":"session","percent":null},{"kind":"weekly_all","percent":7}]}"#
    let snap = try makeSnapshot(from: Data(json.utf8))
    check("null percent skipped", bar(snap), "wk 7%")
} catch {
    failures += 1; print("  FAIL threw \(error)")
}

// -------------------------------------------------------------- helpers

print("\nhelpers")
check("abbreviate Fable", abbreviate("Fable"), "fb")
check("abbreviate Opus", abbreviate("Opus"), "op")
check("abbreviate Sonnet", abbreviate("Sonnet"), "so")
check("abbreviate Haiku", abbreviate("Haiku"), "ha")
check("abbreviate unknown", abbreviate("Quokka 7"), "qu")
check("abbreviate strips digits", abbreviate("3Beta"), "be")
check("retry-after seconds", parseRetryAfter("120") == 120)
check("retry-after zero", parseRetryAfter("0") == 0)
check("retry-after negative clamped", parseRetryAfter("-5") == 0)
check("retry-after whitespace", parseRetryAfter("  45 ") == 45)
check("retry-after http-date parses",
      parseRetryAfter("Wed, 09 Sep 2026 23:59:59 GMT") != nil)
check("retry-after past date clamps to zero",
      parseRetryAfter("Wed, 09 Sep 2020 00:00:00 GMT") == 0)
check("retry-after nil", parseRetryAfter(nil) == nil)
check("retry-after junk", parseRetryAfter("soon") == nil)
check("retry-after empty", parseRetryAfter("   ") == nil)
check("millisecond timestamp", parseTimestamp("2026-09-12T07:59:59.645+00:00") != nil)
check("no-fraction timestamp", parseTimestamp("2026-09-12T07:59:59+00:00") != nil)
check("nil timestamp", parseTimestamp(nil) == nil)
check("junk timestamp", parseTimestamp("tomorrow") == nil)
check("0 -> low",           UsageLevel.forPercent(0) == .low)
check("49.9 -> low",        UsageLevel.forPercent(49.9) == .low)
check("50 -> moderate",     UsageLevel.forPercent(50) == .moderate)
check("74.9 -> moderate",   UsageLevel.forPercent(74.9) == .moderate)
check("75 -> high",         UsageLevel.forPercent(75) == .high)
check("89.9 -> high",       UsageLevel.forPercent(89.9) == .high)
check("90 -> critical",     UsageLevel.forPercent(90) == .critical)
check("100 -> critical",    UsageLevel.forPercent(100) == .critical)
check("over 100 -> critical", UsageLevel.forPercent(140) == .critical)

// -------------------------------------------------------------- pacing

print("\nfetch pacing")
do {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var p = FetchPacer(basePollInterval: 180, maxBackoff: 1800)

    check("first fetch allowed immediately", p.allows(.scheduled, now: t0))

    p.recordSuccess(now: t0)
    check("scheduled waits out the interval", !p.allows(.scheduled, now: t0.addingTimeInterval(60)))
    check("scheduled allowed after the interval", p.allows(.scheduled, now: t0.addingTimeInterval(180)))
    check("menu open does not skip pacing", !p.allows(.menuOpened, now: t0.addingTimeInterval(60)))
    check("manual skips our own pacing", p.allows(.manual, now: t0.addingTimeInterval(1)))
    // The regression this suite exists to catch: a switch stranded behind the
    // poll interval left the app showing nothing until the window elapsed.
    check("account switch skips our own pacing",
          p.allows(.accountSwitch, now: t0.addingTimeInterval(1)))

    // A 429 binds everything, including the triggers that skip local pacing.
    p.recordFailure(.rateLimited(retryAfter: 300), now: t0)
    check("429 blocks scheduled", !p.allows(.scheduled, now: t0.addingTimeInterval(10)))
    check("429 blocks manual", !p.allows(.manual, now: t0.addingTimeInterval(10)))
    check("429 blocks account switch too",
          !p.allows(.accountSwitch, now: t0.addingTimeInterval(10)))
    check("429 honours Retry-After", p.allows(.scheduled, now: t0.addingTimeInterval(300)))
    check("429 not yet clear before Retry-After",
          !p.allows(.scheduled, now: t0.addingTimeInterval(299)))

    var q = FetchPacer(basePollInterval: 180, maxBackoff: 1800)
    q.recordFailure(.rateLimited(retryAfter: 5), now: t0)
    check("Retry-After floored at 60s", !q.allows(.scheduled, now: t0.addingTimeInterval(59)))

    var r = FetchPacer(basePollInterval: 180, maxBackoff: 1800)
    r.recordFailure(.network("down"), now: t0)
    check("first network failure waits one interval",
          !r.allows(.scheduled, now: t0.addingTimeInterval(179)))
    check("network failure does not block a switch",
          r.allows(.accountSwitch, now: t0.addingTimeInterval(1)))
    r.recordFailure(.network("down"), now: t0)
    check("second failure doubles", !r.allows(.scheduled, now: t0.addingTimeInterval(359)))
    for _ in 0..<12 { r.recordFailure(.network("down"), now: t0) }
    check("backoff caps at maxBackoff", r.allows(.scheduled, now: t0.addingTimeInterval(1800)))

    r.recordSuccess(now: t0)
    check("success clears the rate-limit flag", r.allows(.manual, now: t0.addingTimeInterval(1)))
    check("success resets the backoff", r.allows(.scheduled, now: t0.addingTimeInterval(180)))
    check("waitRemaining nil once allowed", r.waitRemaining(now: t0.addingTimeInterval(180)) == nil)
    check("waitRemaining reports the gap", r.waitRemaining(now: t0.addingTimeInterval(120)) == 60)
}

// -------------------------------------------------------------- projection

print("\nhistory keeping")
do {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ h: Double, _ p: Double) -> Sample {
        Sample(at: t0.addingTimeInterval(h * 3600), percent: p)
    }

    var h: [Sample] = []
    h = HistoryPolicy.append(at(0, 10), to: h)
    check("first sample kept", h.count == 1)
    h = HistoryPolicy.append(at(0.1, 11), to: h)
    check("too soon is dropped", h.count == 1)
    h = HistoryPolicy.append(at(0.6, 14), to: h)
    check("past the spacing is kept", h.count == 2)
    // A reset must land immediately or the old window pollutes the fit.
    h = HistoryPolicy.append(at(0.7, 2), to: h)
    check("a reset is kept regardless of spacing", h.count == 3)

    var big: [Sample] = []
    for i in 0..<250 { big = HistoryPolicy.append(at(Double(i), 50), to: big) }
    check("history is capped", big.count == HistoryPolicy.maximumSamples)
    check("the cap drops the oldest", big.first!.at > t0)

    let spanning = [at(0, 80), at(1, 90), at(2, 5), at(3, 12)]
    check("current window starts after the reset",
          HistoryPolicy.currentWindow(spanning).count == 2)
    check("no reset means the whole history",
          HistoryPolicy.currentWindow([at(0, 5), at(1, 9)]).count == 2)
    check("one sample survives", HistoryPolicy.currentWindow([at(0, 5)]).count == 1)
}

print("\nburn-rate projection")
do {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ h: Double, _ p: Double) -> Sample {
        Sample(at: t0.addingTimeInterval(h * 3600), percent: p)
    }
    let now = t0.addingTimeInterval(4 * 3600)

    check("nothing from a single sample",
          project(history: [at(0, 10)], currentPercent: 10, resetsAt: nil, now: now) == nil)
    check("nothing from too short a span",
          project(history: [at(3.8, 10), at(3.9, 11)], currentPercent: 11,
                  resetsAt: nil, now: now) == nil)
    check("nothing when already full",
          project(history: [at(0, 90), at(2, 100)], currentPercent: 100,
                  resetsAt: nil, now: now) == nil)
    check("nothing when flat",
          project(history: [at(0, 40), at(2, 40)], currentPercent: 40,
                  resetsAt: nil, now: now) == nil)
    check("nothing when falling",
          project(history: [at(0, 60), at(2, 40)], currentPercent: 40,
                  resetsAt: nil, now: now) == nil)

    // 10 points an hour, at 40% with 4 hours in hand.
    let steady = [at(0, 0), at(1, 10), at(2, 20), at(3, 30), at(4, 40)]
    let p = project(history: steady, currentPercent: 40, resetsAt: nil, now: now)
    check("rate recovered", p.map { Int($0.ratePerHour.rounded()) } ?? -1, 10)
    let hoursOut = p.map { Int(($0.exhaustsAt.timeIntervalSince(now) / 3600).rounded()) } ?? -1
    check("exhaustion six hours out", "\(hoursOut)", "6")

    let early = t0.addingTimeInterval(7 * 3600)     // reset before we run out
    let late = t0.addingTimeInterval(40 * 3600)     // reset after
    check("reset before exhaustion is not a warning",
          project(history: steady, currentPercent: 40, resetsAt: early, now: now)?.beforeReset == false)
    check("exhaustion before reset is a warning",
          project(history: steady, currentPercent: 40, resetsAt: late, now: now)?.beforeReset == true)

    // Only the current window should feed the fit.
    let acrossReset = [at(0, 70), at(1, 85), at(2, 5), at(3, 10), at(4, 15)]
    let p2 = project(history: acrossReset, currentPercent: 15, resetsAt: late, now: now)
    check("the fit ignores the previous window",
          p2.map { Int($0.ratePerHour.rounded()) } ?? -1, 5)

    check("no text without a warning", projectionText(nil) == nil)
    check("no text when the reset wins",
          projectionText(project(history: steady, currentPercent: 40, resetsAt: early, now: now),
                         now: now) == nil)
    check("text when it matters",
          projectionText(project(history: steady, currentPercent: 40, resetsAt: late, now: now),
                         now: now) ?? "nil", "at this rate, out in 6h 0m")
}

// -------------------------------------------------------------- store format

print("\nstore survives a format change")
do {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970

    // Exactly what 1.3.x wrote: no history, no notified. Synthesised Codable
    // threw on these missing keys and emptied the store; that must not recur.
    let oldFormat = #"""
    {"version":1,"accounts":[{"uuid":"a","email":"x@y.z","addedAt":1700000000,
     "accessToken":"tok","refreshToken":"ref","expiresAt":1700003600}]}
    """#
    if let file = try? decoder.decode(AccountsFile.self, from: Data(oldFormat.utf8)) {
        check("an older file still decodes", file.accounts.count, 1)
        check("identity survives", file.accounts.first?.email ?? "", "x@y.z")
        check("credentials survive", file.accounts.first?.refreshToken ?? "", "ref")
        check("fields added later default", file.accounts.first?.history.isEmpty == true)
        check("and so do the alert flags", file.accounts.first?.notified.isEmpty == true)
    } else {
        failures += 5; print("  FAIL older file did not decode at all")
    }

    // A file with nothing but a uuid is still a usable account.
    let minimal = #"{"accounts":[{"uuid":"b"}]}"#
    check("a minimal account decodes",
          (try? decoder.decode(AccountsFile.self, from: Data(minimal.utf8)))?.accounts.count ?? 0, 1)

    // One unreadable entry must not take the rest with it.
    let mixed = #"{"accounts":[{"uuid":"good"},{"nope":true},{"uuid":"alsogood"}]}"#
    check("a bad entry is skipped, not fatal",
          (try? decoder.decode(AccountsFile.self, from: Data(mixed.utf8)))?.accounts.count ?? 0, 2)

    // Round trip.
    var file = AccountsFile()
    file.pinnedUUID = "a"
    file.accounts = [StoredAccount(uuid: "a", email: "x@y.z", org: "Org", plan: "Max",
                                   accessToken: "tok", refreshToken: "ref",
                                   expiresAt: Date(timeIntervalSince1970: 1_700_003_600),
                                   addedAt: Date(timeIntervalSince1970: 1_700_000_000))]
    if let data = try? encoder.encode(file),
       let back = try? decoder.decode(AccountsFile.self, from: data) {
        check("round trip keeps the pin", back.pinnedUUID ?? "", "a")
        check("round trip keeps the token", back.accounts.first?.accessToken ?? "", "tok")
    } else {
        failures += 2; print("  FAIL round trip")
    }
}

// -------------------------------------------------------------- alerting

print("\nalert thresholds")
check("silent below the first", thresholdCrossed(percent: 40, alreadyNotified: nil) == nil)
check("fires at 50", Int(thresholdCrossed(percent: 50, alreadyNotified: nil) ?? -1), 50)
check("fires at 75 after 50", Int(thresholdCrossed(percent: 80, alreadyNotified: 50) ?? -1), 75)
// A jump past several thresholds is one alert about the highest, not three.
check("a jump alerts once, highest",
      Int(thresholdCrossed(percent: 95, alreadyNotified: nil) ?? -1), 90)
check("silent while sitting above one already announced",
      thresholdCrossed(percent: 91, alreadyNotified: 90) == nil)
check("silent at exactly the announced threshold",
      thresholdCrossed(percent: 90, alreadyNotified: 90) == nil)
check("100 still announces 90 once",
      Int(thresholdCrossed(percent: 100, alreadyNotified: 75) ?? -1), 90)
check("a rollover is a reset", resetsNotifications(previousPercent: 92, currentPercent: 3))
check("a small dip is not a reset",
      !resetsNotifications(previousPercent: 92, currentPercent: 90))

print("\nrecording a reading")
do {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func snap(_ percent: Double, _ at: Date) -> Snapshot {
        Snapshot(metrics: [Metric(kind: "weekly_all", shortLabel: "wk",
                                  longLabel: "Weekly (all models)",
                                  percent: percent,
                                  level: UsageLevel.forPercent(percent),
                                  resetsAt: t0.addingTimeInterval(48 * 3600))],
                 fetchedAt: at)
    }

    var file = AccountsFile()
    file.accounts = [StoredAccount(uuid: "a", email: "x@y.z", org: nil, plan: nil,
                                   accessToken: nil, refreshToken: nil, expiresAt: nil,
                                   addedAt: t0)]

    check("quiet under the first threshold", file.record(snap(20, t0), for: "a").isEmpty)
    check("history started", file.accounts[0].history["weekly_all"]?.count ?? 0, 1)

    let crossing = file.record(snap(78, t0.addingTimeInterval(3600)), for: "a")
    check("crossing alerts", crossing.count, 1)
    check("alerts on the highest passed", Int(crossing.first?.threshold ?? -1), 75)
    check("alert carries the label", crossing.first?.label ?? "", "Weekly (all models)")

    check("no repeat while still above",
          file.record(snap(80, t0.addingTimeInterval(7200)), for: "a").isEmpty)
    check("the next threshold still alerts",
          Int(file.record(snap(93, t0.addingTimeInterval(10800)), for: "a").first?.threshold ?? -1), 90)

    // After the window rolls over the same thresholds must be able to fire again.
    _ = file.record(snap(4, t0.addingTimeInterval(14400)), for: "a")
    check("notification state cleared by a rollover",
          file.accounts[0].notified["weekly_all"] == nil)
    check("and it can alert again next cycle",
          Int(file.record(snap(55, t0.addingTimeInterval(18000)), for: "a").first?.threshold ?? -1), 50)

    check("an unknown account records nothing", file.record(snap(50, t0), for: "nope").isEmpty)
    check("the snapshot is stored", file.accounts[0].lastSnapshot != nil)
}

// -------------------------------------------------------------- updates

print("\nversion comparison")
check("plain", SemVer("1.1.0")?.description ?? "nil", "1.1.0")
check("leading v", SemVer("v1.1.0")?.description ?? "nil", "1.1.0")
check("short form", SemVer("v1.2")?.description ?? "nil", "1.2")
check("junk rejected", SemVer("banana") == nil)
check("empty rejected", SemVer("") == nil)
check("negative rejected", SemVer("1.-2.0") == nil)
check("1.2 equals 1.2.0", SemVer("v1.2")! == SemVer("1.2.0")!)
// The classic sort bug: string ordering puts 1.10 before 1.9.
check("1.10.0 beats 1.9.0", SemVer("1.9.0")! < SemVer("1.10.0")!)
check("2.0.0 beats 1.99.99", SemVer("1.99.99")! < SemVer("2.0.0")!)
check("prerelease suffix ignored", SemVer("1.2.0-beta.1")?.description ?? "nil", "1.2.0")

check("newest of a list", newestTag(["v1.0.0", "v1.10.0", "v1.9.0", "v1.2.0"]) ?? "nil", "v1.10.0")
check("newest ignores junk", newestTag(["nightly", "v1.1.0", "latest"]) ?? "nil", "v1.1.0")
check("newest of nothing", newestTag(["nightly", "latest"]) == nil)
check("newest of empty", newestTag([]) == nil)

check("update offered when newer", updateAvailable(current: "1.1.0", latest: "v1.2.0"))
check("no update when equal", !updateAvailable(current: "1.1.0", latest: "v1.1.0"))
// A downgrade must never be auto-installed.
check("no update when older", !updateAvailable(current: "1.2.0", latest: "v1.1.0"))
check("no update from junk tag", !updateAvailable(current: "1.1.0", latest: "nightly"))
check("no update from dev build", !updateAvailable(current: "dev", latest: "v1.2.0"))

// -------------------------------------------------------------- account

print("\naccount identity")
check("switch detected on uuid change", AccountIdentity.changed(
    AccountIdentity(uuid: "a", email: "x@y.z", organization: nil, plan: nil),
    AccountIdentity(uuid: "b", email: "x@y.z", organization: nil, plan: nil)))
check("no switch on unrelated churn", !AccountIdentity.changed(
    AccountIdentity(uuid: "a", email: "x@y.z", organization: "Org", plan: "Max"),
    AccountIdentity(uuid: "a", email: "x@y.z", organization: "Renamed", plan: "Pro")))
check("sign-out is a switch", AccountIdentity.changed(
    AccountIdentity(uuid: "a", email: nil, organization: nil, plan: nil), nil))
check("email used when uuid missing", AccountIdentity.changed(
    AccountIdentity(uuid: nil, email: "a@x.z", organization: nil, plan: nil),
    AccountIdentity(uuid: nil, email: "b@x.z", organization: nil, plan: nil)))

print("\n\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
