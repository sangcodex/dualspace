// Asynchronous, cancellable subprocesses with drained pipes and a bounded lifetime.
import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: Data
    public let error: Data
    public var text: String { String(decoding: output, as: UTF8.self) }
    public var errorText: String { String(decoding: error, as: UTF8.self) }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult
}

private final class ProcessControl: @unchecked Sendable {
    let lock = NSLock()
    var process: Process?
    var cancelled = false
    var timedOut = false

    func start(_ task: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try task.run()
        process = task
    }

    func stop(timeout: Bool = false) {
        lock.lock()
        if timeout && process?.isRunning != true { lock.unlock(); return }
        if timeout { timedOut = true } else { cancelled = true }
        let task = process
        lock.unlock()
        if let task, task.isRunning {
            task.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if task.isRunning { Darwin.kill(task.processIdentifier, SIGKILL) }
            }
        }
    }

    func state() -> (cancelled: Bool, timedOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (cancelled, timedOut)
    }
}

/// Runs tools without a shell. Cancellation and timeouts stop the direct child process.
/// Example: try await CommandRunner().run("/usr/bin/codesign", ["--verify", app.path], timeout: 60)
public struct CommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) async throws -> CommandResult {
        let control = ProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let task = Process()
                        let stdout = Pipe(), stderr = Pipe()
                        task.executableURL = URL(fileURLWithPath: executable)
                        task.arguments = arguments
                        task.standardOutput = stdout
                        task.standardError = stderr
                        try control.start(task)
                        let deadline = DispatchWorkItem { control.stop(timeout: true) }
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                        let output = DataBox(), error = DataBox()
                        let readers = DispatchGroup()
                        for (pipe, box) in [(stdout, output), (stderr, error)] {
                            readers.enter()
                            DispatchQueue.global(qos: .utility).async {
                                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                                readers.leave()
                            }
                        }
                        task.waitUntilExit()
                        readers.wait()
                        deadline.cancel()
                        let state = control.state()
                        if state.cancelled { throw CancellationError() }
                        if state.timedOut { throw SpaceError.message("\(URL(fileURLWithPath: executable).lastPathComponent) timed out.") }
                        continuation.resume(returning: CommandResult(status: task.terminationStatus, output: output.data, error: error.data))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { control.stop() })
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }

extension CommandRunning {
    func checked(_ tool: String, _ args: [String], timeout: TimeInterval = 180) async throws -> CommandResult {
        let result = try await run(tool, args, timeout: timeout)
        guard result.status == 0 else {
            let detail = result.errorText.isEmpty ? result.text : result.errorText
            throw SpaceError.message("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(result.status)): \(detail.prefix(1800))")
        }
        return result
    }
}
