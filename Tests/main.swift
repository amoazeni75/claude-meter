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
