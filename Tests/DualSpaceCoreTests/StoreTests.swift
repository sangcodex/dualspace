// These tests inject signing failures; real signing and UI checks use the probe example.
import XCTest
@testable import DualSpaceCore

private actor StubRunner: CommandRunning {
    var failSigning = false
    var pauseCopy = false
    var copyStarted = false
    var copyGate: CheckedContinuation<Void, Never>?
    var observer: CheckedContinuation<Void, Never>?
    var signedTargets: [String] = []
    var unreadableEntitlements = false
    var reportedSandbox = false
    var signedSandboxFlags: [String: Bool] = [:]
    var signedJITFlags: [String: Bool] = [:]

    func setFailure(_ value: Bool) { failSigning = value }
    func pauseNextCopy() { pauseCopy = true; copyStarted = false }
    func waitForCopy() async {
        if copyStarted { return }
        await withCheckedContinuation { observer = $0 }
    }
    func releaseCopy() { copyGate?.resume(); copyGate = nil; pauseCopy = false }
    func targets() -> [String] { signedTargets }
    func setUnreadableEntitlements() { unreadableEntitlements = true }
    func setReportedSandbox(_ value: Bool) { reportedSandbox = value }
    func sandboxFlags() -> [String: Bool] { signedSandboxFlags }
    func jitFlags() -> [String: Bool] { signedJITFlags }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        if arguments.contains("-d") && unreadableEntitlements {
            return CommandResult(status: 0, output: Data(), error: Data("warning: binary contains an invalid entitlements blob".utf8))
        }
        if arguments.contains("-d") && reportedSandbox {
            let data = try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.app-sandbox": true, "com.apple.security.cs.allow-jit": true], format: .xml, options: 0)
            return CommandResult(status: 0, output: data, error: Data())
        }
        if executable == "/bin/cp" {
            if pauseCopy {
                copyStarted = true
                observer?.resume(); observer = nil
                await withCheckedContinuation { copyGate = $0 }
            }
            return try await CommandRunner().run(executable, arguments, timeout: timeout)
        }
        if arguments.contains("--force") {
            if let path = arguments.last { signedTargets.append(path) }
            if let index = arguments.firstIndex(of: "--entitlements"), index + 1 < arguments.count, let target = arguments.last {
                let entitlements = try readPlist(URL(fileURLWithPath: arguments[index + 1]))
                signedSandboxFlags[target] = entitlements["com.apple.security.app-sandbox"] as? Bool ?? false
                signedJITFlags[target] = entitlements["com.apple.security.cs.allow-jit"] as? Bool ?? false
            }
            if failSigning { return CommandResult(status: 1, output: Data(), error: Data("Injected signing failure".utf8)) }
        }
        return CommandResult(status: 0, output: Data(), error: Data())
    }
}

