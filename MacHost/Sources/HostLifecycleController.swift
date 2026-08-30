import Foundation

enum HostSuspendReason: String, CaseIterable, Hashable {
    case sessionInactive
    case screenSaver
    case displaySleep
    case systemSleep

    /// Stable, payload-sized value for the optional HostSuspending wire
    /// advisory. The enum's raw strings remain the diagnostic vocabulary.
    var wireID: UInt8 {
        switch self {
        case .sessionInactive: return 1
        case .screenSaver: return 2
        case .displaySleep: return 3
        case .systemSleep: return 4
        }
    }
}

enum HostLifecycleState: Equatable {
    case active
    case suspending(Set<HostSuspendReason>)
    case suspended(Set<HostSuspendReason>)
    case resuming
}

/// Pure lifecycle policy for the Mac host.
///
/// AppDelegate/NSWorkspace/IOKit notification wiring is intentionally kept out
/// of this type. The controller only answers the product question: may a host
/// session emit desktop pixels right now?
///
/// Multiple suspend reasons may overlap. For example, the Mac can lock and
/// then enter system sleep. A wake event must not make pixels eligible again
/// while the user session is still inactive.
final class HostLifecycleController {
    private(set) var state: HostLifecycleState = .active
    private(set) var suspendReasons: Set<HostSuspendReason> = []

    var onStateChanged: ((HostLifecycleState) -> Void)?

    var mayEmitDesktopPixels: Bool {
        state == .active && suspendReasons.isEmpty
    }

    @discardableResult
    func beginSuspend(_ reason: HostSuspendReason) -> Bool {
        let inserted = suspendReasons.insert(reason).inserted
        guard inserted else { return false }
        publish(.suspending(suspendReasons))
        return inserted
    }

    /// Called after capture/encode/network work for the current generation is
    /// quiesced. If a resume raced with teardown, do not resurrect the host;
    /// completion remains constrained by the currently active reasons.
    func suspendCompleted() {
        guard !suspendReasons.isEmpty else {
            publish(.resuming)
            return
        }
        publish(.suspended(suspendReasons))
    }

    /// Clears one concrete macOS lifecycle reason. The host can only enter the
    /// resume path after every reason is gone.
    @discardableResult
    func clearSuspendReason(_ reason: HostSuspendReason) -> Bool {
        guard suspendReasons.remove(reason) != nil else { return false }
        if suspendReasons.isEmpty {
            publish(.resuming)
        } else {
            publish(.suspended(suspendReasons))
        }
        return true
    }

    /// Called only after listeners/capture prerequisites are ready again.
    /// A late completion cannot make the host active if another suspend reason
    /// arrived during resume.
    func resumeCompleted() {
        guard suspendReasons.isEmpty else {
            publish(.suspended(suspendReasons))
            return
        }
        publish(.active)
    }

    private func publish(_ next: HostLifecycleState) {
        guard state != next else { return }
        state = next
        onStateChanged?(next)
    }
}
