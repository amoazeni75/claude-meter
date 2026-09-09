import Cocoa

// Colours and formatting shared by the menu, the bar and the desktop panel.

extension UsageLevel {
    /// Colour for the percentage. Labels beside it stay neutral, so the only
    /// thing carrying colour is the number the colour is about.
    var color: NSColor {
        switch self {
        case .low:      return .systemGreen
        case .moderate: return .usageYellow
        case .high:     return .systemOrange
        case .critical: return .systemRed
        }
    }
}

extension NSColor {
    /// systemYellow is tuned for fills; as text on a light menu bar it is
    /// close to invisible. Keep it in dark mode, darken it to a gold in light.
    static let usageYellow = NSColor(name: "usageYellow") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemYellow
            : NSColor(srgbRed: 0.62, green: 0.47, blue: 0.02, alpha: 1)
    }
}

func gauge(_ percent: Double, width: Int = 12) -> String {
    let filled = Int((percent / 100.0 * Double(width)).rounded())
    let f = max(0, min(width, filled))
    return String(repeating: "█", count: f) + String(repeating: "░", count: width - f)
}

func pad(_ s: String, _ n: Int) -> String {
    let c = s.count
    return c >= n ? s : s + String(repeating: " ", count: n - c)
}

func clip(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : String(s.prefix(n - 1)) + "…"
}

func resetText(_ date: Date?) -> String {
    guard let date = date else { return "" }
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "resetting…" }
    let h = secs / 3600, m = (secs % 3600) / 60
    if h >= 24 { return "resets in \(h / 24)d \(h % 24)h" }
    if h > 0 { return "resets in \(h)h \(m)m" }
    return "resets in \(m)m"
}

func agoText(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 5 { return "just now" }
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}
