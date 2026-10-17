// A visible integration fixture records the Foundation home and persistent launch count.
import AppKit

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let workspace = Bundle.main.object(forInfoDictionaryKey: "ProbeWorkspaceRoot") as! String
            let home = NSHomeDirectory()
            let managed = Bundle.main.object(forInfoDictionaryKey: "DualSpaceInstanceID") != nil
            let dataRoot = managed || home.hasPrefix(workspace + "/") ? URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/ProfileProbe") : URL(fileURLWithPath: workspace).appendingPathComponent("ProbeOriginal")
            try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            let stateURL = dataRoot.appendingPathComponent("state.json")
            let previous = (try? JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))) as? [String: Any] ?? [:]
            let count = (previous["launchCount"] as? Int ?? 0) + 1
            let state: [String: Any] = ["launchCount": count, "foundationHome": home, "environmentHome": ProcessInfo.processInfo.environment["HOME"] ?? "", "profile": ProcessInfo.processInfo.environment["DUALSPACE_PROFILE"] ?? "original", "bundleID": Bundle.main.bundleIdentifier ?? "unknown", "readyAt": Date().timeIntervalSince1970, "pid": Int(getpid())]
            try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(to: stateURL, options: .atomic)
            let label = NSTextField(wrappingLabelWithString: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Profile Probe")\n\nLaunch count: \(count)\n\nFoundation home:\n\(home)\n\nState file:\n\(stateURL.path)")
            label.font = .systemFont(ofSize: 15)
            label.frame = NSRect(x: 25, y: 20, width: 650, height: 280)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 320), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Profile Probe"
            window.contentView?.addSubview(label)
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = ProbeDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
