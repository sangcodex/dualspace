// Shared presentation of observed processes and in-flight user actions.
import Foundation

enum InstancePhase: Equatable {
    case checking, stopped, starting, running, stopping, failed, missing

    var label: String {
        switch self {
        case .checking: return "Checking status…"
        case .stopped: return "Ready to open"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Quitting…"
        case .failed: return "Launch failed"
        case .missing: return "Copy missing"
        }
    }

    var isBusy: Bool { self == .checking || self == .starting || self == .stopping }
}

struct InstanceState: Equatable {
    var phase: InstancePhase = .checking
    var pid: Int32?
    var error: String?

    var label: String {
        if phase == .running, let pid { return "Running · PID \(pid)" }
        return phase.label
    }
}
