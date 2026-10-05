import Foundation
import Combine
import LocalAuthentication
import OSLog

@MainActor
final class AppSessionViewModel: ObservableObject {
    @Published var activeSpace: VaultSpaceKind?
    @Published var selectedTab: AppTab = .media
    @Published private(set) var isSceneActive = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var pendingUnlockMessage: String?

    private let lockService = AppLockService()
    private var authenticationID: UUID?
    private var authenticationContext: LAContext?
    private var authenticationCompletion: (@MainActor (Bool) -> Void)?
    private var hasEnteredBackground = false
    private let logger = Logger(subsystem: "com.cinmouice.SecurityFolder", category: "AppLock")
    private var autoLockTimer: AnyCancellable?
    private var lastInteractionAt = Date()
    private var shouldAutomaticallyAttemptBiometricUnlock = true
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
        shouldAutomaticallyAttemptBiometricUnlock && !isAuthenticating
    }

    var requiresPasscodeAfterBiometricFailures: Bool {
        consecutiveBiometricFailureCount >= 2
    }

    var unlockLockoutRemaining: TimeInterval? {
        lockService.unlockLockoutRemaining()
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
        guard !hasEnteredBackground else { return .failure(message: String(localized: "生物识别已取消。")) }
        cancelAuthentication()
        return applyUnlockResult(lockService.validate(passcode: passcode, for: space, allowCoercionTrigger: true))
    }

    func unlock(using passcode: String) -> UnlockAttemptResult {
        guard !hasEnteredBackground else { return .failure(message: String(localized: "生物识别已取消。")) }
        cancelAuthentication()
        return applyUnlockResult(lockService.validate(passcode: passcode, allowCoercionTrigger: true))
    }

    func unlockPrimaryWithBiometrics(isAutomaticAttempt: Bool) async -> UnlockAttemptResult? {
        guard !isUnlocked, isSceneActive, !hasEnteredBackground, !isAuthenticating,
              !requiresPasscodeAfterBiometricFailures,
              !isAutomaticAttempt || shouldAutomaticallyAttemptBiometricUnlock else { return nil }
        let id = UUID()
        let context = LAContext()
        authenticationID = id
        authenticationContext = context
        isAuthenticating = true
        shouldAutomaticallyAttemptBiometricUnlock = false
        logger.debug("Biometric unlock started")
        let result = await lockService.biometricKey(context: context)
        // A background event, screenshot lock or passcode unlock invalidates this request.
        // Never install key material returned by a stale authentication.
        guard authenticationID == id, !hasEnteredBackground else {
            logger.debug("Discarded stale biometric result")
            return nil
        }
        authenticationID = nil
        authenticationContext = nil
        isAuthenticating = false
        switch result {
        case let .success(space, data):
            lockService.activateBiometricKey(data, for: space)
            logger.debug("Biometric unlock succeeded")
            return applyUnlockResult(.success(space))
        case let .failure(message):
            logger.debug("Biometric unlock ended without unlocking")
            return .failure(message: message)
        }
    }

    func authenticateOwner(
        policy: LAPolicy = .deviceOwnerAuthentication,
        reason: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard isSceneActive, !hasEnteredBackground, !isAuthenticating else {
            completion(false)
            return
        }
        let context = LAContext()
        guard context.canEvaluatePolicy(policy, error: nil) else {
            completion(false)
            return
        }
        let id = UUID()
        authenticationID = id
        authenticationContext = context
        isAuthenticating = true
        authenticationCompletion = completion
        context.evaluatePolicy(policy, localizedReason: reason) { [weak self] success, _ in
            Task { @MainActor [weak self] in
                guard let self, self.authenticationID == id else { return }
                self.authenticationID = nil
                self.authenticationContext = nil
                self.isAuthenticating = false
                self.authenticationCompletion = nil
                completion(success)
            }
        }
    }

    private func cancelAuthentication() {
        let completion = authenticationCompletion
        authenticationCompletion = nil
        authenticationID = nil
        authenticationContext?.invalidate()
        authenticationContext = nil
        isAuthenticating = false
        completion?(false)
    }

    private func applyUnlockResult(_ result: UnlockAttemptResult) -> UnlockAttemptResult {
        if case let .success(space) = result {
            activeSpace = space
            selectedTab = .media
            syncSharedImportAppState()
            registerInteraction()
            startAutoLockMonitoring()
            shouldAutomaticallyAttemptBiometricUnlock = false
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
        lockService.verify(passcode: passcode, for: space)
    }

    func removeCoercionPasscode(for space: VaultSpaceKind) {
        lockService.removeCoercionPasscode(for: space)
        objectWillChange.send()
    }

    func lock(withMessage message: String? = nil) {
        lock(withMessage: message, allowAutomaticBiometricRetry: false)
    }

    func lock(withMessage message: String? = nil, allowAutomaticBiometricRetry: Bool) {
        cancelAuthentication()
        autoLockTimer?.cancel()
        autoLockTimer = nil
        lockService.lock()
        activeSpace = nil
        selectedTab = .media
        pendingUnlockMessage = message
        shouldAutomaticallyAttemptBiometricUnlock = allowAutomaticBiometricRetry && !requiresPasscodeAfterBiometricFailures
        NotificationCenter.default.post(name: .vaultDidLock, object: self)
    }

    func handleDidEnterBackground() {
        guard !hasEnteredBackground else { return }
        hasEnteredBackground = true
        isSceneActive = false
        logger.debug("Scene entered background")
        // Rearm once for the next foreground visit, including when authentication was interrupted.
        lock(allowAutomaticBiometricRetry: true)
    }

    func handleScenePhaseChange(isActive: Bool) {
        isSceneActive = isActive
        if isActive { hasEnteredBackground = false }
        logger.debug("Scene active: \(isActive)")
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

    func recordBiometricFailure(message: String) {
        guard message == String(localized: "生物识别验证失败。") else { return }
        consecutiveBiometricFailureCount += 1

        if requiresPasscodeAfterBiometricFailures {
            pendingUnlockMessage = String(localized: "生物识别已连续验证失败两次，请输入密码解锁。")
            shouldAutomaticallyAttemptBiometricUnlock = false
        }
    }

    func clearAllState() {
        cancelAuthentication()
        lockService.wipeAllSecurityStateForTesting()
        activeSpace = nil
        shouldAutomaticallyAttemptBiometricUnlock = false
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
