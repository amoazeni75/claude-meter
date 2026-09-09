import Foundation

/// The app's version, read from the bundle so Info.plist stays the only place
/// it is written down. Falls back only when running the binary outside a
/// bundle, which is the test harness.
let appVersion: String = {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}()
