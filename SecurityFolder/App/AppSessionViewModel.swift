import Foundation
import Combine

@MainActor
final class AppSessionViewModel: ObservableObject {
    @Published var activeSpace: VaultSpaceKind?
    @Published var selectedTab: AppTab = .media
    @Published var isSnapshotObscured = false
    @Published private(set) var isSceneActive = true
    @Published private(set) var pendingUnlockMessage: String?

    private let lockService = AppLockService()
    private var autoLockTimer: AnyCancellable?
    private var lastInteractionAt = Date()
    private var shouldAutomaticallyAttemptBiometricUnlock = true
    private var shouldSuppressAutomaticBiometricErrors = false
    private var consecutiveBiometricFailureCount = 0

    var isUnlocked: Bool {
        activeSpace != nil
    }

    var canUseBiometrics: Bool {
        lockService.biometricHardwareAvailable
    }

    var shouldRunPrimaryOnboarding: Bool {
        !isPasscodeConfigured(for: .spaceA)
    }

    var isBiometricUnlockEnabled: Bool {
        lockService.biometricUnlockEnabled
    }

    var canAutomaticallyAttemptBiometricUnlock: Bool {
        shouldAutomaticallyAttemptBiometricUnlock
    }

    var suppressAutomaticBiometricErrors: Bool {
        shouldSuppressAutomaticBiometricErrors
    }

    var requiresPasscodeAfterBiometricFailures: Bool {
        consecutiveBiometricFailureCount >= 2
    }

    init() {
        syncSharedImportAppState()
    }

    func isPasscodeConfigured(for space: VaultSpaceKind) -> Bool {
        lockService.isPasscodeConfigured(for: space)
    }

    func configuredPasscodeKind(for space: VaultSpaceKind) -> AppPasscodeKind? {
        lockService.configuredPasscodeKind(for: space)
    }

    func configuredCoercionPasscodeKind(for space: VaultSpaceKind) -> AppPasscodeKind? {
        lockService.configuredCoercionPasscodeKind(for: space)
    }

    func hasCoercionPasscode(for space: VaultSpaceKind) -> Bool {
        lockService.hasCoercionPasscode(for: space)
    }

    func displayName(for space: VaultSpaceKind) -> String {
        SpaceDisplaySettings.displayName(for: space)
    }

    func updateDisplayName(_ name: String, for space: VaultSpaceKind) {
        SpaceDisplaySettings.updateDisplayName(name, for: space)
        syncSharedImportAppState()
        objectWillChange.send()
    }

    func setBiometricUnlockEnabled(_ enabled: Bool) {
        lockService.setBiometricUnlockEnabled(enabled)
        objectWillChange.send()
    }

    func unlock(space: VaultSpaceKind, using passcode: String) -> UnlockAttemptResult {
        let result = lockService.validate(passcode: passcode, for: space, allowCoercionTrigger: true)
        if case let .success(space) = result {
            activeSpace = space
            selectedTab = .media
            syncSharedImportAppState()
            registerInteraction()
            startAutoLockMonitoring()
            isSnapshotObscured = false
            shouldAutomaticallyAttemptBiometricUnlock = false
            shouldSuppressAutomaticBiometricErrors = false
            consecutiveBiometricFailureCount = 0
        }
        return result
    }

    func unlock(using passcode: String) -> UnlockAttemptResult {
        let result = lockService.validate(passcode: passcode, allowCoercionTrigger: true)
        if case let .success(space) = result {
            activeSpace = space
            selectedTab = .media
            syncSharedImportAppState()
            registerInteraction()
            startAutoLockMonitoring()
            isSnapshotObscured = false
            shouldAutomaticallyAttemptBiometricUnlock = false
            shouldSuppressAutomaticBiometricErrors = false
            consecutiveBiometricFailureCount = 0
        }
        return result
    }

