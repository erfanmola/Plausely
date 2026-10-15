import AnalyticsCore
import Foundation
import LocalAuthentication

/// App-lock session state: passcode gate plus biometric shortcut, both
/// user-toggleable from Settings. The model never sees a passcode in the
/// clear beyond the verifying call; the store only ever holds the hash.
/// Biometric evaluation is injectable so tests never touch hardware.
@MainActor
@Observable
public final class AppLockModel {
    public typealias BiometricCheck = @Sendable () async -> Bool

    public private(set) var isEnabled: Bool
    public private(set) var isLocked: Bool
    public private(set) var biometricEnabled: Bool
    public private(set) var biometricKind: BiometricKind = .none
    public private(set) var failedAttempts: Int = 0

    private let biometricCheck: BiometricCheck?

    public enum BiometricKind: Sendable {
        case none
        case touchID
        case faceID
        case opticID
    }

    public init(biometricCheck: BiometricCheck? = nil) {
        self.biometricCheck = biometricCheck
        let record = AppLockStore.load()
        self.isEnabled = record != nil
        self.biometricEnabled = record?.biometricEnabled ?? false
        // Cold start locks when a lock exists; UI tests bypass via args.
        self.isLocked = record != nil && !Self.bypassForTests
        if record != nil { refreshBiometry() }
    }

    private static var bypassForTests: Bool {
        CommandLine.arguments.contains("-plausely-live-reset")
            || CommandLine.arguments.contains("-plausely-mock")
            || CommandLine.arguments.contains("-plausely-mock-sites")
    }

    public func refreshBiometry() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            biometricKind = .none
            return
        }
        switch context.biometryType {
        case .touchID: biometricKind = .touchID
        case .faceID: biometricKind = .faceID
        case .opticID: biometricKind = .opticID
        default: biometricKind = .none
        }
    }

    /// First unlock attempt after lock uses biometry when allowed.
    public func unlockWithBiometrics() async -> Bool {
        guard isEnabled, biometricEnabled, biometricKind != .none else { return false }
        if let biometricCheck {
            if await biometricCheck() {
                failedAttempts = 0
                isLocked = false
                return true
            }
            return false
        }
        let context = LAContext()
        do {
            _ = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock Plausely"
            )
            failedAttempts = 0
            isLocked = false
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func unlock(passcode: String) -> Bool {
        guard AppLockStore.verify(passcode: passcode, against: AppLockStore.load()) else {
            failedAttempts += 1
            return false
        }
        failedAttempts = 0
        isLocked = false
        return true
    }

    public func lock() {
        failedAttempts = 0
        if isEnabled { isLocked = true }
    }

    public func setup(passcode: String, biometric: Bool) throws {
        guard passcode.count == 4, passcode.allSatisfy(\.isNumber) else {
            throw AppLockStoreError.invalidPasscode
        }
        let salt = AppLockStore.randomSalt()
        let stored = AppLockRecord(
            salt: salt,
            hash: AppLockStore.digest(passcode: passcode, salt: salt),
            biometricEnabled: biometric
        )
        try AppLockStore.save(stored)
        isEnabled = true
        biometricEnabled = biometric
        isLocked = false
        failedAttempts = 0
        refreshBiometry()
    }

    public func setBiometric(_ enabled: Bool) throws {
        guard var record = AppLockStore.load() else { return }
        record = AppLockRecord(salt: record.salt, hash: record.hash, biometricEnabled: enabled)
        try AppLockStore.save(record)
        biometricEnabled = enabled
    }

    public func disable() throws {
        try AppLockStore.remove()
        isEnabled = false
        biometricEnabled = false
        isLocked = false
        failedAttempts = 0
    }
}
