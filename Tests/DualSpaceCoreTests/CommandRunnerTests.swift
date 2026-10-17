import XCTest
@testable import DualSpaceCore

final class CommandRunnerTests: XCTestCase {
    func testLargeStdoutAndStderrAreDrainedConcurrently() async throws {
        let script = "for ((i=0; i<16000; i++)); do print -r -- 'abcdefgh'; print -r -- 'ijklmnop' >&2; done"
        let result = try await CommandRunner().run("/bin/zsh", ["-c", script], timeout: 20)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 144000)
        XCTAssertEqual(result.error.count, 144000)
    }

    func testTimeoutTerminatesAChild() async throws {
        let started = Date()
        do { _ = try await CommandRunner().run("/bin/sleep", ["8"], timeout: 0.1); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testCancellationDoesNotWaitForNaturalExit() async throws {
        let task = Task { try await CommandRunner().run("/bin/sleep", ["8"], timeout: 20) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }
}
