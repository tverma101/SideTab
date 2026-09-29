import Foundation
import ServiceManagement
import os.log

class DaemonManager {
    static let shared = DaemonManager()

    private var appService: SMAppService {
        return SMAppService.mainApp
    }
    
    /// A registered login item from our point of view.
    ///
    /// SMAppService.Status.requiresApproval is documented as "the service has
    /// been successfully registered, but the user needs to take action in
    /// System Settings", and it is also what the framework reports after the
    /// user revokes consent. Reading only .enabled therefore reported "off" for
    /// a live login item: the settings toggle snapped back, register() was
    /// repeated on every launch, and applicationDidFinishLaunching popped the
    /// settings window on every single login.
    static func isRegistered(status: SMAppService.Status) -> Bool {
        return status == .enabled || status == .requiresApproval
    }

    var isEnabled: Bool {
        return Self.isRegistered(status: appService.status)
    }
    
    func enable() throws {
        let service = appService
        guard !Self.isRegistered(status: service.status) else { return }
        
        do {
            try service.register()
            os_log("Successfully registered login item.")
        } catch {
            os_log("Failed to register login item: %{public}@", error.localizedDescription)
            throw error
        }
    }
    
    func disable() throws {
        let service = appService
        guard service.status != .notRegistered else { return }
        
        do {
            try service.unregister()
            os_log("Successfully unregistered login item.")
        } catch {
            os_log("Failed to unregister login item: %{public}@", error.localizedDescription)
            throw error
        }
    }
}
