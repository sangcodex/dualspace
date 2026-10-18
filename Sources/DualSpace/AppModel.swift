// UI state observes live processes; it never calls a process launch a verified account login.
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import DualSpaceCore

enum InstanceAction { case launch, quit, refresh, verify, remove }
struct Notice: Identifiable { let id = UUID(); let text: String; let isError: Bool; let instanceID: UUID? }
struct RenameRequest: Identifiable { let record: CloneRecord; var id: UUID { record.id } }

@MainActor final class AppModel: ObservableObject {
    let store: CloneStore
    let runtime: any InstanceRunning
    @Published var instances: [CloneRecord] = []
    @Published var applications: [AppDescriptor] = []
    @Published private(set) var states: [UUID: InstanceState] = [:]
    @Published private(set) var loadingInstances = true
    @Published private(set) var loadingLibrary = false
    @Published var outdated = Set<UUID>()
    @Published var missing = Set<UUID>()
    @Published var section = "instances"
    @Published var search = ""
    @Published var working: String?
    @Published var notice: Notice?
    @Published var draft: AppDescriptor?
    @Published var draftName = ""
    @Published var inspection: Inspection?
    @Published private(set) var inspectionError: String?
    @Published var renameRequest: RenameRequest?
    @Published var removeRequest: CloneRecord?
    @Published var activity: [String] = []
    @Published var sidebarCollapsed: Bool {
        didSet { preferences.set(sidebarCollapsed, forKey: "sidebarCollapsed") }
    }
    private let preferences: UserDefaults
    private var transitions: [UUID: InstancePhase] = [:]
    private var failures: [UUID: InstanceState] = [:]
    private var observers = Set<AnyCancellable>()
    private var reloadGeneration = 0

