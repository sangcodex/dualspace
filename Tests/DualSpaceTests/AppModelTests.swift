// Exercises the manager's lifecycle against an injected process observer.
import XCTest
import AppKit
@testable import DualSpace
@testable import DualSpaceCore

@MainActor private final class RuntimeStub: InstanceRunning {
    var pid: Int32?
    var launchError: Error?
    var quitError: Error?
    var observeLaunch = true
    var launchEntered: XCTestExpectation?
    var quitEntered: XCTestExpectation?
    var launchGate: CheckedContinuation<Int32, Error>?
    var quitGate: CheckedContinuation<Void, Error>?

    func processID(_ record: CloneRecord, at url: URL) -> Int32? { pid }
    func launch(_ record: CloneRecord, at url: URL) async throws -> Int32 {
        if let launchError { throw launchError }
        if let launchEntered {
            return try await withCheckedThrowingContinuation {
                launchGate = $0
                launchEntered.fulfill()
            }
        }
        if observeLaunch { pid = 42 }
        return 42
    }
    func quit(_ record: CloneRecord, at url: URL) async throws {
        if let quitError { throw quitError }
        if let quitEntered {
            try await withCheckedThrowingContinuation {
                quitGate = $0
                quitEntered.fulfill()
            }
        } else { pid = nil }
    }
}

@MainActor final class AppModelTests: XCTestCase {
    private var base: URL!
    private var store: CloneStore!
    private var record: CloneRecord!
    private var runtime: RuntimeStub!
    private var events: NotificationCenter!
    private var model: AppModel!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("DualSpaceStateTests-\(UUID())")
        let source = base.appendingPathComponent("Source.app")
        let executable = source.appendingPathComponent("Contents/MacOS/Example")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try writePlist(["CFBundleIdentifier": "test.source", "CFBundleExecutable": "Example"], to: source.appendingPathComponent("Contents/Info.plist"))
        record = CloneRecord(id: UUID(), name: "Test Copy", source: try AppDescriptor.read(source),
            createdAt: Date(), updatedAt: Date(), notes: [], usesSandbox: false, appFileName: "Test.app")
        store = CloneStore(root: base.appendingPathComponent("Workspace"), launcher: URL(fileURLWithPath: "/usr/bin/true"), runner: CommandRunner())
        _ = try await store.list()
        try FileManager.default.copyItem(at: source, to: store.appURL(record))
        try writePlist(["CFBundleIdentifier": record.bundleID, "CFBundleExecutable": "Example", "DualSpaceInstanceID": record.id.uuidString], to: store.appURL(record).appendingPathComponent("Contents/Info.plist"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Manifest(instances: [record])).write(to: store.root.appendingPathComponent("instances.json"))
        runtime = RuntimeStub()
        events = NotificationCenter()
        model = AppModel(store: store, runtime: runtime, workspaceEvents: events, applicationEvents: events)
        // Keep this lifecycle suite independent of the host's installed apps.
        model.applications = [record.source]
        await model.reload()
    }

    override func tearDown() async throws {
        model = nil
        try FileManager.default.removeItem(at: base)
    }

    func testStartingSurvivesExecTerminationAndWaitsForObservedProcess() async throws {
        let entered = expectation(description: "Launch entered")
        runtime.launchEntered = entered
        let action = Task { await model.act(.launch, on: record) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(model.state(for: record).phase, .starting)
        events.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.state(for: record).phase, .starting)
        let gate = try XCTUnwrap(runtime.launchGate)
        gate.resume(returning: 99)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.state(for: record).phase, .starting)
        XCTAssertNil(model.pids[record.id])
        runtime.pid = 123
        events.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        await action.value
        XCTAssertEqual(model.state(for: record).phase, .running)
        XCTAssertEqual(model.pids[record.id], 123)
        XCTAssertNil(model.state(for: record).error)
    }

    func testFailurePersistsUntilRetryAndClearsAfterSuccess() async {
        runtime.launchError = SpaceError.message("Injected launch failure")
        await model.act(.launch, on: record)
        XCTAssertEqual(model.state(for: record).phase, .failed)
        model.refreshStatus()
        XCTAssertEqual(model.state(for: record).error, "Injected launch failure")
        runtime.launchError = nil
        await model.act(.launch, on: record)
        XCTAssertEqual(model.state(for: record).phase, .running)
        XCTAssertNil(model.state(for: record).error)
        XCTAssertNil(model.working)
    }

    func testAcceptedLaunchWithoutAnObservedProcessTimesOut() async {
        runtime.observeLaunch = false
        await model.act(.launch, on: record)
        XCTAssertEqual(model.state(for: record).phase, .failed)
        XCTAssertNotNil(model.state(for: record).error)
        XCTAssertNil(model.pids[record.id])
        XCTAssertNil(model.working)
    }

    func testExternalLaunchAndQuitUpdateWithoutAView() async throws {
        runtime.launchError = SpaceError.message("Injected launch failure")
        await model.act(.launch, on: record)
        runtime.pid = 321
        events.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        try await waitFor(.running)
        XCTAssertNil(model.state(for: record).error)
        XCTAssertNil(model.notice)
        runtime.pid = nil
        events.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        try await waitFor(.stopped)
        XCTAssertTrue(model.pids.isEmpty)
    }

    func testQuitShowsTransitionAndKeepsRunningOnFailure() async throws {
        runtime.pid = 42
        model.refreshStatus()
        runtime.quitError = SpaceError.message("Finish the open dialog")
        await model.act(.quit, on: record)
        XCTAssertEqual(model.state(for: record).phase, .running)
        XCTAssertEqual(model.state(for: record).error, "Finish the open dialog")
        runtime.quitError = nil
        let entered = expectation(description: "Quit entered")
        runtime.quitEntered = entered
        let action = Task { await model.act(.quit, on: record) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(model.state(for: record).phase, .stopping)
        runtime.pid = nil
        events.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        let gate = try XCTUnwrap(runtime.quitGate)
        gate.resume()
        await action.value
        XCTAssertEqual(model.state(for: record).phase, .stopped)
        XCTAssertNil(model.state(for: record).error)
    }

    func testReloadFindsExistingProcessAndMissingCopyRemainsExplicit() async throws {
        runtime.pid = 42
        await model.reload()
        XCTAssertEqual(model.state(for: record).phase, .running)
        XCTAssertFalse(model.loadingInstances)
        try FileManager.default.removeItem(at: store.appURL(record))
        model.refreshStatus()
        XCTAssertEqual(model.state(for: record).phase, .running)
        XCTAssertTrue(model.missing.contains(record.id))
        runtime.pid = nil
        model.refreshStatus()
        XCTAssertEqual(model.state(for: record).phase, .missing)
    }

    private func waitFor(_ phase: InstancePhase) async throws {
        for _ in 0..<100 {
            if model.state(for: record).phase == phase { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The workspace event did not update the instance state.")
    }
}
