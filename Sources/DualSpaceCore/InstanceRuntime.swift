// Launch Services integration resolves instances by both identity and managed path.
import Foundation
import AppKit
import Darwin

/// Injects process observation and lifecycle operations into the manager.
/// Example: pass InstanceRuntime() to AppModel's runtime parameter.
@MainActor public protocol InstanceRunning {
    func processID(_ record: CloneRecord, at url: URL) -> Int32?
    func launch(_ record: CloneRecord, at url: URL) async throws -> Int32
    func quit(_ record: CloneRecord, at url: URL) async throws
}

/// Starts and observes managed apps without substituting a running original.
/// Example: try await InstanceRuntime().launch(record, at: store.appURL(record))
@MainActor public final class InstanceRuntime: InstanceRunning {
    public init() {}

    public func processID(_ record: CloneRecord, at url: URL) -> Int32? {
        Self.running(record, at: url)?.processIdentifier
    }

    public static func running(_ record: CloneRecord, at url: URL) -> NSRunningApplication? {
        var candidates = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == record.bundleID || $0.executableURL?.lastPathComponent == record.source.executable
        }
        if record.usesSandbox != true {
            let receiptURL = url.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Profiles/\(record.id.uuidString.lowercased())/launch.json")
            if let data = try? Data(contentsOf: receiptURL),
               let receipt = try? JSONDecoder().decode(ProcessReceipt.self, from: data), receipt.pid > 0,
               let app = NSRunningApplication(processIdentifier: receipt.pid) { candidates.append(app) }
        }
        return candidates.first { app in
            guard !app.isTerminated else { return false }
            if let actual = app.bundleURL, matchesBundle(record, managed: url, actual: actual) { return true }
            // After exec, Launch Services may no longer identify the bootstrap
            // bundle. Recover its root from the observed executable, then apply
            // the same path, marker, and translocation checks.
            guard let executable = app.executableURL,
                  executable.deletingLastPathComponent().lastPathComponent == "MacOS",
                  executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents" else { return false }
            let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return matchesBundle(record, managed: url, actual: bundle)
        }
    }

    private struct ProcessReceipt: Decodable { let pid: Int32 }

    nonisolated static func matchesBundle(_ record: CloneRecord, managed: URL, actual: URL) -> Bool {
        let expected = managed.standardizedFileURL.resolvingSymlinksInPath()
        let observed = actual.standardizedFileURL.resolvingSymlinksInPath()
        let isTranslocation = isTranslocatedPath(observed)
        guard observed == expected || (isTranslocation && observed.lastPathComponent == expected.lastPathComponent) else { return false }
        guard let info = try? readPlist(observed.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == record.bundleID,
              info["DualSpaceInstanceID"] as? String == record.id.uuidString else { return false }
        if observed == expected { return true }
        // App Translocation uses a read-only loopback mount. On the observed
        // host it preserves file inodes while changing the volume identifier.
        guard isTranslocation,
              (try? observed.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true,
              let executable = info["CFBundleExecutable"] as? String,
              executable == URL(fileURLWithPath: executable).lastPathComponent else { return false }
        return sameInode(expected, observed) && sameInode(
            expected.appendingPathComponent("Contents/MacOS/\(executable)"),
            observed.appendingPathComponent("Contents/MacOS/\(executable)"))
    }

    nonisolated static func isTranslocatedPath(_ url: URL) -> Bool {
        // Foundation can retain either system alias, depending on whether
        // the full path still exists. Identity and mount checks follow.
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return (path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/"))
            && path.contains("/AppTranslocation/")
    }

    private nonisolated static func sameInode(_ one: URL, _ two: URL) -> Bool {
        var first = stat(), second = stat()
        return stat(one.path, &first) == 0 && stat(two.path, &second) == 0 && first.st_ino == second.st_ino
    }

    public func launch(_ record: CloneRecord, at url: URL) async throws -> Int32 {
        if let current = Self.running(record, at: url) {
            current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return current.processIdentifier
        }
        let options = NSWorkspace.OpenConfiguration()
        options.createsNewApplicationInstance = true
        options.allowsRunningApplicationSubstitution = false
        options.activates = true
        let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: options) { application, error in
                if let error { continuation.resume(throwing: error) }
                else if let application { continuation.resume(returning: application) }
                else { continuation.resume(throwing: SpaceError.message("Launch Services did not return a process.")) }
            }
        }
        if let current = Self.running(record, at: url) { return current.processIdentifier }
        // An exec bootstrap can retire the launch callback's app object before
        // the replacement is registered. An accepted request is not a crash.
        return app.isTerminated ? 0 : app.processIdentifier
    }

    public func quit(_ record: CloneRecord, at url: URL) async throws {
        guard let app = Self.running(record, at: url) else { return }
        guard app.terminate() else { throw SpaceError.message("The app declined the quit request. Quit it from its own menu.") }
        for _ in 0..<40 {
            if app.isTerminated { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw SpaceError.message("The app is still quitting. Finish any open dialogs in its window.")
    }
}