final class StoreTests: XCTestCase {
    private var base: URL!
    private var source: URL!
    private var runner: StubRunner!
    private var store: CloneStore!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("DualSpaceTests-\(UUID())")
        source = base.appendingPathComponent("Original.app")
        let executable = source.appendingPathComponent("Contents/MacOS/Example")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try writePlist(["CFBundleIdentifier": "test.original", "CFBundleExecutable": "Example", "CFBundleName": "Example", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"], to: source.appendingPathComponent("Contents/Info.plist"))
        runner = StubRunner()
        store = CloneStore(root: base.appendingPathComponent("Workspace"), launcher: URL(fileURLWithPath: "/usr/bin/true"), runner: runner)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }

    func testDistinctCopiesKeepSourceAndUseDifferentProfiles() async throws {
        let before = try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist"))
        let one = try await store.create(source: source, name: "Work")
        let two = try await store.create(source: source, name: "Personal")
        XCTAssertNotEqual(one.bundleID, two.bundleID)
        XCTAssertNotEqual(store.profileURL(one), store.profileURL(two))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist")), before)
        let count = try await store.list().count
        XCTAssertEqual(count, 2)
    }

    func testRenamedElectronFrameworkIsDetectedByPrincipalClass() throws {
        let infoURL = source.appendingPathComponent("Contents/Info.plist")
        var info = try readPlist(infoURL)
        info["NSPrincipalClass"] = "AtomApplication"
        try writePlist(info, to: infoURL)
        XCTAssertEqual(try AppDescriptor.read(source).kind, .electron)
    }

    func testElectronKeepsHelperProductNameAndUsesPrivateHome() async throws {
        let infoURL = source.appendingPathComponent("Contents/Info.plist")
        var info = try readPlist(infoURL)
        info["NSPrincipalClass"] = "AtomApplication"
        info["ElectronTeamID"] = "VENDOR"
        try writePlist(info, to: infoURL)
        await runner.setReportedSandbox(true)
        let framework = source.appendingPathComponent("Contents/Frameworks/Electron Framework.framework/Resources/Info.plist")
        try FileManager.default.createDirectory(at: framework.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePlist(["CFBundleIdentifier": "test.original.framework"], to: framework)
        let record = try await store.create(source: source, name: "Electron Work")
        let copied = try readPlist(store.appURL(record).appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(copied["CFBundleName"] as? String, "Example")
        XCTAssertEqual(copied["CFBundleDisplayName"] as? String, "Electron Work")
        XCTAssertTrue((copied["CFBundleExecutable"] as? String)?.hasPrefix("DualSpaceBoot-") == true)
        XCTAssertNil(copied["ElectronTeamID"])
        let launch = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.appURL(record).appendingPathComponent("Contents/Resources/DualSpaceLaunch.json"))) as? [String: Any])
        XCTAssertEqual(launch["homePath"] as? String, store.homeURL(record).path)
        XCTAssertFalse(record.runsInSandbox)
        let copiedFramework = store.appURL(record).appendingPathComponent("Contents/Frameworks/Electron Framework.framework/Resources/Info.plist")
        XCTAssertEqual(try readPlist(copiedFramework)["CFBundleIdentifier"] as? String, "test.original.framework")
        let flags = await runner.sandboxFlags()
        XCTAssertFalse(flags.values.contains(true))
        let jit = await runner.jitFlags()
        XCTAssertEqual(jit.first(where: { $0.key.hasSuffix("/Frameworks/Electron Framework.framework") })?.value, true)
    }

    func testLegacyElectronRebuildKeepsContainerAndProfileLocations() async throws {
        let infoURL = source.appendingPathComponent("Contents/Info.plist")
        var info = try readPlist(infoURL)
        info["NSPrincipalClass"] = "BrowserCrApplication"
        try writePlist(info, to: infoURL)
        let original = try await store.create(source: source, name: "Legacy Electron")
        let manifestURL = store.root.appendingPathComponent("instances.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
        manifest.instances[0].usesSandbox = true
        let legacy = manifest.instances[0]
        let profile = store.profileURL(legacy)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL)
        info["NSPrincipalClass"] = "AtomApplication"
        try writePlist(info, to: infoURL)
        await runner.setReportedSandbox(true)
        let refreshed = try await store.refresh(id: original.id)
        XCTAssertEqual(refreshed.id, original.id)
        XCTAssertEqual(refreshed.source.kind, .electron)
        XCTAssertTrue(refreshed.usesBootstrap)
        XCTAssertEqual(store.profileURL(refreshed), profile)
        XCTAssertEqual(store.homeURL(refreshed), store.homeURL(legacy))
        XCTAssertFalse(refreshed.runsInSandbox)
        let configURL = store.appURL(refreshed).appendingPathComponent("Contents/Resources/DualSpaceLaunch.json")
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        XCTAssertEqual(config["homePath"] as? String, store.homeURL(legacy).path)
        XCTAssertEqual(config["profilePath"] as? String, profile.path)
        XCTAssertEqual(config["useSandboxHome"] as? Bool, false)
        let flags = await runner.sandboxFlags()
        XCTAssertFalse(flags.values.contains(true))
    }

