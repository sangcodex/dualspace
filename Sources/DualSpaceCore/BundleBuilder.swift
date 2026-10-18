// Materializes a copy, namespaces its identity, and re-signs nested code from the inside out.
import Foundation
import AppKit
import Darwin

extension CloneStore {
    func build(_ record: CloneRecord, at destination: URL, temporary: URL) async throws {
        guard !record.usesBootstrap || fm.isExecutableFile(atPath: launcher.path) else {
            throw SpaceError.message("The embedded launcher is missing. Rebuild DualSpace before creating a copy.")
        }
        try Task.checkCancellation()
        let source = URL(fileURLWithPath: record.source.path)
        _ = try await runner.checked("/bin/cp", ["-cR", source.path, destination.path], timeout: 240)
        try checkSymlinks(inside: destination)
        let infoURL = destination.appendingPathComponent("Contents/Info.plist")
        var info = try readPlist(infoURL)
        let bootName = "DualSpaceBoot-" + record.id.uuidString.prefix(8).lowercased()
        guard record.source.executable != bootName else { throw SpaceError.message("The source uses a reserved executable name.") }
        if record.usesBootstrap {
            let bootURL = destination.appendingPathComponent("Contents/MacOS/\(bootName)")
            try fm.copyItem(at: launcher, to: bootURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bootURL.path)
        }
        info["CFBundleIdentifier"] = record.bundleID
        // Electron derives helper executable names from CFBundleName. Keep
        // the runtime product name; CFBundleDisplayName labels the copy.
        if !record.source.kind.usesChromium { info["CFBundleName"] = record.name }
        info["CFBundleDisplayName"] = record.name
        info["CFBundleExecutable"] = record.usesBootstrap ? bootName : record.source.executable
        info["DualSpaceInstanceID"] = record.id.uuidString
        info["CFBundleDocumentTypes"] = nil
        info["UTExportedTypeDeclarations"] = nil
        info["UTImportedTypeDeclarations"] = nil
        info["SUEnableAutomaticChecks"] = false
        info["SUAutomaticallyUpdate"] = false
        info["SUAllowsAutomaticUpdates"] = false
        if !record.runsInSandbox && !record.usesBootstrap {
            try configurePrivateHome(record, info: &info)
        }
        if record.source.kind == .electron {
            info["ElectronTeamID"] = nil
        }
        if record.source.bundleID == "com.ccswitch.desktop" {
            try await NativeCompatibility().prepareCCSwitch(record, at: destination, runner: runner)
            info["DualSpaceNativeIdentity"] = NativeCompatibility.ccSwitchIdentity(record.id)
            info["LSArchitecturePriority"] = ["arm64"]
        }
        if var types = info["CFBundleURLTypes"] as? [[String: Any]] {
            let suffix = "-ds-" + record.id.uuidString.prefix(8).lowercased()
            for index in types.indices {
                types[index]["CFBundleURLName"] = record.bundleID
                if let schemes = types[index]["CFBundleURLSchemes"] as? [String] {
                    types[index]["CFBundleURLSchemes"] = schemes.map { $0 + suffix }
                }
            }
            info["CFBundleURLTypes"] = types
        }
        try writePlist(info, to: infoURL)
        try rewriteNestedIdentities(in: destination, sourceID: record.source.bundleID, targetID: record.bundleID)
        let config: [String: Any] = ["executable": record.source.executable, "profilePath": profileURL(record).path, "homePath": homeURL(record).path, "kind": record.source.kind.rawValue, "useSandboxHome": record.runsInSandbox, "ccSwitchHome": record.source.bundleID == "com.ccswitch.desktop"]
        let resources = destination.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: resources.appendingPathComponent("DualSpaceLaunch.json"), options: .atomic)
        try addIcon(record, to: destination)
        try await signCode(in: destination, record: record, temporary: temporary)
        try await validate(record, at: destination)
        guard try AppDescriptor.read(source) == record.source else {
            throw SpaceError.message("The source app changed while the copy was being built. Try again after its update finishes.")
        }
        try Task.checkCancellation()
    }

    private func configurePrivateHome(_ record: CloneRecord, info: inout [String: Any]) throws {
        let profile = homeURL(record)
        for child in ["", "Library/Application Support", "Library/Caches", "Library/Preferences", "tmp"] {
            let directory = profile.appendingPathComponent(child)
            let resolved = directory.resolvingSymlinksInPath().path
            let expected = profile.standardizedFileURL.path
            guard (resolved == expected || resolved.hasPrefix(expected + "/")),
                  record.usesSandbox == true || resolved.hasPrefix(root.path + "/Profiles/") else {
                throw SpaceError.message("The private home points outside the managed profiles directory.")
            }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var environment = info["LSEnvironment"] as? [String: String] ?? [:]
        environment["HOME"] = profile.path
        environment["CFFIXED_USER_HOME"] = profile.path
        environment["DUALSPACE_PROFILE"] = profileURL(record).path
        environment["TMPDIR"] = profile.appendingPathComponent("tmp").path + "/"
        environment["XDG_CONFIG_HOME"] = profile.appendingPathComponent("Library/Application Support").path
        environment["XDG_CACHE_HOME"] = profile.appendingPathComponent("Library/Caches").path
        if record.source.bundleID == "com.ccswitch.desktop" { environment["CC_SWITCH_TEST_HOME"] = profile.path }
        info["LSEnvironment"] = environment
        // WeChat prepends this plist value to its Crashpad Mach service names.
        // Keeping Tencent's prefix makes our existing 57-byte IDs exceed the
        // 128-byte bootstrap limit. An empty prefix preserves the account path
        // and lets the parent and AppEx agree on the local service namespace.
        if record.privateWeChat { info["TeamIdentifier"] = "" }
    }

    func validate(_ record: CloneRecord, at url: URL) async throws {
        try checkSymlinks(inside: url)
        let info = try readPlist(url.appendingPathComponent("Contents/Info.plist"))
        guard info["CFBundleIdentifier"] as? String == record.bundleID,
              info["DualSpaceInstanceID"] as? String == record.id.uuidString,
              let boot = info["CFBundleExecutable"] as? String,
              fm.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/\(boot)").path) else {
            throw SpaceError.message("The copy's identity or launcher is inconsistent. Rebuild this instance.")
        }
        _ = try await runner.checked("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path], timeout: 120)
    }

    private func checkSymlinks(inside root: URL) throws {
        guard let entries = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw SpaceError.message("The application bundle could not be read.")
        }
        for case let url as URL in entries {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                let resolved = url.resolvingSymlinksInPath().path
                guard resolved.hasPrefix(root.path + "/") else {
                    throw SpaceError.message("The app contains an external symbolic link: \(url.lastPathComponent). Its copy cannot be changed safely.")
                }
            }
        }
    }

    private func rewriteNestedIdentities(in root: URL, sourceID: String, targetID: String) throws {
        guard let entries = fm.enumerator(at: root.appendingPathComponent("Contents"), includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in entries where url.lastPathComponent == "Info.plist" && url.path != root.appendingPathComponent("Contents/Info.plist").path {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { continue }
            guard var info = try? readPlist(url), let identifier = info["CFBundleIdentifier"] as? String else { continue }
            let bundleType = url.deletingLastPathComponent().deletingLastPathComponent().pathExtension
            guard ["app", "xpc", "appex"].contains(bundleType) else { continue }
            if identifier == sourceID || identifier.hasPrefix(sourceID + ".") {
                info["CFBundleIdentifier"] = targetID + identifier.dropFirst(sourceID.count)
            } else if sourceID == "com.tencent.xinWeChat",
                      ["app", "xpc", "appex"].contains(url.deletingLastPathComponent().deletingLastPathComponent().pathExtension) {
                // AppEx uses a separate vendor namespace; frameworks retain
                // their resource identity, while runnable helpers are isolated.
                if identifier.hasPrefix("com.tencent.flue.") {
                    info["CFBundleIdentifier"] = targetID + ".flue." + identifier.dropFirst("com.tencent.flue.".count)
                } else if identifier == "com.tencent.xWechat.DebugHelper" {
                    info["CFBundleIdentifier"] = targetID + ".DebugHelper"
                } else { continue }
            } else { continue }
            try writePlist(info, to: url)
        }
        // Localized metadata would otherwise override the copy's display name.
        guard let resources = fm.enumerator(at: root.appendingPathComponent("Contents/Resources"), includingPropertiesForKeys: nil) else { return }
        for case let url as URL in resources where url.lastPathComponent == "InfoPlist.strings" {
            guard var values = try? readPlist(url) else { continue }
            values["CFBundleDisplayName"] = nil
            values["CFBundleName"] = nil
            try writePlist(values, to: url)
        }
    }

    private func signCode(in root: URL, record: CloneRecord, temporary: URL) async throws {
        let source = record.source
        let (codeFiles, bundles) = try codeTargets(in: root)
        let originalExecutable = root.appendingPathComponent("Contents/MacOS/\(source.executable)")
        let rootReport = try await runner.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", originalExecutable.path], timeout: 30)
        var rootEntitlements = sanitized(entitlementDictionary(rootReport.output), kind: source.kind)
        if record.runsInSandbox {
            rootEntitlements["com.apple.security.app-sandbox"] = true
        }
        let rootID = try readPlist(root.appendingPathComponent("Contents/Info.plist"))["CFBundleIdentifier"] as? String
        var targets = codeFiles.sorted { $0.path < $1.path }
        targets += bundles.sorted { $0.pathComponents.count > $1.pathComponents.count }
        targets.append(root)
        for (index, target) in targets.enumerated() {
            try Task.checkCancellation()
            let original = try await runner.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", target.path], timeout: 30)
            var entitlements = sanitized(entitlementDictionary(original.output), kind: source.kind)
            if target == root || target.deletingLastPathComponent() == root.appendingPathComponent("Contents/MacOS") {
                entitlements = rootEntitlements
            }
            if (target == root && record.usesBootstrap) || target.lastPathComponent.hasPrefix("DualSpaceBoot-") {
                entitlements = ["com.apple.security.cs.disable-library-validation": true]
            }
            if !record.runsInSandbox {
                // The bootstrap and its exec target must use the same mode;
                // sandbox activation here would replace the private HOME.
                entitlements["com.apple.security.app-sandbox"] = nil
                entitlements["com.apple.security.inherit"] = nil
            }
            let entitlementURL = temporary.appendingPathComponent("entitlements-\(index).plist")
            try writePlist(entitlements, to: entitlementURL)
            var arguments = ["--force", "--sign", "-", "--options", "runtime", "--timestamp=none", "--entitlements", entitlementURL.path]
            // Ad-hoc signatures default to a hash-specific requirement. A
            // containing app checks every framework version against Current's
            // requirement, so versions must share an explicit signing identity.
            let frameworkVersion = target.deletingLastPathComponent().lastPathComponent == "Versions"
                && target.deletingLastPathComponent().deletingLastPathComponent().pathExtension == "framework"
            if target.pathExtension == "framework" || frameworkVersion,
               let metadata = try? readPlist(target.appendingPathComponent("Resources/Info.plist")),
               let identifier = metadata["CFBundleIdentifier"] as? String {
                let escaped = identifier.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                arguments += ["--identifier", identifier, "--requirements", "=designated => identifier \"\(escaped)\""]
            }
            if target == originalExecutable, let rootID { arguments += ["--identifier", rootID] }
            arguments.append(target.path)
            _ = try await runner.checked("/usr/bin/codesign", arguments, timeout: 120)
        }
    }

    private func codeTargets(in root: URL) throws -> ([URL], [URL]) {
        var codeFiles: [URL] = []
        var bundles: [URL] = []
        if let entries = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let url as URL in entries {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { continue }
                if ["app", "xpc", "appex", "framework"].contains(url.pathExtension) {
                    bundles.append(url)
                    if url.pathExtension == "framework" {
                        let versions = url.appendingPathComponent("Versions")
                        if fm.fileExists(atPath: versions.path) {
                            for version in try fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
                                let metadata = try version.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                                if metadata.isDirectory == true && metadata.isSymbolicLink != true { bundles.append(version) }
                            }
                        }
                    }
                } else if ["bundle", "plugin"].contains(url.pathExtension),
                          let info = try? readPlist(url.appendingPathComponent("Contents/Info.plist")),
                          info["CFBundleExecutable"] != nil {
                    bundles.append(url)
                }
                if values.isRegularFile == true, isMachO(url) || hasResourceSignature(url) { codeFiles.append(url) }
            }
        }
        return (codeFiles, bundles)
    }

    private func sanitized(_ original: [String: Any], kind: AppKind) -> [String: Any] {
        var result = original.filter { key, _ in
            key.hasPrefix("com.apple.security.") && key != "com.apple.security.application-groups"
        }
        // Local signatures have no vendor Team ID. The copied process must load
        // its locally signed libraries; the source bundle is never re-signed.
        result["com.apple.security.cs.disable-library-validation"] = true
        if kind.usesChromium {
            result["com.apple.security.cs.allow-jit"] = true
            result["com.apple.security.cs.allow-unsigned-executable-memory"] = true
        }
        return result
    }

    private func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let bytes = [UInt8](data)
        return [[0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe], [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca], [0xca, 0xfe, 0xba, 0xbf]].contains(bytes)
    }

    private func hasResourceSignature(_ url: URL) -> Bool {
        // Non-Mach-O code signatures live in extended attributes. WeChat's
        // XPlayer includes such a signed JSON file alongside its libraries.
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.cs.CodeDirectory", nil, 0, 0, XATTR_NOFOLLOW) > 0
        }
    }

    private func addIcon(_ record: CloneRecord, to app: URL) throws {
        let icon = NSWorkspace.shared.icon(forFile: record.source.path)
        let canvas = NSImage(size: NSSize(width: 512, height: 512))
        canvas.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: 512, height: 512))
        let seed = Double(record.id.uuid.0) / 255
        NSColor(calibratedHue: seed, saturation: 0.67, brightness: 0.92, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 332, y: 10, width: 166, height: 166), xRadius: 48, yRadius: 48).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 106, weight: .bold), .foregroundColor: NSColor.white]
        NSString(string: "+").draw(at: NSPoint(x: 370, y: 36), withAttributes: attributes)
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let path = app.appendingPathComponent("Contents/Resources/DualSpaceIcon.png")
        try png.write(to: path)
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        var info = try readPlist(infoURL)
        info["CFBundleIconName"] = nil
        info["CFBundleIcons"] = nil
        info["CFBundleIconFile"] = "DualSpaceIcon.png"
        try writePlist(info, to: infoURL)
    }
}
