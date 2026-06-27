import Foundation

enum AppSettingsKey {
    // MARK: - General preferences
    static let trashRetentionDays = "trashRetentionDays"
    static let defaultTrashRetentionDays = 30
    static let legacyAutoLockTimeoutMinutes = "autoLockTimeoutMinutes"
    static let autoLockTimeoutSeconds = "autoLockTimeoutSeconds"
    static let defaultAutoLockTimeoutSeconds = 60
    static let appTheme = "appTheme"
    static let appLanguage = "appLanguage"
    static let advancedDataProtectionEnabled = "advancedDataProtectionEnabled"
    static let defaultAdvancedDataProtectionEnabled = false
    static let screenPrivacyProtectionEnabled = "screenPrivacyProtectionEnabled"
    static let defaultScreenPrivacyProtectionEnabled = true
    static let deleteImportedSystemAssetsAfterImport = "deleteImportedSystemAssetsAfterImport"
    static let defaultDeleteImportedSystemAssetsAfterImport = true
    static let biometricUnlockEnabled = "biometricUnlockEnabled"
    static let defaultBiometricUnlockEnabled = false
    static let autoSubmitNumericPasscode = "autoSubmitNumericPasscode"
    static let defaultAutoSubmitNumericPasscode = true
    static let spaceADisplayName = "spaceADisplayName"
    static let spaceBDisplayName = "spaceBDisplayName"
    static let installMarker = "installMarker"
    static let legacySecondary1111CleanupCompleted = "legacySecondary1111CleanupCompleted"
    static let lastBackupRecoveryNotice = "lastBackupRecoveryNotice"
    static let spaceALibrarySortOption = "spaceALibrarySortOption"
    static let spaceBLibrarySortOption = "spaceBLibrarySortOption"
    static let lockButtonHintShown = "lockButtonHintShown"

    // MARK: - Biometric routing
    static let biometricUnlockMode = "biometricUnlockMode"
    static let biometricDefaultSpace = "biometricDefaultSpace"
    static let biometricScheduledPrimarySpace = "biometricScheduledPrimarySpace"
    static let biometricScheduleStartMinutes = "biometricScheduleStartMinutes"
    static let biometricScheduleEndMinutes = "biometricScheduleEndMinutes"

    // MARK: - Passcode preferences
    static let spaceAPasscodeKind = "spaceAPasscodeKind"
    static let spaceBPasscodeKind = "spaceBPasscodeKind"
    static let coercionPasscodeKind = "coercionPasscodeKind"
    static let spaceACoercionPasscodeKind = "spaceACoercionPasscodeKind"
    static let spaceBCoercionPasscodeKind = "spaceBCoercionPasscodeKind"
}
