import Foundation
import LocalAuthentication

/// Keeps hacker mode behind Face ID, Touch ID or the device passcode, so someone
/// picking up an unlocked phone cannot see what was browsed there.
///
/// Hacker mode locks whenever it is left or the app goes to the background. Its tabs
/// stay in memory meanwhile, but are not shown until the owner unlocks it again.
final class HackerModeLock {
    typealias Authenticate = () async -> Bool

    private(set) var isLocked = true
    private let authenticate: Authenticate
    private var authentication: Task<Bool, Never>?

    init(authenticate: @escaping Authenticate = HackerModeLock.authenticateDeviceOwner) {
        self.authenticate = authenticate
    }

    /// Asks the owner to authenticate, if locked. Asking twice at once shows one prompt.
    func unlock() async -> Bool {
        guard isLocked else { return true }
        if let authentication {
            return await authentication.value
        }
        let authentication = Task { await authenticate() }
        self.authentication = authentication
        let success = await authentication.value
        self.authentication = nil
        if success {
            isLocked = false
        }
        return success
    }

    func lock() {
        isLocked = true
    }

    /// Face ID, Touch ID or the passcode, whatever the device uses.
    static func authenticateDeviceOwner() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Without a passcode the phone itself is open to anyone, so a lock here
            // would protect nothing. Let the owner in.
            return (error as? LAError)?.code == .passcodeNotSet
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock hacker mode")
        } catch {
            return false
        }
    }
}
