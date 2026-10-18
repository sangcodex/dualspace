// Bounded adaptations for native apps whose compiled single-instance identity ignores Info.plist.
import Foundation
import CryptoKit

/// Applies the verified CC Switch recipe only to an exact supported artifact.
/// Example: try NativeCompatibility().checkCCSwitch(descriptor)
struct NativeCompatibility {
    private let sourceDigest = "7fdbdb1cb87ffe8b9fbf90434b09bf9a50b134d68d76fdd4f8a890284cde7848"

    func checkCCSwitch(_ source: AppDescriptor) throws {
        #if arch(arm64)
        guard source.version == "3.20.4", source.executable == "cc-switch" else { throw unsupported() }
        let file = URL(fileURLWithPath: source.path).appendingPathComponent("Contents/MacOS/\(source.executable)")
        guard try digest(file) == sourceDigest else { throw unsupported() }
        #else
        throw unsupported()
        #endif
    }

    static func ccSwitchIdentity(_ id: UUID) -> String {
        // The optimized arm64 build copies the final four bytes with an
        // immediate store. Preserve that suffix and namespace the data prefix.
        "ds" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(14) + "ktop"
    }

    func prepareCCSwitch(_ record: CloneRecord, at app: URL, runner: any CommandRunning) async throws {
        try checkCCSwitch(record.source)
        let executable = app.appendingPathComponent("Contents/MacOS/\(record.source.executable)")
        guard try digest(executable) == sourceDigest else { throw unsupported() }
        let thin = executable.appendingPathExtension("arm64")
        defer { try? FileManager.default.removeItem(at: thin) }
        _ = try await runner.checked("/usr/bin/lipo", [executable.path, "-thin", "arm64", "-output", thin.path], timeout: 60)
        var bytes = try Data(contentsOf: thin)
        // Exact artifact + Mach-O __TEXT,__const range verified for 3.20.4.
        // No scan-and-replace is performed on instructions or arbitrary data.
        let offset = 0x14d9f3b
        let original = Data("com.ccswitch.desktop".utf8)
        guard bytes.count == 29_664_096,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == "82ac0cb872c3382f7239689b58b0c774e6dd79040bc2facd88a25f9824a64217",
              bytes.prefix(8) == Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]),
              bytes.subdata(in: offset..<(offset + original.count)) == original else { throw unsupported() }
        bytes.replaceSubrange(offset..<(offset + original.count), with: Data(Self.ccSwitchIdentity(record.id).utf8))
        try bytes.write(to: thin)
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.moveItem(at: thin, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    private func digest(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    private func unsupported() -> SpaceError {
        .message("This CC Switch build has an unsupported compiled single-instance lock. The verified adaptation requires the original 3.20.4 universal build on Apple Silicon. No copy was published; the existing instance is preserved.")
    }
}