    func unlockPrimaryWithBiometrics() -> UnlockAttemptResult {
        let result = lockService.unlockPrimaryWithBiometrics()
        if case let .success(space) = result {
            activeSpace = space
            selectedTab = .media
            syncSharedImportAppState()
            registerInteraction()
            startAutoLockMonitoring()
            isSnapshotObscured = false
            shouldAutomaticallyAttemptBiometricUnlock = false
            shouldSuppressAutomaticBiometricErrors = false
            consecutiveBiometricFailureCount = 0
        }
        return result
    }

    func configureInitialPasscode(
        _ passcode: String,
        kind: AppPasscodeKind,
        for space: VaultSpaceKind,
        unlockAfterSetup: Bool = true
    ) -> PasscodeUpdateResult {
        let result = lockService.configureInitialPasscode(passcode, kind: kind, for: space)
        if case .success = result {
            syncSharedImportAppState()
        }
        if unlockAfterSetup, case .success = result {
            _ = unlock(space: space, using: kind.normalized(passcode))
        }
        return result
    }

    func changePasscode(
        for space: VaultSpaceKind,
        currentPasscode: String,
        newPasscode: String,
        kind: AppPasscodeKind,
        allowTemporaryTypeMismatch: Bool = false
    ) -> PasscodeUpdateResult {
        lockService.changePasscode(
            for: space,
            currentPasscode: currentPasscode,
            newPasscode: newPasscode,
            kind: kind,
            allowTemporaryTypeMismatch: allowTemporaryTypeMismatch
        )
    }

    /// 在不切换当前已解锁空间的前提下，为另一个空间初始化密码。
    /// 这样用户可以在空间 A 内先把空间 B 创建好，再回到锁定页分别进入。
    func createSpacePasscode(
        for space: VaultSpaceKind,
        passcode: String,
        kind: AppPasscodeKind
    ) -> PasscodeUpdateResult {
        let result = lockService.configureInitialPasscode(passcode, kind: kind, for: space)
        if case .success = result {
            syncSharedImportAppState()
            objectWillChange.send()
        }
        return result
    }

    func configureCoercionPasscode(
        _ passcode: String,
        kind: AppPasscodeKind,
        for space: VaultSpaceKind,
        allowTemporaryTypeMismatch: Bool = false
    ) -> PasscodeUpdateResult {
        let result = lockService.configureCoercionPasscode(
            passcode,
            kind: kind,
            for: space,
            allowTemporaryTypeMismatch: allowTemporaryTypeMismatch
        )

        if case .success = result {
            objectWillChange.send()
        }

        return result
    }

    func validatePasscode(_ passcode: String, for space: VaultSpaceKind) -> UnlockAttemptResult {
        lockService.validate(passcode: passcode, for: space, allowCoercionTrigger: false)
    }

    func removeCoercionPasscode(for space: VaultSpaceKind) {
        lockService.removeCoercionPasscode(for: space)
        objectWillChange.send()
    }

    func lock(withMessage message: String? = nil) {
        lock(withMessage: message, allowAutomaticBiometricRetry: false)
    }

    func lock(withMessage message: String? = nil, allowAutomaticBiometricRetry: Bool) {
        autoLockTimer?.cancel()
        autoLockTimer = nil
        lockService.lock()
        activeSpace = nil
        selectedTab = .media
        isSnapshotObscured = true
        pendingUnlockMessage = message
        shouldAutomaticallyAttemptBiometricUnlock = allowAutomaticBiometricRetry && !requiresPasscodeAfterBiometricFailures
        shouldSuppressAutomaticBiometricErrors = allowAutomaticBiometricRetry
        print("[SecurityFolder][Session] Locked. automaticBiometricRetry=\(allowAutomaticBiometricRetry)")
    }

    func switchToDecoyOrBlankSpace() {
        lock()
    }

