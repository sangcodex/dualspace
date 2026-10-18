// Launch Services integration resolves instances by both identity and managed path.
import Foundation
import AppKit
import Darwin
import Security

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
        Self.observe(record, at: url)?.pid
    }

    public static func running(_ record: CloneRecord, at url: URL) -> NSRunningApplication? {
        observe(record, at: url)?.app
    }

    private static func observe(_ record: CloneRecord, at url: URL) -> (pid: Int32, app: NSRunningApplication?)? {
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == record.bundleID || $0.executableURL?.lastPathComponent == record.source.executable
        }
        for app in applications where app.processIdentifier > 0 && !app.isTerminated {
            if matchesProcess(app.processIdentifier, record: record, managed: url) {
                return (app.processIdentifier, app)
            }
        }
        // An exec-launched browser can have a valid window but an AppKit PID
        // of -1. Recover the PID from its receipt, then verify the live kernel
        // executable path; a stale receipt must never select another process.
        let receiptURL: URL
        if record.usesSandbox == true && !record.nativeSandbox {
            receiptURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/\(record.bundleID)/Data/Library/Application Support/DualSpace/launch.json")
        } else {
            receiptURL = url.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Profiles/\(record.id.uuidString.lowercased())/launch.json")
        }
        if let data = try? Data(contentsOf: receiptURL),
           let receipt = try? JSONDecoder().decode(ProcessReceipt.self, from: data),
           matchesProcess(receipt.pid, record: record, managed: url) {
            return (receipt.pid, NSRunningApplication(processIdentifier: receipt.pid))
        }
        if record.usesBootstrap || applications.contains(where: { $0.processIdentifier <= 0 }) {
            // A second Finder launch can overwrite the receipt and then hand
            // off to the first process. Recover the first process by its exact
            // live executable path before permitting a rebuild or another launch.
            let capacity = max(0, proc_listallpids(nil, 0)) + 64
            var pids = [Int32](repeating: 0, count: Int(capacity))
            let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
            for pid in pids.prefix(max(0, min(Int(count), pids.count))) {
                if matchesProcess(pid, record: record, managed: url) {
                    return (pid, NSRunningApplication(processIdentifier: pid))
                }
            }
        }
        return nil
    }

    private struct ProcessReceipt: Decodable { let pid: Int32 }

    nonisolated static func matchesProcess(_ pid: Int32, record: CloneRecord, managed: URL) -> Bool {
        guard pid > 0 else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let executable = URL(fileURLWithPath: String(cString: path))
        guard executable.lastPathComponent == record.source.executable,
              executable.deletingLastPathComponent().lastPathComponent == "MacOS",
              executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents" else { return false }
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if matchesBundle(record, managed: managed, actual: bundle) { return true }
        guard isSystemCodeCopy(bundle, record: record, managed: managed),
              let info = try? readPlist(bundle.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == record.bundleID,
              info["DualSpaceInstanceID"] as? String == record.id.uuidString else { return false }
        // macOS can run exec targets from a code_sign_clone cache, without a
        // usable AppKit PID. Bind that cache to the live signed process and the
        // managed executable's code digest, not just a directory name or plist.
        var live: SecCode?
        var liveStatic: SecStaticCode?
        var expected: SecStaticCode?
        let main = managed.appendingPathComponent("Contents/MacOS/\(record.source.executable)")
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &live) == errSecSuccess,
              let live, SecCodeCheckValidity(live, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(live, [], &liveStatic) == errSecSuccess,
              SecStaticCodeCreateWithPath(main as CFURL, [], &expected) == errSecSuccess,
              let liveStatic, let expected,
              let digest = signingDigest(liveStatic) else { return false }
        return digest == signingDigest(expected)
    }

    nonisolated static func isSystemCodeCopy(_ bundle: URL, record: CloneRecord, managed: URL) -> Bool {
        let path = bundle.standardizedFileURL.resolvingSymlinksInPath()
        return (path.path.hasPrefix("/private/var/folders/") || path.path.hasPrefix("/var/folders/"))
            && path.lastPathComponent == managed.lastPathComponent + ".bundle"
            && path.deletingLastPathComponent().lastPathComponent.hasPrefix("code_sign_clone.")
            && path.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == record.bundleID + ".code_sign_clone"
            && path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "X"
    }

    private nonisolated static func signingDigest(_ code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
    }

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
        if let current = Self.observe(record, at: url) {
            current.app?.activate(options: [.activateAllWindows])
            return current.pid
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
        if let current = Self.observe(record, at: url) { return current.pid }
        // An exec bootstrap can retire the launch callback's app object before
        // the replacement is registered. An accepted request is not a crash.
        return app.isTerminated ? 0 : max(0, app.processIdentifier)
    }

    public func quit(_ record: CloneRecord, at url: URL) async throws {
        guard let observed = Self.observe(record, at: url) else { return }
        guard let app = observed.app, app.terminate() else { throw SpaceError.message("The app declined the quit request. Quit it from its own menu.") }
        for _ in 0..<40 {
            if !Self.matchesProcess(observed.pid, record: record, managed: url) { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw SpaceError.message("The app is still quitting. Finish any open dialogs in its window.")
    }
}
