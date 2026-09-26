import Foundation

/// IdleSleepMonitor — pause the capture pipeline when no client is connected.
///
/// The sender normally captures + encodes at full rate whether or not a tablet
/// is attached (measured: ~97% CPU with no client, encoding frames into the
/// void). This monitor watches the client-connected flag; once the grace
/// window passes with no client, it pauses SCStream capture so the encoder
/// goes idle. When a client connects, it resumes capture and forces a keyframe;
/// cached-frame replay covers the SCStream restart gap.
///
/// Knobs:
///   defaults write com.sidescreen.app SideScreen_exp_idleSleep -bool true
///   defaults write com.sidescreen.app SideScreen_exp_idleSleepSecs -int 15
/// The monitor is enabled by default for both USB and wireless sessions. Set
/// SideScreen_exp_idleSleep to false to disable it.
@MainActor
final class IdleSleepMonitor {
    private let isClientConnected: () -> Bool
    private let pause: () -> Void
    private let resume: () -> Void
    private let graceSecs: Double

    private var timer: Timer?
    private var idleSince: Date?
    private var paused = false

    init(
        isClientConnected: @escaping () -> Bool,
        pause: @escaping () -> Void,
        resume: @escaping () -> Void,
        graceSecs: Double
    ) {
        self.isClientConnected = isClientConnected
        self.pause = pause
        self.resume = resume
        self.graceSecs = graceSecs
    }

    /// The timer is added to the main run loop, and RunLoop is documented as
    /// not thread-safe — adding a timer to another thread's run loop can crash.
    /// Being on the main actor also wakes the loop, so the grace window is not
    /// delayed by a main-loop idle period.
    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        idleSince = nil
        paused = false
    }

    private func tick() {
        if isClientConnected() {
            idleSince = nil
            if paused {
                paused = false
                resume()
            }
        } else {
            if let since = idleSince {
                if !paused, Date().timeIntervalSince(since) >= graceSecs {
                    paused = true
                    pause()
                }
            } else {
                idleSince = Date()
            }
        }
    }
}