    func handleDidEnterBackground() {
        isSnapshotObscured = true
        guard isUnlocked else { return }
        print("[SecurityFolder][Session] App entered background while unlocked. Locking and allowing automatic biometric retry on resume.")
        lock(allowAutomaticBiometricRetry: true)
    }

    func handleScenePhaseChange(isActive: Bool) {
        isSceneActive = isActive
        isSnapshotObscured = !isActive
    }

    func registerInteraction() {
        guard isUnlocked else { return }
        lastInteractionAt = .now
    }

    func consumePendingUnlockMessage() -> String? {
        let message = pendingUnlockMessage
        pendingUnlockMessage = nil
        return message
    }

    func markAutomaticBiometricUnlockAttempted() {
        shouldAutomaticallyAttemptBiometricUnlock = false
        print("[SecurityFolder][Session] Automatic biometric unlock attempt consumed.")
    }

    func consumeSuppressAutomaticBiometricErrors() -> Bool {
        let shouldSuppress = shouldSuppressAutomaticBiometricErrors
        shouldSuppressAutomaticBiometricErrors = false
        return shouldSuppress
    }

    func recordBiometricFailure(message: String) {
        if message == String(localized: "生物识别验证失败。") {
            consecutiveBiometricFailureCount += 1
            print("[SecurityFolder][Session] Biometric unlock failed. consecutiveFailures=\(consecutiveBiometricFailureCount)")

            if requiresPasscodeAfterBiometricFailures {
                pendingUnlockMessage = String(localized: "生物识别已连续验证失败两次，请输入密码解锁。")
                shouldAutomaticallyAttemptBiometricUnlock = false
                shouldSuppressAutomaticBiometricErrors = false
            }
        } else {
            print("[SecurityFolder][Session] Biometric unlock did not succeed. message=\(message)")
        }
    }

    func clearAllState() {
        lockService.wipeAllSecurityStateForTesting()
        activeSpace = nil
        shouldAutomaticallyAttemptBiometricUnlock = false
        shouldSuppressAutomaticBiometricErrors = false
        consecutiveBiometricFailureCount = 0
        pendingUnlockMessage = nil
        syncSharedImportAppState()
    }

    private func startAutoLockMonitoring() {
        autoLockTimer?.cancel()
        autoLockTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.evaluateAutoLock()
            }
    }

    private func evaluateAutoLock() {
        guard isUnlocked else { return }
        let timeoutSeconds = autoLockTimeoutSeconds
        guard timeoutSeconds > 0 else { return }

        let timeoutInterval = TimeInterval(timeoutSeconds)
        if Date().timeIntervalSince(lastInteractionAt) >= timeoutInterval {
            lock()
        }
    }

    private var autoLockTimeoutSeconds: Int {
        let defaults = UserDefaults.standard
        if let storedSeconds = defaults.object(forKey: AppSettingsKey.autoLockTimeoutSeconds) as? Int {
            return storedSeconds
        }

        if defaults.object(forKey: AppSettingsKey.legacyAutoLockTimeoutMinutes) != nil {
            let legacyMinutes = defaults.integer(forKey: AppSettingsKey.legacyAutoLockTimeoutMinutes)
            let migratedSeconds = legacyMinutes > 0
                ? legacyMinutes * 60
                : AppSettingsKey.defaultAutoLockTimeoutSeconds
            defaults.set(migratedSeconds, forKey: AppSettingsKey.autoLockTimeoutSeconds)
            return migratedSeconds
        }

        return AppSettingsKey.defaultAutoLockTimeoutSeconds
    }

    private func syncSharedImportAppState() {
        var state = SharedImportStore.shared.appState
        state.currentTierRawValue = SubscriptionManager.shared.currentTier.rawValue
        state.isSpaceBConfigured = isPasscodeConfigured(for: .spaceB)
        state.spaceADisplayName = displayName(for: .spaceA)
        state.spaceBDisplayName = displayName(for: .spaceB)
        SharedImportStore.shared.appState = state
    }
}
