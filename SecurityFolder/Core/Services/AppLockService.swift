import Foundation
import LocalAuthentication
import CryptoKit

enum UnlockAttemptResult {
    case success(VaultSpaceKind)
    case failure(message: String)
}

enum PasscodeUpdateResult {
    case success
    case failure(message: String)
}

struct AppLockService {
    private let cryptoService: VaultCryptoService
    private let defaults: UserDefaults

    init(
        cryptoService: VaultCryptoService = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.cryptoService = cryptoService
        self.defaults = defaults
    }

    var biometricHardwareAvailable: Bool {
        cryptoService.biometricUnlockAvailable
    }

    var biometricUnlockAvailable: Bool {
        biometricUnlockEnabled && biometricHardwareAvailable
    }

    var biometricUnlockEnabled: Bool {
        if defaults.object(forKey: AppSettingsKey.biometricUnlockEnabled) == nil {
            return AppSettingsKey.defaultBiometricUnlockEnabled
        }
        return defaults.bool(forKey: AppSettingsKey.biometricUnlockEnabled)
    }

    func setBiometricUnlockEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: AppSettingsKey.biometricUnlockEnabled)
    }

    func isPasscodeConfigured(for space: VaultSpaceKind) -> Bool {
        cryptoService.hasWrappedKey(for: space)
    }

    func configuredPasscodeKind(for space: VaultSpaceKind) -> AppPasscodeKind? {
        guard isPasscodeConfigured(for: space) else { return nil }
        let key = passcodeKindKey(for: space)
        return defaults.string(forKey: key).flatMap(AppPasscodeKind.init(rawValue:)) ?? .fourDigits
    }

    func unlockPrimaryWithBiometrics() -> UnlockAttemptResult {
        guard biometricUnlockEnabled else {
            return .failure(message: String(localized: "生物识别已在设置中关闭。"))
        }

        do {
            let targetSpace = BiometricUnlockSettings.load().resolvedSpace()
            let targetSpaceDisplayName = SpaceDisplaySettings.displayName(for: targetSpace)
            guard isPasscodeConfigured(for: targetSpace) else {
                return .failure(
                    message: String.localizedStringWithFormat(
                        String(localized: "%@ 还没有设置密码。"),
                        targetSpaceDisplayName
                    )
                )
            }

            try cryptoService.unlockWithBiometrics(space: targetSpace)
            return .success(targetSpace)
        } catch {
            return .failure(message: unlockErrorMessage(for: error))
        }
    }

    func validate(
        passcode: String,
        for space: VaultSpaceKind,
        allowCoercionTrigger: Bool = false
    ) -> UnlockAttemptResult {
        let displayName = SpaceDisplaySettings.displayName(for: space)
        guard isPasscodeConfigured(for: space) else {
            return .failure(
                message: String.localizedStringWithFormat(
                    String(localized: "%@ 还没有设置密码。"),
                    displayName
                )
            )
        }

        let normalizedInput = normalizePotentialPasscode(passcode, for: space)
        if allowCoercionTrigger && matchesCoercionPasscode(normalizedInput, for: space) {
            EmergencyWipeService().performCoercionWipeAndTerminate()
        }

        do {
            try cryptoService.unlock(space: space, passcode: normalizedInput)
            return .success(space)
        } catch {
            return .failure(message: unlockErrorMessage(for: error))
        }
    }

    /// 兼容现有调用：会尝试依次匹配两个空间。
    func validate(passcode: String, allowCoercionTrigger: Bool = false) -> UnlockAttemptResult {
        let configuredSpaces = VaultSpaceKind.allCases.filter { isPasscodeConfigured(for: $0) }
        guard !configuredSpaces.isEmpty else {
            return .failure(message: String(localized: "当前还没有可解锁的空间。"))
        }

        if allowCoercionTrigger {
            for space in configuredSpaces {
                if matchesCoercionPasscode(normalizePotentialPasscode(passcode, for: space), for: space) {
                    EmergencyWipeService().performCoercionWipeAndTerminate()
                }
            }
        }

        for space in configuredSpaces {
            let result = validate(passcode: passcode, for: space, allowCoercionTrigger: allowCoercionTrigger)
            if case .success = result {
                return result
            }
        }
        return .failure(message: String(localized: "密码不正确，请重试。"))
    }

    func configureInitialPasscode(
        _ passcode: String,
        kind: AppPasscodeKind,
        for space: VaultSpaceKind
    ) -> PasscodeUpdateResult {
        guard kind.isValid(passcode) else {
            return .failure(message: String(localized: "密码格式不符合要求。"))
        }

        if let conflictMessage = validateCrossSpacePasscodeRules(
            proposedPasscode: passcode,
            proposedKind: kind,
            for: space
        ) {
            return .failure(message: conflictMessage)
        }

        do {
            try cryptoService.configurePasscode(for: space, newPasscode: kind.normalized(passcode))
            defaults.set(kind.rawValue, forKey: passcodeKindKey(for: space))
            return .success
        } catch {
            return .failure(message: unlockErrorMessage(for: error))
        }
    }

    func changePasscode(
        for space: VaultSpaceKind,
        currentPasscode: String,
        newPasscode: String,
        kind: AppPasscodeKind,
        allowTemporaryTypeMismatch: Bool = false
    ) -> PasscodeUpdateResult {
        guard kind.isValid(newPasscode) else {
            return .failure(message: String(localized: "新密码格式不符合要求。"))
        }

        if let currentKind = configuredPasscodeKind(for: space),
           currentKind != kind,
           !allowTemporaryTypeMismatch,
           let dependencyMessage = validatePasscodeTypeChangeDependencies(for: space) {
            return .failure(message: dependencyMessage)
        }

        if let conflictMessage = validateCrossSpacePasscodeRules(
            proposedPasscode: newPasscode,
            proposedKind: kind,
            for: space,
            allowTemporaryTypeMismatch: allowTemporaryTypeMismatch
        ) {
            return .failure(message: conflictMessage)
        }

        do {
            try cryptoService.changePasscode(
                for: space,
                oldPasscode: currentPasscode,
                newPasscode: kind.normalized(newPasscode)
            )
            defaults.set(kind.rawValue, forKey: passcodeKindKey(for: space))
            return .success
        } catch {
            return .failure(message: unlockErrorMessage(for: error))
        }
    }

    func lock() {
        cryptoService.lock()
    }

    /// 启动时对本地安全状态做一次自检。
    /// 主要解决“App 已经像新安装，但 Keychain 还残留旧密钥”的情况。
    func reconcilePersistentSecurityState() {
        let hasInstallMarker = defaults.bool(forKey: AppSettingsKey.installMarker)
        let hasSpaceAKey = isPasscodeConfigured(for: .spaceA)
        let hasSpaceBKey = isPasscodeConfigured(for: .spaceB)
        let hasSpaceAKind = defaults.string(forKey: AppSettingsKey.spaceAPasscodeKind) != nil
        let hasSpaceBKind = defaults.string(forKey: AppSettingsKey.spaceBPasscodeKind) != nil

        print("[SecurityFolder][Startup] installMarker=\(hasInstallMarker) spaceAKey=\(hasSpaceAKey) spaceBKey=\(hasSpaceBKey) spaceAKind=\(hasSpaceAKind) spaceBKind=\(hasSpaceBKind)")

        if !hasInstallMarker {
            if hasSpaceAKey || hasSpaceBKey {
                print("[SecurityFolder][Startup] Detected stale keychain data on a fresh install. Wiping persisted vault keys.")
                wipeAllSecurityState()
            }
            defaults.set(true, forKey: AppSettingsKey.installMarker)
            return
        }

        performLegacySecondaryPasscodeCleanupIfNeeded()
        performLegacyCoercionPasscodeMigrationIfNeeded()

        let isCorruptedPrimaryState = hasSpaceAKey != hasSpaceAKind
        let isCorruptedSecondaryState = hasSpaceBKey != hasSpaceBKind
        let hasSecondaryWithoutPrimary = hasSpaceBKey && !hasSpaceAKey

        if isCorruptedPrimaryState || isCorruptedSecondaryState || hasSecondaryWithoutPrimary {
            print("[SecurityFolder][Startup] Detected inconsistent security state. primaryMismatch=\(isCorruptedPrimaryState) secondaryMismatch=\(isCorruptedSecondaryState) secondaryWithoutPrimary=\(hasSecondaryWithoutPrimary). Wiping persisted vault keys.")
            wipeAllSecurityState()
            defaults.set(true, forKey: AppSettingsKey.installMarker)
        }
    }

    func hasCoercionPasscode(for space: VaultSpaceKind) -> Bool {
        keychainItemExists(account: coercionAccount())
    }

    func configuredCoercionPasscodeKind(for space: VaultSpaceKind) -> AppPasscodeKind? {
        guard hasCoercionPasscode(for: space) else { return nil }
        let key = coercionKindKey()
        return defaults.string(forKey: key).flatMap(AppPasscodeKind.init(rawValue:))
    }

    func configureCoercionPasscode(
        _ passcode: String,
        kind: AppPasscodeKind,
        for space: VaultSpaceKind,
        allowTemporaryTypeMismatch: Bool = false
    ) -> PasscodeUpdateResult {
        guard kind.isValid(passcode) else {
            return .failure(message: String(localized: "密码格式不符合要求。"))
        }

        if let conflictMessage = validateCoercionPasscodeRules(
            proposedPasscode: passcode,
            proposedKind: kind,
            for: space,
            allowTemporaryTypeMismatch: allowTemporaryTypeMismatch
        ) {
            return .failure(message: conflictMessage)
        }

        do {
            let digest = coercionDigest(for: kind.normalized(passcode))
            try saveKeychainData(digest, account: coercionAccount())
            defaults.set(kind.rawValue, forKey: coercionKindKey())
            return .success
        } catch {
            return .failure(message: String(localized: "胁迫密码保存失败，请重试。"))
        }
    }

    func removeCoercionPasscode(for space: VaultSpaceKind) {
        deleteKeychainItem(account: coercionAccount())
        defaults.removeObject(forKey: coercionKindKey())
        clearLegacyCoercionPasscodeState()
    }

    func clearCoercionPasscodeStorageForEmergencyWipe() {
        deleteKeychainItem(account: coercionAccount())
        defaults.removeObject(forKey: coercionKindKey())
        clearLegacyCoercionPasscodeState()
    }

    func authenticateOwner(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(false)
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            completion(success)
        }
    }
    
    func wipeAllSecurityStateForTesting() {
        wipeAllSecurityState()
    }

    private func passcodeKindKey(for space: VaultSpaceKind) -> String {
        switch space {
        case .spaceA:
            AppSettingsKey.spaceAPasscodeKind
        case .spaceB:
            AppSettingsKey.spaceBPasscodeKind
        }
    }

    private func coercionKindKey() -> String {
        AppSettingsKey.coercionPasscodeKind
    }

    private func coercionAccount() -> String {
        "global.coercion.hash"
    }

    private func siblingSpace(for space: VaultSpaceKind) -> VaultSpaceKind {
        switch space {
        case .spaceA:
            return .spaceB
        case .spaceB:
            return .spaceA
        }
    }

    private func validateCrossSpacePasscodeRules(
        proposedPasscode: String,
        proposedKind: AppPasscodeKind,
        for space: VaultSpaceKind,
        allowTemporaryTypeMismatch: Bool = false
    ) -> String? {
        let otherSpace = siblingSpace(for: space)

        if configuredCoercionKinds().contains(where: { $0 != proposedKind }) && !allowTemporaryTypeMismatch {
            return String(localized: "胁迫密码类型必须和主空间、第二空间保持一致。")
        }

        let normalizedPasscode = proposedKind.normalized(proposedPasscode)
        if isPasscodeConfigured(for: otherSpace) {
            if let otherKind = configuredPasscodeKind(for: otherSpace),
               otherKind != proposedKind,
               !allowTemporaryTypeMismatch {
                return String(localized: "两个空间必须使用同一种密码类型。")
            }

            if matchesPrimaryPasscode(normalizedPasscode, for: otherSpace, kind: proposedKind) {
                return String(localized: "两个空间不能使用相同的密码。")
            }
        }

        if matchesAnyConfiguredCoercionPasscode(normalizedPasscode, kind: proposedKind) {
            return String(localized: "胁迫密码、主空间密码和第二空间密码不能重复。")
        }

        return nil
    }

    private func validateCoercionPasscodeRules(
        proposedPasscode: String,
        proposedKind: AppPasscodeKind,
        for space: VaultSpaceKind,
        allowTemporaryTypeMismatch: Bool = false
    ) -> String? {
        guard let primaryKind = configuredPasscodeKind(for: .spaceA) else {
            return String(localized: "请先设置主空间密码。")
        }

        if proposedKind != primaryKind && !allowTemporaryTypeMismatch {
            return String(localized: "胁迫密码类型必须和主空间保持一致。")
        }

        let normalizedPasscode = proposedKind.normalized(proposedPasscode)
        if matchesAnyConfiguredPrimaryPasscode(normalizedPasscode, kind: proposedKind) {
            return String(localized: "胁迫密码、主空间密码和第二空间密码不能重复。")
        }

        return nil
    }

    private func validatePasscodeTypeChangeDependencies(for space: VaultSpaceKind) -> String? {
        let otherSpace = siblingSpace(for: space)
        let hasSiblingPasscode = isPasscodeConfigured(for: otherSpace)
        let hasCoercion = hasCoercionPasscode(for: space)

        guard hasSiblingPasscode || hasCoercion else {
            return nil
        }

        if hasSiblingPasscode && hasCoercion {
            return String(localized: "修改密码类型前，请先把第二空间密码和胁迫密码改成同一种类型，或先关闭它们。")
        }

        if hasSiblingPasscode {
            return String(localized: "修改密码类型前，请先处理第二空间密码，让两个空间保持同一种类型。")
        }

        return String(localized: "修改密码类型前，请先处理胁迫密码，让它和新的主空间密码保持同一种类型。")
    }

    private func normalizePotentialPasscode(_ passcode: String, for space: VaultSpaceKind) -> String {
        let kind = configuredPasscodeKind(for: space) ?? .custom
        return kind.normalized(passcode)
    }

    private func matchesCoercionPasscode(_ passcode: String, for space: VaultSpaceKind) -> Bool {
        guard hasCoercionPasscode(for: space),
              let kind = configuredCoercionPasscodeKind(for: space),
              let storedDigest = try? keychainData(account: coercionAccount()) else {
            return false
        }

        let normalized = kind.normalized(passcode)
        return storedDigest == coercionDigest(for: normalized)
    }

    private func matchesPrimaryPasscode(
        _ normalizedPasscode: String,
        for space: VaultSpaceKind,
        kind: AppPasscodeKind
    ) -> Bool {
        guard isPasscodeConfigured(for: space),
              configuredPasscodeKind(for: space) == kind else {
            return false
        }

        do {
            try cryptoService.unlock(space: space, passcode: normalizedPasscode)
            cryptoService.lock()
            return true
        } catch {
            cryptoService.lock()
            return false
        }
    }

    private func matchesAnyConfiguredPrimaryPasscode(
        _ normalizedPasscode: String,
        kind: AppPasscodeKind
    ) -> Bool {
        VaultSpaceKind.allCases.contains { space in
            matchesPrimaryPasscode(normalizedPasscode, for: space, kind: kind)
        }
    }

    private func matchesAnyConfiguredCoercionPasscode(
        _ normalizedPasscode: String,
        kind: AppPasscodeKind
    ) -> Bool {
        guard hasCoercionPasscode(for: .spaceA),
              configuredCoercionPasscodeKind(for: .spaceA) == kind else {
            return false
        }
        return matchesCoercionPasscode(normalizedPasscode, for: .spaceA)
    }

    private func configuredCoercionKinds() -> [AppPasscodeKind] {
        configuredCoercionPasscodeKind(for: .spaceA).map { [$0] } ?? []
    }

    private func coercionDigest(for passcode: String) -> Data {
        let material = Data("SecurityFolder.Coercion|\(passcode)".utf8)
        return Data(SHA256.hash(data: material))
    }

    private func saveKeychainData(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.cinmouice.SecurityFolder.coercion",
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return
        }

        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "com.cinmouice.SecurityFolder.coercion",
                    kSecAttrAccount as String: account
                ] as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )

            guard updateStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
            }
            return
        }

        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    private func keychainData(account: String) throws -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.cinmouice.SecurityFolder.coercion",
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ] as CFDictionary,
            &item
        )

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        return item as? Data
    }

    private func deleteKeychainItem(account: String) {
        SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.cinmouice.SecurityFolder.coercion",
                kSecAttrAccount as String: account
            ] as CFDictionary
        )
    }

    private func keychainItemExists(account: String) -> Bool {
        let status = SecItemCopyMatching(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.cinmouice.SecurityFolder.coercion",
                kSecAttrAccount as String: account,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ] as CFDictionary,
            nil
        )

        return status == errSecSuccess
    }

    private func wipeAllSecurityState() {
        cryptoService.wipeAllPersistentKeys()
        defaults.removeObject(forKey: AppSettingsKey.spaceAPasscodeKind)
        defaults.removeObject(forKey: AppSettingsKey.spaceBPasscodeKind)
        defaults.removeObject(forKey: AppSettingsKey.coercionPasscodeKind)
        defaults.removeObject(forKey: AppSettingsKey.spaceACoercionPasscodeKind)
        defaults.removeObject(forKey: AppSettingsKey.spaceBCoercionPasscodeKind)
        defaults.removeObject(forKey: AppSettingsKey.biometricUnlockMode)
        defaults.removeObject(forKey: AppSettingsKey.biometricDefaultSpace)
        defaults.removeObject(forKey: AppSettingsKey.biometricScheduledPrimarySpace)
        defaults.removeObject(forKey: AppSettingsKey.biometricScheduleStartMinutes)
        defaults.removeObject(forKey: AppSettingsKey.biometricScheduleEndMinutes)
        deleteKeychainItem(account: coercionAccount())
        clearLegacyCoercionPasscodeState()
    }

    private func performLegacySecondaryPasscodeCleanupIfNeeded() {
        guard !defaults.bool(forKey: AppSettingsKey.legacySecondary1111CleanupCompleted) else {
            return
        }

        defer {
            defaults.set(true, forKey: AppSettingsKey.legacySecondary1111CleanupCompleted)
        }

        guard isPasscodeConfigured(for: .spaceB) else {
            return
        }

        let legacyResult = validate(passcode: "1111", for: .spaceB, allowCoercionTrigger: false)
        if case .success = legacyResult {
            print("[SecurityFolder][Startup] Detected legacy secondary passcode 1111 residue. Wiping persisted vault keys.")
            wipeAllSecurityState()
        }
    }

    private func performLegacyCoercionPasscodeMigrationIfNeeded() {
        let hasGlobalCoercion = keychainItemExists(account: coercionAccount())
        let legacyEntries = VaultSpaceKind.allCases.compactMap { space -> (VaultSpaceKind, Data, AppPasscodeKind)? in
            guard let digest = try? keychainData(account: legacyCoercionAccount(for: space)),
                  let kind = legacyConfiguredCoercionPasscodeKind(for: space) else {
                return nil
            }
            return (space, digest, kind)
        }

        guard !legacyEntries.isEmpty else { return }

        if !hasGlobalCoercion, let preferredEntry = legacyEntries.first(where: { $0.0 == .spaceA }) ?? legacyEntries.first {
            do {
                try saveKeychainData(preferredEntry.1, account: coercionAccount())
                defaults.set(preferredEntry.2.rawValue, forKey: coercionKindKey())
                print("[SecurityFolder][Startup] Migrated legacy coercion passcode from \(preferredEntry.0.rawValue) to global storage.")
            } catch {
                print("[SecurityFolder][Startup] Failed to migrate legacy coercion passcode: \(error)")
            }
        }

        if legacyEntries.count > 1 {
            print("[SecurityFolder][Startup] Found multiple legacy coercion passcodes. Kept one global coercion passcode and removed the extra legacy entries.")
        }

        clearLegacyCoercionPasscodeState()
    }

    private func legacyConfiguredCoercionPasscodeKind(for space: VaultSpaceKind) -> AppPasscodeKind? {
        let key: String
        switch space {
        case .spaceA:
            key = AppSettingsKey.spaceACoercionPasscodeKind
        case .spaceB:
            key = AppSettingsKey.spaceBCoercionPasscodeKind
        }
        return defaults.string(forKey: key).flatMap(AppPasscodeKind.init(rawValue:))
    }

    private func legacyCoercionAccount(for space: VaultSpaceKind) -> String {
        "space.\(space.rawValue).coercion.hash"
    }

    private func clearLegacyCoercionPasscodeState() {
        defaults.removeObject(forKey: AppSettingsKey.spaceACoercionPasscodeKind)
        defaults.removeObject(forKey: AppSettingsKey.spaceBCoercionPasscodeKind)
        VaultSpaceKind.allCases.forEach { deleteKeychainItem(account: legacyCoercionAccount(for: $0)) }
    }

    private func unlockErrorMessage(for error: Error) -> String {
        if let cryptoError = error as? VaultCryptoError {
            return cryptoError.localizedDescription
        }

        let nsError = error as NSError
        let code = OSStatus(nsError.code)
        switch code {
        case errSecUserCanceled:
            return String(localized: "生物识别已取消。")
        case errSecAuthFailed:
            return String(localized: "生物识别验证失败。")
        default:
            return String(localized: "密码不正确，或当前空间的密钥不可用。")
        }
    }
}
