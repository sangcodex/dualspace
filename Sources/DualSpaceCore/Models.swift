// Shared application metadata and stable per-instance identity.
import Foundation

public enum AppKind: String, Codable, Sendable {
    case native, chromium

    public var label: String { self == .chromium ? "Chromium / Electron" : "Native app" }
    public var isolation: String {
        self == .chromium ? "Dedicated browser profile" : "Private home; app data needs verification"
    }
}

/// Reads bundle metadata without caching it across an application update.
/// Example: let app = try AppDescriptor.read(URL(fileURLWithPath: "/Applications/WeChat.app"))
public struct AppDescriptor: Codable, Sendable, Identifiable, Equatable {
    public let path: String
    public let bundleID: String
    public let name: String
    public let version: String
    public let build: String
    public let executable: String
    public let kind: AppKind
    public var id: String { path }
    public var release: String { "\(version) (\(build))" }

    public static func read(_ input: URL) throws -> AppDescriptor {
        let url = input.standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "app",
              !url.path.hasPrefix("/System/"),
              !url.path.hasPrefix("/Applications/Safari.app") else {
            throw SpaceError.message("Choose a third-party .app. Protected system apps cannot be cloned.")
        }
        let info = try readPlist(url.appendingPathComponent("Contents/Info.plist"))
        guard let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable == URL(fileURLWithPath: executable).lastPathComponent,
              executable != ".", executable != "..",
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/\(executable)").path) else {
            throw SpaceError.message("The app has no valid bundle identifier or executable.")
        }
        guard info["DualSpaceInstanceID"] == nil else {
            throw SpaceError.message("Choose the original application, rather than an existing DualSpace copy.")
        }
        let fm = FileManager.default
        let isChromium = fm.fileExists(atPath: url.appendingPathComponent("Contents/Resources/app.asar").path)
            || fm.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
            || fm.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Google Chrome Framework.framework").path)
            || (info["NSPrincipalClass"] as? String) == "AtomApplication"
        return AppDescriptor(
            path: url.path, bundleID: bundleID,
            name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent,
            version: (info["CFBundleShortVersionString"] as? String) ?? "Unknown",
            build: (info["CFBundleVersion"] as? String) ?? "Unknown",
            executable: executable, kind: isChromium ? .chromium : .native
        )
    }
}

public struct CloneRecord: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var source: AppDescriptor
    public let createdAt: Date
    public var updatedAt: Date
    public var notes: [String]
    public var usesSandbox: Bool?
    public var appFileName: String?
    public var nativeSandbox: Bool { source.kind == .native && usesSandbox == true }
    var privateWeChat: Bool { source.bundleID == "com.tencent.xinWeChat" && source.kind == .native && usesSandbox != true }
    var usesBootstrap: Bool { !nativeSandbox && !privateWeChat }
    public var bundleID: String { "local.dualspace.instance.i" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    public var folderName: String { appFileName ?? (id.uuidString.lowercased() + ".app") }
}

struct Manifest: Codable {
    var schemaVersion = 1
    var instances: [CloneRecord] = []
}

public struct Inspection: Sendable {
    public let app: AppDescriptor
    public let notes: [String]
    public let sandboxed: Bool?
    public var copyUsesSandbox: Bool { sandboxed == true && app.bundleID != "com.tencent.xinWeChat" }
}

public enum SpaceError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

func readPlist(_ url: URL) throws -> [String: Any] {
    guard let result = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else {
        throw SpaceError.message("Invalid property list: \(url.lastPathComponent)")
    }
    return result
}

func writePlist(_ value: [String: Any], to url: URL) throws {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url, options: .atomic)
}

func checkedName(_ value: String) throws -> String {
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 64, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw SpaceError.message("Use a name between 1 and 64 characters, without control characters.")
    }
    return name
}
