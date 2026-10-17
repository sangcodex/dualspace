// Composition root for the window, menu bar, store and runtime.
import SwiftUI
import AppKit
import DualSpaceCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main struct DualSpaceApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    init() {
        let root = ProcessInfo.processInfo.environment["DUALSPACE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? (Bundle.main.object(forInfoDictionaryKey: "DualSpaceWorkspace") as? String).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DualSpace")
        let launcher = Bundle.main.resourceURL?.appendingPathComponent("DualSpaceLauncher")
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("DualSpaceLauncher")
        let store = CloneStore(root: root, launcher: launcher, runner: CommandRunner())
        _model = StateObject(wrappedValue: AppModel(store: store, runtime: InstanceRuntime()))
    }

    var body: some Scene {
        WindowGroup("DualSpace", id: "main") {
            MainView(model: model)
                .frame(minWidth: 900, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1100, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Instance…") { model.chooseApp() }.keyboardShortcut("n")
                    .disabled(model.working != nil)
                Button("Refresh Library") { Task { await model.reload(refreshLibrary: true) } }.keyboardShortcut("r")
            }
            CommandGroup(before: .sidebar) {
                Button(model.sidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar") {
                    withAnimation(.easeInOut(duration: 0.18)) { model.sidebarCollapsed.toggle() }
                }.keyboardShortcut("s", modifiers: [.command, .control])
            }
        }
        MenuBarExtra("DualSpace", systemImage: "square.on.square") {
            Button("Open DualSpace") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            ForEach(model.instances) { record in
                Button(record.name + " — " + model.state(for: record).phase.label) {
                    Task { await model.act(.launch, on: record) }
                }.disabled(model.working != nil || model.state(for: record).phase.isBusy || model.state(for: record).phase == .missing)
            }
            Divider()
            Button("New Instance…") { model.chooseApp() }.disabled(model.working != nil)
            Button("Quit DualSpace") { NSApp.terminate(nil) }
        }
    }
}