    init(store: CloneStore, runtime: any InstanceRunning,
         workspaceEvents: NotificationCenter = NSWorkspace.shared.notificationCenter,
         applicationEvents: NotificationCenter = .default,
         preferences: UserDefaults = .standard) {
        self.store = store
        self.runtime = runtime
        self.preferences = preferences
        self.sidebarCollapsed = preferences.bool(forKey: "sidebarCollapsed")
        Publishers.Merge(
            workspaceEvents.publisher(for: NSWorkspace.didLaunchApplicationNotification),
            workspaceEvents.publisher(for: NSWorkspace.didTerminateApplicationNotification)
        ).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }.store(in: &observers)
        applicationEvents.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.reload() }
            }.store(in: &observers)
        // Exec-based apps can disappear from Launch Services notifications.
        Timer.publish(every: 2, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshStatus() }
            .store(in: &observers)
    }

    var pids: [UUID: Int32] { states.compactMapValues(\.pid) }
    func state(for record: CloneRecord) -> InstanceState { states[record.id] ?? InstanceState() }

    var filteredInstances: [CloneRecord] {
        instances.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.source.name.localizedCaseInsensitiveContains(search) }
    }
    var filteredApps: [AppDescriptor] {
        applications.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
    }

    func reload(refreshLibrary: Bool = false) async {
        reloadGeneration += 1
        let generation = reloadGeneration
        do {
            let records = try await store.list()
            guard generation == reloadGeneration else { return }
            if records != instances { instances = records }
            loadingInstances = false
            let ids = Set(records.map(\.id))
            transitions = transitions.filter { ids.contains($0.key) }
            failures = failures.filter { ids.contains($0.key) }
            refreshStatus()
            var stale = Set<UUID>()
            for record in records {
                if await store.isOutdated(record) { stale.insert(record.id) }
            }
            guard generation == reloadGeneration else { return }
            if outdated != stale { outdated = stale }
        }
        catch {
            guard generation == reloadGeneration else { return }
            loadingInstances = false
            report(error.localizedDescription, error: true)
        }
        if (applications.isEmpty || refreshLibrary) && !loadingLibrary {
            loadingLibrary = true
            applications = await Task.detached(priority: .utility) {
                let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
                return roots.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] }
                    .compactMap { try? AppDescriptor.read($0) }
                    .filter { $0.bundleID != "local.dualspace.manager" }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }.value
            loadingLibrary = false
        }
    }

    func refreshStatus() {
        var observed: [UUID: InstanceState] = [:]
        var absent = Set<UUID>()
        for record in instances {
            let url = store.appURL(record)
            let pid = runtime.processID(record, at: url)
            let exists = FileManager.default.fileExists(atPath: url.path)
            if !exists { absent.insert(record.id) }
            if let failure = failures[record.id], failure.pid != pid {
                failures.removeValue(forKey: record.id)
                if notice?.isError == true && notice?.instanceID == record.id { notice = nil }
            }
            let failure = failures[record.id]
            let phase = transitions[record.id]
                ?? (pid != nil ? .running : (!exists ? .missing : (failure != nil ? .failed : .stopped)))
            observed[record.id] = InstanceState(phase: phase, pid: pid, error: failure?.error)
        }
        if states != observed { states = observed }
        if missing != absent { missing = absent }
    }

    func chooseApp() {
        guard working == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an application to copy"
        panel.prompt = "Choose App"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        select(url)
    }

    func select(_ url: URL) {
        guard working == nil else { return }
        do {
            let app = try AppDescriptor.read(url)
            inspection = nil
            inspectionError = nil
            notice = nil
            let count = instances.filter { $0.source.bundleID == app.bundleID }.count
            draftName = app.name + (count == 0 ? " Work" : " \(count + 2)")
            draft = app
            Task {
                do {
                    let result = try await store.inspect(source: url)
                    if draft?.path == app.path { inspection = result }
                } catch {
                    if draft?.path == app.path {
                        inspectionError = error.localizedDescription
                        report(error.localizedDescription, error: true)
                    }
                }
            }
        } catch { report(error.localizedDescription, error: true) }
    }

    func create() async {
        guard let source = draft, working == nil else { return }
        let name = draftName
        working = "Creating \(name)…"
        defer { working = nil }
        do {
            let record = try await store.create(source: URL(fileURLWithPath: source.path), name: name)
            draft = nil
            section = "instances"
            search = ""
            report("\(record.name) is ready. Open it and sign in with another account.")
            await reload()
        } catch { report(error.localizedDescription, error: true) }
    }

    func act(_ action: InstanceAction, on record: CloneRecord) async {
        guard working == nil else { return }
        working = action == .launch ? "Opening \(record.name)…" : "Working on \(record.name)…"
        defer {
            transitions.removeValue(forKey: record.id)
            refreshStatus()
            working = nil
        }
        notice = nil
        if action == .launch || action == .quit {
            failures.removeValue(forKey: record.id)
            if action == .quit { transitions[record.id] = .stopping }
            else if runtime.processID(record, at: store.appURL(record)) == nil { transitions[record.id] = .starting }
            refreshStatus()
        }
        do {
            switch action {
            case .launch:
                if runtime.processID(record, at: store.appURL(record)) == nil {
                    _ = try await store.preflight(id: record.id)
                }
                _ = try await runtime.launch(record, at: store.appURL(record))
                try await confirmLaunch(record)
                transitions.removeValue(forKey: record.id)
                refreshStatus()
                report("Opened \(record.name). The app runs independently of DualSpace.")
            case .quit:
                try await runtime.quit(record, at: store.appURL(record))
                transitions.removeValue(forKey: record.id)
                refreshStatus()
                report("\(record.name) has quit.")
            case .refresh:
                _ = try await store.refresh(id: record.id)
                report("\(record.name) was rebuilt. Its identity and profile were kept.")
            case .verify:
                try await store.verify(id: record.id)
                report("\(record.name): application identity and code signature passed verification.")
            case .remove:
                try await store.remove(id: record.id)
                report("\(record.name) was removed from the list. Its profile and a recoverable copy were kept.")
            }
            await reload()
        } catch {
            if action == .launch || action == .quit {
                failures[record.id] = InstanceState(phase: .failed,
                    pid: runtime.processID(record, at: store.appURL(record)), error: error.localizedDescription)
            }
            report(error.localizedDescription, error: true, instanceID: record.id)
        }
    }

    private func confirmLaunch(_ record: CloneRecord) async throws {
        // Only a pending launch has a bounded reconciliation loop. Exec may
        // replace the callback process before Launch Services registers it.
        var previous: Int32?
        var stable = 0
        for _ in 0..<40 {
            try Task.checkCancellation()
            let pid = runtime.processID(record, at: store.appURL(record))
            stable = pid != nil && pid == previous ? stable + 1 : 0
            if stable >= 5 { return }
            previous = pid
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw SpaceError.message("Startup could not be confirmed. The app may have exited or may still need attention. Try opening it again or check Compatibility Details.")
    }

    func rename(_ record: CloneRecord, to name: String) async {
        guard working == nil else { return }
        working = "Renaming \(record.name)…"
        defer { working = nil }
        do {
            _ = try await store.refresh(id: record.id, name: name)
            renameRequest = nil
            report("The instance was renamed. Its account profile was kept.")
            await reload()
        } catch { report(error.localizedDescription, error: true) }
    }

    func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else { report("This location will be created on the instance's first launch.") }
    }

    func openOriginal(_ record: CloneRecord) {
        let config = NSWorkspace.OpenConfiguration()
        config.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: record.source.path), configuration: config) { _, error in
            if let error { Task { @MainActor in self.report(error.localizedDescription, error: true) } }
        }
    }

    func report(_ text: String, error: Bool = false, instanceID: UUID? = nil) {
        notice = Notice(text: text, isError: error, instanceID: instanceID)
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        activity.insert("\(stamp)  \(text)", at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }
    }
}
