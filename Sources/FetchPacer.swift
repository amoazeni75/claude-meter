import Foundation

/// Decides when the next fetch is allowed.
///
/// This is deliberately pure and clock-injectable: pacing bugs are invisible
/// until they strand the app for half an hour, so the rules are tested rather
/// than reasoned about. The distinction that matters is between *our* pacing,
/// which some triggers may skip, and a wait the *server* asked for, which
/// nothing may skip.
struct FetchPacer {

    enum Trigger {
        case scheduled      // the poll timer
        case wake           // woke from sleep
        case menuOpened
        case manual         // the Refresh Now item
        case accountSwitch  // the signed-in account changed underneath us

        /// Whether this trigger may ignore our own polling interval. It never
        /// licenses ignoring a 429.
        var overridesLocalPacing: Bool {
            switch self {
            case .scheduled, .wake, .menuOpened: return false
            case .manual, .accountSwitch:        return true
            }
        }
    }

    let basePollInterval: TimeInterval
    let maxBackoff: TimeInterval

    private(set) var nextAllowedAt: Date = .distantPast
    private(set) var consecutiveFailures: Int = 0
    /// True while the last outcome was a 429, which binds every trigger.
    private(set) var isRateLimited: Bool = false

    init(basePollInterval: TimeInterval = 180, maxBackoff: TimeInterval = 1800) {
        self.basePollInterval = basePollInterval
        self.maxBackoff = maxBackoff
    }

    func allows(_ trigger: Trigger, now: Date = Date()) -> Bool {
        if now >= nextAllowedAt { return true }
        return trigger.overridesLocalPacing && !isRateLimited
    }

    /// Seconds until the next fetch is permitted, or nil if one is permitted now.
    func waitRemaining(now: Date = Date()) -> TimeInterval? {
        let remaining = nextAllowedAt.timeIntervalSince(now)
        return remaining > 0 ? remaining : nil
    }

    mutating func recordSuccess(now: Date = Date()) {
        consecutiveFailures = 0
        isRateLimited = false
        nextAllowedAt = now.addingTimeInterval(basePollInterval)
    }

    mutating func recordFailure(_ error: UsageError, now: Date = Date()) {
        consecutiveFailures += 1
        if case .rateLimited(let retryAfter) = error {
            isRateLimited = true
            // Never sooner than the server asked, and never sooner than a
            // minute even if it asked for less.
            nextAllowedAt = now.addingTimeInterval(max(retryAfter ?? basePollInterval, 60))
        } else {
            isRateLimited = false
            let factor = pow(2.0, Double(min(consecutiveFailures - 1, 6)))
            nextAllowedAt = now.addingTimeInterval(min(basePollInterval * factor, maxBackoff))
        }
    }
}