    func testUnsupportedCCSwitchBuildFailsBeforePublishingACopy() async throws {
        let infoURL = source.appendingPathComponent("Contents/Info.plist")
        var info = try readPlist(infoURL)
        info["CFBundleIdentifier"] = "com.ccswitch.desktop"
        info["CFBundleShortVersionString"] = "3.20.4"
        try writePlist(info, to: infoURL)
        do { _ = try await store.create(source: source, name: "Unsupported"); XCTFail("Expected artifact validation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unsupported compiled single-instance lock")) }
        let records = try await store.list()
        XCTAssertTrue(records.isEmpty)
        let targets = await runner.targets()
        XCTAssertTrue(targets.isEmpty)
    }

    func testVersionedFrameworkPassesRealDeepSignatureVerification() async throws {
        let fm = FileManager.default
        let main = source.appendingPathComponent("Contents/MacOS/Example")
        try fm.removeItem(at: main)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: main)
        let framework = source.appendingPathComponent("Contents/Frameworks/Engine.framework")
        let real = CommandRunner()
        for version in ["A", "B"] {
            let directory = framework.appendingPathComponent("Versions/\(version)")
            try fm.createDirectory(at: directory.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: version == "A" ? "/usr/bin/true" : "/usr/bin/false"), to: directory.appendingPathComponent("Engine"))
            try writePlist(["CFBundleIdentifier": "test.original.engine", "CFBundleExecutable": "Engine", "CFBundlePackageType": "FMWK"], to: directory.appendingPathComponent("Resources/Info.plist"))
            _ = try await real.checked("/usr/bin/codesign", ["--force", "--sign", "-", "--requirements", "=designated => identifier \"test.original.engine\"", directory.path])
        }
        for (link, destination) in [("Versions/Current", "B"), ("Resources", "Versions/Current/Resources"), ("Engine", "Versions/Current/Engine")] {
            try fm.createSymbolicLink(atPath: framework.appendingPathComponent(link).path, withDestinationPath: destination)
        }
        _ = try await real.checked("/usr/bin/codesign", ["--force", "--sign", "-", source.path])
        let realStore = CloneStore(root: store.root, launcher: store.launcher, runner: real)
        let record = try await realStore.create(source: source, name: "Versioned Framework")
        try await realStore.verify(id: record.id)
        for version in ["A", "B"] {
            let directory = realStore.appURL(record).appendingPathComponent("Contents/Frameworks/Engine.framework/Versions/\(version)")
            _ = try await real.checked("/usr/bin/codesign", ["--verify", "--deep", "--strict", directory.path])
        }
    }

    func testRefreshAndRenamePreserveIdentityAndProfile() async throws {
        let original = try await store.create(source: source, name: "Work")
        let profile = store.profileURL(original)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let marker = profile.appendingPathComponent("account-marker")
        try Data("persistent".utf8).write(to: marker)
        let updated = try await store.refresh(id: original.id, name: "Renamed")
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.bundleID, original.bundleID)
        XCTAssertEqual(store.appURL(updated), store.appURL(original))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "persistent")
        XCTAssertEqual(updated.name, "Renamed")
    }

    func testPreflightDoesNotRequireOriginalOrRunSigning() async throws {
        let record = try await store.create(source: source, name: "Standalone")
        try FileManager.default.removeItem(at: source)
        await runner.setFailure(true)
        let ready = try await store.preflight(id: record.id)
        XCTAssertEqual(ready.id, record.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appURL(record).appendingPathComponent("Contents/MacOS/Example").path))
    }

    func testRunningIdentityRejectsAnExternalDuplicateAndIncorrectMarker() async throws {
        let record = try await store.create(source: source, name: "Identity")
        let managed = store.appURL(record)
        XCTAssertTrue(InstanceRuntime.matchesBundle(record, managed: managed, actual: managed))
        let duplicate = base.appendingPathComponent(record.folderName)
        try FileManager.default.copyItem(at: managed, to: duplicate)
        XCTAssertFalse(InstanceRuntime.matchesBundle(record, managed: managed, actual: duplicate))
        let infoURL = managed.appendingPathComponent("Contents/Info.plist")
        var info = try readPlist(infoURL)
        info["DualSpaceInstanceID"] = UUID().uuidString
        try writePlist(info, to: infoURL)
        XCTAssertFalse(InstanceRuntime.matchesBundle(record, managed: managed, actual: managed))
    }

    func testTranslocationRecognizesBothSystemPathSpellingsOnly() {
        let suffix = "/folders/test/session/T/AppTranslocation/example/d/Managed.app"
        XCTAssertTrue(InstanceRuntime.isTranslocatedPath(URL(fileURLWithPath: "/private/var" + suffix)))
        XCTAssertTrue(InstanceRuntime.isTranslocatedPath(URL(fileURLWithPath: "/var" + suffix)))
        XCTAssertFalse(InstanceRuntime.isTranslocatedPath(URL(fileURLWithPath: "/tmp" + suffix)))
        XCTAssertFalse(InstanceRuntime.isTranslocatedPath(URL(fileURLWithPath: "/var/folders/test/Managed.app")))
        XCTAssertFalse(InstanceRuntime.isTranslocatedPath(URL(fileURLWithPath: "/var/folders-other/AppTranslocation/example/d/Managed.app")))
    }

    func testWeChatDirectLaunchKeepsPrivateHomeAndMainEntitlements() async throws {
        let infoURL = source.appendingPathComponent("Contents/Info.plist")
        var info = try readPlist(infoURL)
        info["CFBundleIdentifier"] = "com.tencent.xinWeChat"
        info["TeamIdentifier"] = "5A4RE8SF68."
        info["LSEnvironment"] = ["APP_OPTION": "preserved", "HOME": "/old/home", "CFFIXED_USER_HOME": "/old/home"]
        try writePlist(info, to: infoURL)
        await runner.setReportedSandbox(true)
        let helper = source.appendingPathComponent("Contents/Helpers/Helper.app")
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: helper.appendingPathComponent("Contents/MacOS/Helper"))
        try writePlist(["CFBundleIdentifier": "com.tencent.xinWeChat.helper", "CFBundleExecutable": "Helper"], to: helper.appendingPathComponent("Contents/Info.plist"))
        let record = try await store.create(source: source, name: "WeChat Work")
        let copyInfo = try readPlist(store.appURL(record).appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(copyInfo["CFBundleExecutable"] as? String, "Example")
        let environment = try XCTUnwrap(copyInfo["LSEnvironment"] as? [String: String])
        XCTAssertEqual(environment["HOME"], store.profileURL(record).path)
        XCTAssertEqual(environment["CFFIXED_USER_HOME"], store.profileURL(record).path)
        XCTAssertEqual(environment["DUALSPACE_PROFILE"], store.profileURL(record).path)
        XCTAssertEqual(environment["APP_OPTION"], "preserved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(environment["TMPDIR"])))
        XCTAssertEqual(copyInfo["TeamIdentifier"] as? String, "")
        let handshake = record.bundleID + ".crashpad.child_port_handshake.9450.1322889.ZVZAHOYSMPKDINBC"
        XCTAssertGreaterThanOrEqual(("5A4RE8SF68." + handshake).utf8.count, 128)
        XCTAssertLessThan(handshake.utf8.count, 128)
        XCTAssertFalse(record.nativeSandbox)
        XCTAssertTrue(store.profileURL(record).path.hasPrefix(store.root.appendingPathComponent("Profiles").path + "/"))
        let flags = await runner.sandboxFlags()
        XCTAssertTrue(flags.keys.contains(where: { $0.hasSuffix("Helper.app/Contents/MacOS/Helper") }))
        XCTAssertFalse(flags.isEmpty)
        XCTAssertTrue(flags.values.allSatisfy { !$0 })
        let jit = await runner.jitFlags()
        XCTAssertEqual(jit.first(where: { $0.key.hasSuffix("/Copy.app") })?.value, true)
        XCTAssertEqual(try readPlist(infoURL)["TeamIdentifier"] as? String, "5A4RE8SF68.")
    }

    func testWeChatNamespacesAppExHelpersWithoutRenamingFrameworkResources() async throws {
        let infoURL = source.appendingPathComponent("Contents/Info.plist")
        var info = try readPlist(infoURL)
        info["CFBundleIdentifier"] = "com.tencent.xinWeChat"
        try writePlist(info, to: infoURL)
        let paths = [
            "Contents/MacOS/WeChatAppEx.app/Contents/Info.plist": "com.tencent.flue.WeChatAppEx",
            "Contents/MacOS/WeChatAppEx.app/Contents/Frameworks/Engine.framework/Versions/A/Helpers/Renderer.app/Contents/Info.plist": "com.tencent.flue.helper.renderer",
            "Contents/MacOS/WeChatAppEx.app/Contents/Frameworks/Engine.framework/Versions/A/Helpers/WeApp.app/Contents/Info.plist": "com.tencent.flue.WeApp",
            "Contents/MacOS/WeChatAppEx.app/Contents/Frameworks/Engine.framework/Versions/A/Resources/Info.plist": "com.tencent.flue.framework",
            "Contents/XPCServices/DebugHelper.xpc/Contents/Info.plist": "com.tencent.xWechat.DebugHelper"
        ]
        for (path, identifier) in paths {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writePlist(["CFBundleIdentifier": identifier], to: url)
        }
        let one = try await store.create(source: source, name: "One")
        let two = try await store.create(source: source, name: "Two")
        for (path, identifier) in paths {
            let first = try XCTUnwrap(readPlist(store.appURL(one).appendingPathComponent(path))["CFBundleIdentifier"] as? String)
            let second = try XCTUnwrap(readPlist(store.appURL(two).appendingPathComponent(path))["CFBundleIdentifier"] as? String)
            if identifier == "com.tencent.flue.framework" {
                XCTAssertEqual(first, identifier)
                XCTAssertEqual(second, identifier)
            } else {
                XCTAssertTrue(first.hasPrefix(one.bundleID + "."))
                XCTAssertTrue(second.hasPrefix(two.bundleID + "."))
                XCTAssertNotEqual(first, second)
            }
            XCTAssertEqual(try readPlist(source.appendingPathComponent(path))["CFBundleIdentifier"] as? String, identifier)
        }
    }

    func testWeChatRepairPreservesExistingIdentityAndAccountDirectory() async throws {
        let infoURL = source.appendingPathComponent("Contents/Info.plist")
        var info = try readPlist(infoURL)
        info["CFBundleIdentifier"] = "com.tencent.xinWeChat"
        try writePlist(info, to: infoURL)
        let original = try await store.create(source: source, name: "Existing WeChat")
        let profile = store.profileURL(original)
        let marker = profile.appendingPathComponent("account-marker")
        try Data("existing-account".utf8).write(to: marker)
        let copyInfoURL = store.appURL(original).appendingPathComponent("Contents/Info.plist")
        var legacyInfo = try readPlist(copyInfoURL)
        legacyInfo["TeamIdentifier"] = "5A4RE8SF68."
        legacyInfo["LSEnvironment"] = nil
        legacyInfo["CFBundleExecutable"] = "DualSpaceBoot-legacy"
        try writePlist(legacyInfo, to: copyInfoURL)
        let refreshed = try await store.refresh(id: original.id)
        XCTAssertEqual(refreshed.bundleID, original.bundleID)
        XCTAssertEqual(store.profileURL(refreshed), profile)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "existing-account")
        let repaired = try readPlist(store.appURL(refreshed).appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual((repaired["LSEnvironment"] as? [String: String])?["HOME"], profile.path)
        XCTAssertEqual(repaired["TeamIdentifier"] as? String, "")
        XCTAssertEqual(repaired["CFBundleExecutable"] as? String, "Example")
    }

    func testOtherSandboxedAppsKeepTheirOwnMainExecutableAndContainer() async throws {
        await runner.setReportedSandbox(true)
        let record = try await store.create(source: source, name: "Sandboxed")
        let info = try readPlist(store.appURL(record).appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "Example")
        XCTAssertTrue(record.nativeSandbox)
        XCTAssertTrue(store.profileURL(record).path.contains("Library/Containers/\(record.bundleID)/Data"))
    }

    func testRefreshingLegacyPrivateHomeNeverSwitchesItsDataToASandbox() async throws {
        let original = try await store.create(source: source, name: "Legacy")
        let profile = store.profileURL(original)
        let manifestURL = store.root.appendingPathComponent("instances.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
        manifest.instances[0].usesSandbox = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL)
        await runner.setReportedSandbox(true)
        let refreshed = try await store.refresh(id: original.id)
        XCTAssertEqual(refreshed.usesSandbox, false)
        XCTAssertEqual(store.profileURL(refreshed), profile)
    }

    func testRefreshingASandboxedInstanceKeepsItsExistingContainer() async throws {
        await runner.setReportedSandbox(true)
        let original = try await store.create(source: source, name: "Existing Sandbox")
        let profile = store.profileURL(original)
        await runner.setReportedSandbox(false)
        let refreshed = try await store.refresh(id: original.id)
        XCTAssertEqual(refreshed.usesSandbox, true)
        XCTAssertEqual(store.profileURL(refreshed), profile)
    }

    func testSigningFailureKeepsPreviousCopyAndManifest() async throws {
        let original = try await store.create(source: source, name: "Work")
        let before = try Data(contentsOf: store.appURL(original).appendingPathComponent("Contents/Info.plist"))
        await runner.setFailure(true)
        do {
            _ = try await store.refresh(id: original.id, name: "Changed")
            XCTFail("A signing failure must fail the update")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Injected signing failure")) }
        XCTAssertEqual(try Data(contentsOf: store.appURL(original).appendingPathComponent("Contents/Info.plist")), before)
        let records = try await store.list()
        XCTAssertEqual(records.first?.name, "Work")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("Staging").path).isEmpty)
    }

    func testFailedCreateDoesNotPublishPartialApp() async throws {
        await runner.setFailure(true)
        do { _ = try await store.create(source: source, name: "Work"); XCTFail("Expected failure") } catch { }
        let records = try await store.list()
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("Applications").path).isEmpty)
    }

    func testNestedExecutableBundleIsResignedBeforeItsContainingApp() async throws {
        let updater = source.appendingPathComponent("Contents/Frameworks/Updater.app")
        let bundle = updater.appendingPathComponent("Contents/Helpers/SoftwareUpdate.bundle")
        for directory in [updater, bundle] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try writePlist(["CFBundleIdentifier": "test.original.updater", "CFBundleExecutable": "Helper"], to: directory.appendingPathComponent("Contents/Info.plist"))
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: directory.appendingPathComponent("Contents/MacOS/Helper"))
        }
        _ = try await store.create(source: source, name: "Nested")
        let targets = await runner.targets()
        let nested = try XCTUnwrap(targets.firstIndex(where: { $0.hasSuffix("SoftwareUpdate.bundle") }))
        let parent = try XCTUnwrap(targets.firstIndex(where: { $0.hasSuffix("Updater.app") }))
        XCTAssertLessThan(nested, parent)
    }

    func testSignedNonMachOResourceIsResignedAndItsContentIsPreserved() async throws {
        let resource = source.appendingPathComponent("Contents/Frameworks/driver.json")
        try FileManager.default.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = Data("{\"driver\":\"example\"}\n".utf8)
        try content.write(to: resource)
        _ = try await CommandRunner().checked("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", resource.path], timeout: 30)
        let record = try await store.create(source: source, name: "Signed Resource")
        let targets = await runner.targets()
        XCTAssertTrue(targets.contains(where: { $0.hasSuffix("/Frameworks/driver.json") }))
        let copied = store.appURL(record).appendingPathComponent("Contents/Frameworks/driver.json")
        XCTAssertEqual(try Data(contentsOf: copied), content)
        XCTAssertEqual(try Data(contentsOf: resource), content)
    }

    func testCorruptManifestIsPreserved() async throws {
        _ = try await store.list()
        let manifest = store.root.appendingPathComponent("instances.json")
        let invalid = Data("not a manifest".utf8)
        try invalid.write(to: manifest)
        do { _ = try await store.create(source: source, name: "Work"); XCTFail("Expected failure") } catch { }
        XCTAssertEqual(try Data(contentsOf: manifest), invalid)
    }

    func testNamesCannotCollideOrBecomePaths() async throws {
        _ = try await store.create(source: source, name: "Work")
        do { _ = try await store.create(source: source, name: " work "); XCTFail("Expected duplicate-name failure") } catch { }
        let named = try await store.create(source: source, name: "../../Friendly Name")
        XCTAssertEqual(store.appURL(named).deletingLastPathComponent(), store.root.appendingPathComponent("Applications"))
        XCTAssertFalse(named.folderName.contains("/"))
    }

    func testExternalSymlinkCannotBeWrittenThrough() async throws {
        let external = base.appendingPathComponent("untouched.txt")
        try Data("keep me".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Contents/Outside"), withDestinationURL: external)
        do { _ = try await store.create(source: source, name: "Work"); XCTFail("Expected rejection") } catch { }
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "keep me")
        let records = try await store.list()
        XCTAssertTrue(records.isEmpty)
    }

    func testUnreadableEntitlementsDoNotPublishOrReplaceACopy() async throws {
        let original = try await store.create(source: source, name: "Existing")
        let manifest = store.root.appendingPathComponent("instances.json")
        let before = try Data(contentsOf: manifest)
        await runner.setUnreadableEntitlements()
        do { _ = try await store.create(source: source, name: "Unknown"); XCTFail("Expected unreadable signing permissions to stop creation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("signing permissions could not be read")) }
        do { _ = try await store.refresh(id: original.id); XCTFail("Expected unreadable signing permissions to preserve the existing copy") }
        catch { XCTAssertTrue(error.localizedDescription.contains("signing permissions could not be read")) }
        XCTAssertEqual(try Data(contentsOf: manifest), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appURL(original).path))
        let names = try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("Applications").path)
        XCTAssertEqual(names, [original.folderName])
    }

    func testManagedDirectoryCannotRedirectOutsideWorkspace() async throws {
        _ = try await store.list()
        let staging = store.root.appendingPathComponent("Staging")
        try FileManager.default.removeItem(at: staging)
        try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: base)
        do { _ = try await store.create(source: source, name: "Work"); XCTFail("Expected rejection") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testConcurrentOperationsCannotPublishOverEachOther() async throws {
        await runner.pauseNextCopy()
        let first = Task { try await store.create(source: source, name: "One") }
        await runner.waitForCopy()
        let otherStore = CloneStore(root: store.root, launcher: store.launcher, runner: runner)
        do { _ = try await otherStore.create(source: source, name: "Two"); XCTFail("Expected workspace lock") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Another operation")) }
        await runner.releaseCopy()
        _ = try await first.value
        let records = try await store.list()
        XCTAssertEqual(records.map(\.name), ["One"])
    }

    func testRemovalKeepsProfileAndRecoverableBundle() async throws {
        let record = try await store.create(source: source, name: "Work")
        let profile = store.profileURL(record)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: profile.appendingPathComponent("marker"))
        try await store.remove(id: record.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.appendingPathComponent("marker").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.appURL(record).path))
        let retired = try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("Retired").path)
        XCTAssertTrue(retired.contains(where: { $0.hasSuffix(".bundle") }))
    }
}
