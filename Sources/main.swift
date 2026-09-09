import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = StatusController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
}

// One icon in the menu bar, no matter how many times it gets launched.
if let bid = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bid).count > 1 {
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only: no Dock icon, no menu bar menu
let delegate = AppDelegate()
app.delegate = delegate
app.run()
