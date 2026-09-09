import Foundation

/// One recorded reading of a single window.
struct Sample: Codable, Equatable {
    var at: Date
    var percent: Double
}

/// What the recent trend implies about running out.
struct Projection: Equatable {
    /// Percentage points consumed per hour.
    let ratePerHour: Double
    /// When the window would reach 100% at that rate.
    let exhaustsAt: Date
    /// Whether that lands before the window resets, which is the only case
    /// worth telling anyone about.
    let beforeReset: Bool
}

/// Readings are kept at a coarse spacing and a hard cap, because they live in
/// the Keychain blob alongside the accounts and it should stay small.
enum HistoryPolicy {
    static let minimumSpacing: TimeInterval = 30 * 60
    static let maximumSamples = 200

    /// Appends unless the newest sample is too recent, then trims.
    static func append(_ sample: Sample, to history: [Sample]) -> [Sample] {
        var out = history
        if let last = out.last {
            // A window reset shows up as the number falling; keep it, since
            // the old readings now describe a different window.
            let reset = sample.percent < last.percent - 5
            if !reset, sample.at.timeIntervalSince(last.at) < minimumSpacing {
                return out
            }
        }
        out.append(sample)
        if out.count > maximumSamples { out.removeFirst(out.count - maximumSamples) }
        return out
    }

    /// Only the readings belonging to the window in force now. A drop of more
    /// than a few points means the window rolled over, so anything at or
    /// before that point describes the previous one.
    static func currentWindow(_ history: [Sample]) -> [Sample] {
        guard history.count > 1 else { return history }
        var start = 0
        for i in 1..<history.count where history[i].percent < history[i - 1].percent - 5 {
            start = i
        }
        return Array(history[start...])
    }
}

/// Projects when a window runs out, from the slope of its recent readings.
///
/// Deliberately a plain least-squares fit over the current window rather than
/// anything cleverer: usage is bursty, and a model that reacted quickly would
/// promise a burnout every time someone ran a long task.
func project(history: [Sample],
             currentPercent: Double,
             resetsAt: Date?,
             now: Date = Date()) -> Projection? {

    let window = HistoryPolicy.currentWindow(history)
    guard window.count >= 2 else { return nil }
    guard currentPercent < 100 else { return nil }

    let first = window.first!
    let span = now.timeIntervalSince(first.at) / 3600
    // Too short a span and the slope is noise.
    guard span >= 0.5 else { return nil }

    // Least squares on (hours since first sample, percent).
    let points = window.map { (($0.at.timeIntervalSince(first.at)) / 3600, $0.percent) }
    let n = Double(points.count)
    let sumX = points.reduce(0) { $0 + $1.0 }
    let sumY = points.reduce(0) { $0 + $1.1 }
    let sumXY = points.reduce(0) { $0 + $1.0 * $1.1 }
    let sumXX = points.reduce(0) { $0 + $1.0 * $1.0 }
    let denominator = n * sumXX - sumX * sumX
    guard abs(denominator) > 0.0001 else { return nil }

    let rate = (n * sumXY - sumX * sumY) / denominator
    guard rate > 0.05 else { return nil }   // flat or falling: nothing to say

    let hoursLeft = (100 - currentPercent) / rate
    guard hoursLeft.isFinite, hoursLeft >= 0 else { return nil }
    let exhaustsAt = now.addingTimeInterval(hoursLeft * 3600)

    let beforeReset = resetsAt.map { exhaustsAt < $0 } ?? false
    return Projection(ratePerHour: rate, exhaustsAt: exhaustsAt, beforeReset: beforeReset)
}

/// Human phrasing for a projection, or nil when there is nothing worth saying.
func projectionText(_ projection: Projection?, now: Date = Date()) -> String? {
    guard let p = projection, p.beforeReset else { return nil }
    let seconds = p.exhaustsAt.timeIntervalSince(now)
    guard seconds > 0 else { return "running out now" }
    let hours = Int(seconds / 3600)
    if hours >= 24 { return "at this rate, out in \(hours / 24)d \(hours % 24)h" }
    if hours >= 1 { return "at this rate, out in \(hours)h \(Int(seconds / 60) % 60)m" }
    return "at this rate, out in \(Int(seconds / 60))m"
}


// MARK: - Alert thresholds

/// Default points at which crossing is worth interrupting someone.
let defaultThresholds: [Double] = [50, 75, 90]

/// The threshold to announce now, or nil for silence.
///
/// Only ever announces the highest threshold reached, and never one already
/// announced for this window — so a jump from 40% to 95% gives one alert about
/// 90, not three, and sitting at 91% gives none at all.
func thresholdCrossed(percent: Double,
                      alreadyNotified: Double?,
                      thresholds: [Double] = defaultThresholds) -> Double? {
    let reached = thresholds.filter { percent >= $0 }.max()
    guard let hit = reached else { return nil }
    if let last = alreadyNotified, hit <= last { return nil }
    return hit
}

/// A window that rolled over should be able to alert again.
func resetsNotifications(previousPercent: Double, currentPercent: Double) -> Bool {
    currentPercent < previousPercent - 5
}
