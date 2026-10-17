// Owns managed copies and commits bundle replacements together with their manifest.
import Foundation
import Darwin

private final class WorkspaceLock {
    private let descriptor: Int32
    init(root: URL) throws {
        descriptor = Darwin.open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SpaceError.message("The workspace lock could not be opened.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw SpaceError.message("Another operation is using this workspace. Wait for it to finish.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

/// Stores stable copies under an explicitly owned directory.
/// Example: let store = CloneStore(root: workspace, launcher: launcherURL, runner: CommandRunner())
/// let instance = try await store.create(source: sourceURL, name: "WeChat Work")
public actor CloneStore {
    public nonisolated let root: URL
    public nonisolated let launcher: URL
    let runner: any CommandRunning
    let fm = FileManager.default

    public init(root: URL, launcher: URL, runner: any CommandRunning) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.launcher = launcher.standardizedFileURL
        self.runner = runner
    }

    public nonisolated func appURL(_ record: CloneRecord) -> URL {
        root.appendingPathComponent("Applications/\(record.folderName)")
    }

    public nonisolated func profileURL(_ record: CloneRecord) -> URL {
        if record.usesSandbox == true {
            let container = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/\(record.bundleID)/Data")
            return record.nativeSandbox ? container : container.appendingPathComponent("Library/Application Support/DualSpace")
        }
        return root.appendingPathComponent("Profiles/\(record.id.uuidString.lowercased())")
    }

    public func list() throws -> [CloneRecord] {
        try ensureDirectories()
        return try load().instances.sorted { $0.createdAt < $1.createdAt }
    }

    public func inspect(source: URL) async throws -> Inspection {
        try await AppInspector(runner: runner).inspect(source)
    }

    public func create(source: URL, name: String) async throws -> CloneRecord {
        try ensureDirectories()
        let lock = try WorkspaceLock(root: root)
        defer { withExtendedLifetime(lock) {} }
        var manifest = try load()
        let name = try uniqueName(name, in: manifest)
        let report = try await inspect(source: source)
        try requireReadableEntitlements(report)
        guard !report.app.path.hasPrefix(root.path + "/") else {
            throw SpaceError.message("Select an original application outside the managed workspace.")
        }
        let now = Date()
        let id = UUID()
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let fileName = (safeName.isEmpty ? "Instance" : safeName) + "-" + id.uuidString.prefix(8).lowercased() + ".app"
        let record = CloneRecord(id: id, name: name, source: report.app, createdAt: now, updatedAt: now, notes: report.notes, usesSandbox: report.copyUsesSandbox, appFileName: fileName)
        let work = try makeStaging()
        defer { try? fm.removeItem(at: work) }
        let staged = work.appendingPathComponent("Copy.app")
        try await build(record, at: staged, temporary: work)
        let destination = appURL(record)
        try fm.moveItem(at: staged, to: destination)
        do {
            manifest.instances.append(record)
            try save(manifest)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        return record
    }

    public func refresh(id: UUID, name: String? = nil) async throws -> CloneRecord {
        try ensureDirectories()
        let lock = try WorkspaceLock(root: root)
        defer { withExtendedLifetime(lock) {} }
        var manifest = try load()
        guard let index = manifest.instances.firstIndex(where: { $0.id == id }) else { throw missing() }
        var record = manifest.instances[index]
        try await ensureStopped(record)
        if let name { record.name = try uniqueName(name, in: manifest, excluding: id) }
        let report = try await inspect(source: URL(fileURLWithPath: record.source.path))
        try requireReadableEntitlements(report)
        guard report.app.bundleID == record.source.bundleID else {
            throw SpaceError.message("The source application's identity changed. Select it again as a new application.")
        }
        record.source = report.app
        record.notes = report.notes
        // Missing metadata belongs to the original private-home format. A
        // rebuild must never silently switch the account's storage location.
        record.usesSandbox = record.usesSandbox ?? false
        if record.usesSandbox != report.copyUsesSandbox {
            record.notes = report.notes.filter { !$0.hasPrefix("This WeChat copy uses") && !$0.hasPrefix("The copy uses a distinct") && !$0.hasPrefix("A private home is configured") }
            record.notes.append(record.usesSandbox == true
                ? "This instance retains its existing macOS sandbox container. Its data location has not been migrated."
                : "This instance retains its existing private home. Its data location has not been migrated.")
        }
        record.updatedAt = Date()
        let work = try makeStaging()
        defer { try? fm.removeItem(at: work) }
        let staged = work.appendingPathComponent("Copy.app")
        try await build(record, at: staged, temporary: work)
        // A launch may have happened while signing. Re-check before replacing files.
        try await ensureStopped(record)
        let destination = appURL(record)
        let backup = work.appendingPathComponent("Previous.bundle")
        let existed = fm.fileExists(atPath: destination.path)
        if existed { try fm.moveItem(at: destination, to: backup) }
        do {
            try fm.moveItem(at: staged, to: destination)
            manifest.instances[index] = record
            try save(manifest)
        } catch {
            try? fm.removeItem(at: destination)
            if existed { try? fm.moveItem(at: backup, to: destination) }
            throw error
        }
        return record
    }

    public func remove(id: UUID) async throws {
        try ensureDirectories()
        let lock = try WorkspaceLock(root: root)
        defer { withExtendedLifetime(lock) {} }
        var manifest = try load()
        guard let record = manifest.instances.first(where: { $0.id == id }) else { throw missing() }
        try await ensureStopped(record)
        let destination = appURL(record)
        let retired = root.appendingPathComponent("Retired/\(id.uuidString)-\(UUID().uuidString).bundle")
        let existed = fm.fileExists(atPath: destination.path)
        if existed { try fm.moveItem(at: destination, to: retired) }
        do {
            manifest.instances.removeAll { $0.id == id }
            try save(manifest)
            let recovery = retired.deletingPathExtension().appendingPathExtension("json")
            try? encoder().encode(record).write(to: recovery, options: .atomic)
        } catch {
            if existed { try? fm.moveItem(at: retired, to: destination) }
            throw error
        }
    }

    public func verify(id: UUID) async throws {
        try ensureDirectories()
        guard let record = try load().instances.first(where: { $0.id == id }) else { throw missing() }
        try await validate(record, at: appURL(record))
    }

    public func preflight(id: UUID) throws -> CloneRecord {
        try ensureDirectories()
        guard let record = try load().instances.first(where: { $0.id == id }) else { throw missing() }
        let url = appURL(record)
        let info = try readPlist(url.appendingPathComponent("Contents/Info.plist"))
        guard info["CFBundleIdentifier"] as? String == record.bundleID,
              info["DualSpaceInstanceID"] as? String == id.uuidString,
              let executable = info["CFBundleExecutable"] as? String,
              executable == URL(fileURLWithPath: executable).lastPathComponent,
              fm.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/\(executable)").path) else {
            throw SpaceError.message("The instance is incomplete. Rebuild it from the original application.")
        }
        return record
    }

    public func isOutdated(_ record: CloneRecord) -> Bool {
        guard let source = try? AppDescriptor.read(URL(fileURLWithPath: record.source.path)) else { return false }
        return source.version != record.source.version || source.build != record.source.build
    }

    private func uniqueName(_ raw: String, in manifest: Manifest, excluding: UUID? = nil) throws -> String {
        let name = try checkedName(raw)
        guard !manifest.instances.contains(where: { $0.id != excluding && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw SpaceError.message("An instance already uses that name. Choose another name.")
        }
        return name
    }

    private func ensureDirectories() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["Applications", "Profiles", "Staging", "Retired"] {
            let url = root.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isDirectory == true,
                      url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                    throw SpaceError.message("The managed \(name) directory is not a regular local directory.")
                }
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        }
    }

    private func load() throws -> Manifest {
        let url = root.appendingPathComponent("instances.json")
        guard fm.fileExists(atPath: url.path) else { return Manifest() }
        do {
            let value = try decoder().decode(Manifest.self, from: Data(contentsOf: url))
            guard value.schemaVersion == 1, Set(value.instances.map(\.id)).count == value.instances.count else {
                throw SpaceError.message("Unsupported or duplicate instance metadata.")
            }
            guard value.instances.allSatisfy({ $0.folderName == URL(fileURLWithPath: $0.folderName).lastPathComponent && $0.folderName.hasSuffix(".app") && !$0.folderName.hasPrefix(".") }) else {
                throw SpaceError.message("The manifest contains an invalid app filename.")
            }
            return value
        } catch {
            throw SpaceError.message("The instance manifest could not be read. It has been preserved: \(error.localizedDescription)")
        }
    }

    private func save(_ manifest: Manifest) throws {
        try encoder().encode(manifest).write(to: root.appendingPathComponent("instances.json"), options: .atomic)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeStaging() throws -> URL {
        let url = root.appendingPathComponent("Staging/\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func missing() -> SpaceError { .message("This instance no longer exists. Refresh the list.") }

    private func requireReadableEntitlements(_ inspection: Inspection) throws {
        guard inspection.sandboxed != nil else {
            throw SpaceError.message("The source signing permissions could not be read in this environment. No copy was published. Try creating it in the DualSpace app outside the restricted terminal.")
        }
    }

    private func ensureStopped(_ record: CloneRecord) async throws {
        let running = await MainActor.run { InstanceRuntime.running(record, at: self.appURL(record)) != nil }
        guard !running else { throw SpaceError.message("Quit \(record.name) before changing its application files.") }
    }
}
