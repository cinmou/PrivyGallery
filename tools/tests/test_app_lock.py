#!/usr/bin/env python3
"""Exercise the actual session coordinator with delayed authentication and no biometric hardware."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
fixtures = r'''
import Foundation
import LocalAuthentication

@MainActor enum TestDriver {
    static var pending: [CheckedContinuation<BiometricKeyResult, Never>] = []
    static var activatedKeys = 0
    static var locks = 0
    static func complete(_ index: Int, _ result: BiometricKeyResult) { pending[index].resume(returning: result) }
}
enum AppTab { case media }
enum AppPasscodeKind { case fourDigits; func normalized(_ value: String) -> String { value } }
enum UnlockAttemptResult { case success(VaultSpaceKind); case failure(message: String) }
enum BiometricKeyResult { case success(VaultSpaceKind, Data); case failure(message: String) }
enum PasscodeUpdateResult { case success; case failure(message: String) }
@MainActor struct AppLockService {
    var biometricHardwareAvailable: Bool { true }
    var biometricUnlockEnabled: Bool { true }
    func unlockLockoutRemaining() -> TimeInterval? { nil }
    func isPasscodeConfigured(for space: VaultSpaceKind) -> Bool { true }
    func configuredPasscodeKind(for space: VaultSpaceKind) -> AppPasscodeKind? { .fourDigits }
    func configuredCoercionPasscodeKind(for space: VaultSpaceKind) -> AppPasscodeKind? { nil }
    func hasCoercionPasscode(for space: VaultSpaceKind) -> Bool { false }
    func setBiometricUnlockEnabled(_ enabled: Bool) {}
    func validate(passcode: String, for space: VaultSpaceKind, allowCoercionTrigger: Bool) -> UnlockAttemptResult { .success(space) }
    func validate(passcode: String, allowCoercionTrigger: Bool) -> UnlockAttemptResult { .success(.spaceA) }
    func biometricKey(context: LAContext) async -> BiometricKeyResult {
        await withCheckedContinuation { TestDriver.pending.append($0) }
    }
    func activateBiometricKey(_ data: Data, for space: VaultSpaceKind) { TestDriver.activatedKeys += 1 }
    func configureInitialPasscode(_ passcode: String, kind: AppPasscodeKind, for space: VaultSpaceKind) -> PasscodeUpdateResult { .success }
    func changePasscode(for space: VaultSpaceKind, currentPasscode: String, newPasscode: String, kind: AppPasscodeKind, allowTemporaryTypeMismatch: Bool) -> PasscodeUpdateResult { .success }
    func configureCoercionPasscode(_ passcode: String, kind: AppPasscodeKind, for space: VaultSpaceKind, allowTemporaryTypeMismatch: Bool) -> PasscodeUpdateResult { .success }
    func verify(passcode: String, for space: VaultSpaceKind) -> UnlockAttemptResult { .success(space) }
    func removeCoercionPasscode(for space: VaultSpaceKind) {}
    func lock() { TestDriver.locks += 1 }
    func wipeAllSecurityStateForTesting() {}
}
struct SharedState {
    var currentTierRawValue = ""
    var isSpaceBConfigured = false
    var spaceADisplayName = ""
    var spaceBDisplayName = ""
}
@MainActor final class SharedImportStore {
    static let shared = SharedImportStore()
    var appState = SharedState()
}
@MainActor final class SubscriptionManager {
    enum Tier: String { case free }
    static let shared = SubscriptionManager()
    var currentTier: Tier = .free
}
@MainActor enum SpaceDisplaySettings {
    static func displayName(for space: VaultSpaceKind) -> String { space.rawValue }
    static func updateDisplayName(_ name: String, for space: VaultSpaceKind) {}
}
'''
checks = r'''
import Foundation

@main struct Checks {
    @MainActor static func waitForRequest(_ count: Int) async {
        for _ in 0..<10_000 {
            if TestDriver.pending.count == count { return }
            await Task.yield()
        }
        fatalError("Authentication request was not started")
    }
    @MainActor static func main() async {
        let session = AppSessionViewModel()
        session.handleScenePhaseChange(isActive: true)
        let first = Task { await session.unlockPrimaryWithBiometrics(isAutomaticAttempt: true) }
        await waitForRequest(1)
        precondition(session.isAuthenticating)
        var settingsAccepted = true
        session.authenticateOwner(reason: "settings") { settingsAccepted = $0 }
        precondition(!settingsAccepted, "Settings authentication must not overlap the unlock prompt")
        let duplicate = await session.unlockPrimaryWithBiometrics(isAutomaticAttempt: false)
        precondition(duplicate == nil && TestDriver.pending.count == 1, "Automatic/manual prompts must not overlap")
        session.handleScenePhaseChange(isActive: false)
        session.handleScenePhaseChange(isActive: true)
        precondition(session.isAuthenticating && !session.canAutomaticallyAttemptBiometricUnlock, "Face ID's inactive/active events must not restart authentication")
        TestDriver.complete(0, .success(.spaceB, Data([1])))
        _ = await first.value
        precondition(session.activeSpace == .spaceB && TestDriver.activatedKeys == 1)

        session.handleDidEnterBackground()
        let locks = TestDriver.locks
        session.handleDidEnterBackground()
        precondition(TestDriver.locks == locks, "Duplicate background notifications must be idempotent")
        _ = session.unlock(using: "1234")
        precondition(!session.isUnlocked, "A delayed passcode action must not unlock in the background")
        session.handleScenePhaseChange(isActive: true)
        let stale = Task { await session.unlockPrimaryWithBiometrics(isAutomaticAttempt: true) }
        await waitForRequest(2)
        session.handleDidEnterBackground()
        session.handleScenePhaseChange(isActive: true)
        let current = Task { await session.unlockPrimaryWithBiometrics(isAutomaticAttempt: true) }
        await waitForRequest(3)
        TestDriver.complete(1, .success(.spaceA, Data([2])))
        let ignored = await stale.value
        precondition(ignored == nil && !session.isUnlocked && session.isAuthenticating && TestDriver.activatedKeys == 1, "A stale success must not unlock or cancel the newer request")
        TestDriver.complete(2, .failure(message: String(localized: "生物识别已取消。")))
        _ = await current.value
        precondition(!session.isAuthenticating && !session.canAutomaticallyAttemptBiometricUnlock, "User cancellation must not cause a prompt loop")
        session.recordBiometricFailure(message: String(localized: "生物识别已取消。"))
        precondition(!session.requiresPasscodeAfterBiometricFailures)

        let manual = Task { await session.unlockPrimaryWithBiometrics(isAutomaticAttempt: false) }
        await waitForRequest(4)
        session.lock(withMessage: "screenshot")
        TestDriver.complete(3, .success(.spaceA, Data([3])))
        _ = await manual.value
        precondition(!session.isUnlocked && TestDriver.activatedKeys == 1, "Screenshot/manual lock must defeat in-flight success")
        precondition(session.consumePendingUnlockMessage() == "screenshot")

        session.handleDidEnterBackground()
        session.handleScenePhaseChange(isActive: true)
        let interrupted = Task { await session.unlockPrimaryWithBiometrics(isAutomaticAttempt: true) }
        await waitForRequest(5)
        _ = session.unlock(using: "1234")
        TestDriver.complete(4, .success(.spaceB, Data([4])))
        _ = await interrupted.value
        precondition(session.activeSpace == .spaceA && TestDriver.activatedKeys == 1, "Passcode unlock must defeat in-flight biometric result")
        session.recordBiometricFailure(message: String(localized: "生物识别验证失败。"))
        session.recordBiometricFailure(message: String(localized: "生物识别验证失败。"))
        session.handleDidEnterBackground()
        session.handleScenePhaseChange(isActive: true)
        precondition(session.requiresPasscodeAfterBiometricFailures && !session.canAutomaticallyAttemptBiometricUnlock, "Real failures must retain the passcode fallback")
        print("App lock lifecycle and delayed authentication regressions passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='privygallery-app-lock-') as folder:
    folder = Path(folder)
    (folder / 'Fixtures.swift').write_text(fixtures)
    (folder / 'Session.swift').write_text((ROOT / 'SecurityFolder/App/AppSessionViewModel.swift').read_text())
    (folder / 'Checks.swift').write_text(checks)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'module-cache'),
                    str(folder / 'Fixtures.swift'), str(folder / 'Session.swift'),
                    str(ROOT / 'SecurityFolder/Core/Models/VaultSpaceKind.swift'),
                    str(ROOT / 'SecurityFolder/Core/Models/AppSettingsKey.swift'),
                    str(ROOT / 'SecurityFolder/Shared/Models/AppNotifications.swift'),
                    str(folder / 'Checks.swift'), '-o', str(folder / 'checks')], check=True)
    subprocess.run([str(folder / 'checks')], check=True)
