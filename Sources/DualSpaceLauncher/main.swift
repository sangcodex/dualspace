// Embedded in every clone so Finder and manager launches share one profile.
import Foundation
import AppKit
import Darwin

let bootstrapStartedAt = Date().timeIntervalSince1970

struct LaunchConfiguration: Decodable {
    let executable: String
    let profilePath: String
    let homePath: String?
    let kind: String
    let useSandboxHome: Bool?
    let ccSwitchHome: Bool?
}

do {
    let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    let contents = binary.deletingLastPathComponent().deletingLastPathComponent()
    let configURL = contents.appendingPathComponent("Resources/DualSpaceLaunch.json")
    let config = try JSONDecoder().decode(LaunchConfiguration.self, from: Data(contentsOf: configURL))
    guard config.executable == URL(fileURLWithPath: config.executable).lastPathComponent,
          config.executable != ".", config.executable != "..", !config.executable.isEmpty else {
        throw NSError(domain: "DualSpace", code: 1, userInfo: [NSLocalizedDescriptionKey: "The copy has an invalid launch configuration."])
    }
    let executable = contents.appendingPathComponent("MacOS/\(config.executable)")
    let profile = config.useSandboxHome == true
        ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/DualSpace")
        : URL(fileURLWithPath: config.profilePath, isDirectory: true)
    let fm = FileManager.default
    let privateHome = config.homePath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? profile
    for child in ["", "Library/Application Support", "Library/Caches", "Library/Preferences", "tmp"] {
        try fm.createDirectory(at: privateHome.appendingPathComponent(child), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    try fm.createDirectory(at: profile.appendingPathComponent("Chromium"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    setenv("HOME", privateHome.path, 1)
    setenv("CFFIXED_USER_HOME", privateHome.path, 1)
    setenv("XDG_CONFIG_HOME", privateHome.appendingPathComponent("Library/Application Support").path, 1)
    setenv("XDG_CACHE_HOME", privateHome.appendingPathComponent("Library/Caches").path, 1)
    setenv("TMPDIR", privateHome.appendingPathComponent("tmp").path + "/", 1)
    setenv("DUALSPACE_PROFILE", profile.path, 1)
    if config.ccSwitchHome == true { setenv("CC_SWITCH_TEST_HOME", privateHome.path, 1) }
    let receipt: [String: Any] = ["pid": Int(getpid()), "startedAt": bootstrapStartedAt, "execAt": Date().timeIntervalSince1970, "bundlePath": contents.deletingLastPathComponent().path]
    try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: profile.appendingPathComponent("launch.json"), options: .atomic)
    var args = [executable.path]
    if config.kind == "chromium" || config.kind == "electron" { args.append("--user-data-dir=\(profile.appendingPathComponent("Chromium").path)") }
    var skipProfileValue = false
    for argument in CommandLine.arguments.dropFirst() {
        if skipProfileValue { skipProfileValue = false; continue }
        if argument == "--user-data-dir" { skipProfileValue = true; continue }
        if argument.hasPrefix("--user-data-dir=") || argument.hasPrefix("-psn_") { continue }
        args.append(argument)
    }
    let cargs = args.map { strdup($0) } + [nil]
    defer { cargs.forEach { free($0) } }
    cargs.withUnsafeBufferPointer { ptr in _ = execv(executable.path, ptr.baseAddress!) }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
} catch {
    let alert = NSAlert()
    alert.messageText = "This copy could not start"
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    alert.runModal()
    exit(1)
}
