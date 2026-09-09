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
