// Validates recovery of exec-launched processes without trusting stale receipts.
import XCTest
import AppKit
@testable import DualSpaceCore

final class RuntimeIdentityTests: XCTestCase {
    @MainActor func testStaleReceiptFindsOwnedProcessAndNeverSelectsAnUnrelatedPID() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DualSpaceRuntime-\(UUID())").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let source = AppDescriptor(path: "/unused", bundleID: "test.browser", name: "Example", version: "1", build: "1", executable: "Example", kind: .chromium)
        let record = CloneRecord(id: UUID(), name: "Example", source: source, createdAt: Date(), updatedAt: Date(), notes: [], usesSandbox: false, appFileName: "Example.app")
        let app = root.appendingPathComponent("Applications/Example.app")
        let main = app.appendingPathComponent("Contents/MacOS/Example")
        try fm.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: main)
        try writePlist(["CFBundleIdentifier": record.bundleID, "DualSpaceInstanceID": record.id.uuidString, "CFBundleExecutable": "Example"], to: app.appendingPathComponent("Contents/Info.plist"))
        _ = try await CommandRunner().checked("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        let owned = Process(), unrelated = Process()
        owned.executableURL = main
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        for process in [owned, unrelated] {
            process.arguments = ["30"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
        defer {
            for process in [owned, unrelated] where process.isRunning { process.terminate() }
        }
        let profile = root.appendingPathComponent("Profiles/\(record.id.uuidString.lowercased())")
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["pid": unrelated.processIdentifier]).write(to: profile.appendingPathComponent("launch.json"))
        let runtime = InstanceRuntime()
        XCTAssertEqual(runtime.processID(record, at: app), owned.processIdentifier)
        XCTAssertFalse(InstanceRuntime.matchesProcess(unrelated.processIdentifier, record: record, managed: app))
        XCTAssertFalse(InstanceRuntime.matchesProcess(-1, record: record, managed: app))
        owned.terminate()
        for _ in 0..<100 {
            if !InstanceRuntime.matchesProcess(owned.processIdentifier, record: record, managed: app) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(runtime.processID(record, at: app))
    }

    func testSystemCodeCopyRequiresMatchingSystemNamespaceAndBundleName() {
        let source = AppDescriptor(path: "/unused", bundleID: "test.browser", name: "Example", version: "1", build: "1", executable: "Example", kind: .chromium)
        let record = CloneRecord(id: UUID(), name: "Example", source: source, createdAt: Date(), updatedAt: Date(), notes: [])
        let managed = URL(fileURLWithPath: "/managed/Example.app")
        let suffix = "/X/\(record.bundleID).code_sign_clone/code_sign_clone.sample/Example.app.bundle"
        XCTAssertTrue(InstanceRuntime.isSystemCodeCopy(URL(fileURLWithPath: "/private/var/folders/sample" + suffix), record: record, managed: managed))
        XCTAssertFalse(InstanceRuntime.isSystemCodeCopy(URL(fileURLWithPath: "/tmp" + suffix), record: record, managed: managed))
        XCTAssertFalse(InstanceRuntime.isSystemCodeCopy(URL(fileURLWithPath: "/private/var/folders/sample" + suffix.replacingOccurrences(of: record.bundleID, with: "another.instance")), record: record, managed: managed))
        XCTAssertFalse(InstanceRuntime.isSystemCodeCopy(URL(fileURLWithPath: "/private/var/folders/sample" + suffix.replacingOccurrences(of: "Example.app", with: "Other.app")), record: record, managed: managed))
    }
}
