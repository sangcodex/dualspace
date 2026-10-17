// Embedded in every clone so Finder and manager launches share one profile.
import Foundation
import AppKit
import Darwin

let bootstrapStartedAt = Date().timeIntervalSince1970

struct LaunchConfiguration: Decodable {
    let executable: String
    let profilePath: String
    let kind: String
    let useSandboxHome: Bool?
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
    for child in ["", "Library/Application Support", "Library/Caches", "Library/Preferences", "tmp", "Chromium"] {
        try fm.createDirectory(at: profile.appendingPathComponent(child), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    setenv("HOME", profile.path, 1)
    setenv("CFFIXED_USER_HOME", profile.path, 1)
    setenv("XDG_CONFIG_HOME", profile.appendingPathComponent("Library/Application Support").path, 1)
    setenv("XDG_CACHE_HOME", profile.appendingPathComponent("Library/Caches").path, 1)
    setenv("TMPDIR", profile.appendingPathComponent("tmp").path + "/", 1)
    setenv("DUALSPACE_PROFILE", profile.path, 1)
    let receipt: [String: Any] = ["pid": Int(getpid()), "startedAt": bootstrapStartedAt, "execAt": Date().timeIntervalSince1970, "bundlePath": contents.deletingLastPathComponent().path]
    try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: profile.appendingPathComponent("launch.json"), options: .atomic)
    var args = [executable.path]
    if config.kind == "chromium" { args.append("--user-data-dir=\(profile.appendingPathComponent("Chromium").path)") }
    args += CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("--user-data-dir") }
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
