// Entitlement inspection keeps unsupported assumptions visible to the caller.
import Foundation

/// Inspects an app before materializing a copy; no source files are changed.
/// Example: try await AppInspector(runner: CommandRunner()).inspect(sourceURL)
public struct AppInspector: Sendable {
    let runner: any CommandRunning
    public init(runner: any CommandRunning) { self.runner = runner }

    public func inspect(_ url: URL) async throws -> Inspection {
        let app = try AppDescriptor.read(url)
        let result = try await runner.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path], timeout: 30)
        let entitlements = entitlementDictionary(result.output)
        var notes: [String] = []
        if result.status != 0 || result.errorText.contains("invalid entitlements") {
            notes.append("The source signing entitlements could not be read reliably. App-specific data isolation is unverified.")
        }
        if entitlements["com.apple.security.application-groups"] != nil {
            notes.append("Shared app groups are present. Copies cannot inherit the vendor's group authorization.")
        }
        if entitlements["keychain-access-groups"] != nil {
            notes.append("Vendor keychain groups are present. Sign in again inside the copy; some sign-in methods may be incompatible.")
        }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path) {
            notes.append("This is an App Store installation. Receipt checks can reject a modified copy.")
        }
        if app.kind == .native {
            if app.bundleID == "com.tencent.xinWeChat" {
                notes.append("This WeChat copy uses a private home for compatibility. Separate app data is not an App Sandbox security boundary.")
            } else if entitlements["com.apple.security.app-sandbox"] as? Bool == true {
                notes.append("The copy uses a distinct macOS sandbox container. Verify its independent account login before daily use.")
            } else {
                notes.append("A private home is configured. Native apps may use fixed paths or external services; verify account separation before daily use.")
            }
        } else {
            notes.append("A dedicated Chromium profile is configured. Apps can override Chromium's profile option; verify the signed-in account.")
        }
        if let info = try? readPlist(URL(fileURLWithPath: app.path).appendingPathComponent("Contents/Info.plist")), info["CFBundleURLTypes"] != nil {
            notes.append("Custom URL schemes are namespaced for the copy. Browser-based sign-in callbacks may need app-specific support.")
        }
        let readable = result.status == 0 && !result.errorText.contains("invalid entitlements")
        return Inspection(app: app, notes: notes, sandboxed: readable ? (entitlements["com.apple.security.app-sandbox"] as? Bool ?? false) : nil)
    }
}

func entitlementDictionary(_ data: Data) -> [String: Any] {
    if let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] { return value }
    if let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)), end.upperBound > start.lowerBound {
        return (try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]) ?? [:]
    }
    return [:]
}
