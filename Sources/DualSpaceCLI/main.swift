// A small executable example uses the same store as the graphical application.
import Foundation
import AppKit
import DualSpaceCore

@main struct DualSpaceCommand {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let binaries = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
            let root = ProcessInfo.processInfo.environment["DUALSPACE_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DualSpace")
            let store = CloneStore(root: root, launcher: binaries.appendingPathComponent("DualSpaceLauncher"), runner: CommandRunner())
            let command = args.first ?? "help"
            switch command {
            case "inspect":
                guard args.count == 2 else { throw SpaceError.message("Usage: dualspace-cli inspect /path/to/App.app") }
                let report = try await store.inspect(source: URL(fileURLWithPath: args[1]))
                try printJSON(["app": report.app.name, "kind": report.app.kind.label, "version": report.app.release, "sandboxed": report.sandboxed.map { $0 as Any } ?? NSNull(), "notes": report.notes] as [String: Any])
            case "create":
                guard args.count == 3 else { throw SpaceError.message("Usage: dualspace-cli create /path/to/App.app 'Instance name'") }
                let record = try await store.create(source: URL(fileURLWithPath: args[1]), name: args[2])
                try printRecord(record, store: store)
            case "list":
                let records = try await store.list()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                print(String(decoding: try encoder.encode(records), as: UTF8.self))
            case "refresh", "rename", "remove", "verify", "launch", "quit":
                guard args.count >= 2, let id = UUID(uuidString: args[1]) else { throw SpaceError.message("Provide an instance UUID from 'list'.") }
                if command == "refresh" || command == "rename" {
                    if command == "rename" && args.count != 3 { throw SpaceError.message("Provide the new instance name.") }
                    try printRecord(try await store.refresh(id: id, name: command == "rename" ? args[2] : nil), store: store)
                } else if command == "remove" { try await store.remove(id: id); print("Removed copy. Its profile has been kept.") }
                else if command == "verify" { try await store.verify(id: id); print("The managed identity and code signature are valid.") }
                else {
                    guard let record = try await store.list().first(where: { $0.id == id }) else { throw SpaceError.message("Instance not found.") }
                    let runtime = InstanceRuntime()
                    if command == "quit" { try await runtime.quit(record, at: store.appURL(record)); print("Quit requested.") }
                    else {
                        let pid = try await runtime.launch(record, at: store.appURL(record))
                        print(pid > 0 ? "PID \(pid)" : "The copy was opened; the system did not expose its process identifier.")
                    }
                }
            default:
                print("DualSpace\n\ninspect APP\ncreate APP NAME\nlist\nlaunch UUID\nquit UUID\nrefresh UUID\nrename UUID NAME\nverify UUID\nremove UUID\n\nSet DUALSPACE_HOME to choose a workspace. Use the graphical app for normal operation.")
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static func printJSON(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }

    static func printRecord(_ record: CloneRecord, store: CloneStore) throws {
        try printJSON(["id": record.id.uuidString, "name": record.name, "bundleID": record.bundleID, "application": store.appURL(record).path, "profile": store.profileURL(record).path, "notes": record.notes])
    }
}
