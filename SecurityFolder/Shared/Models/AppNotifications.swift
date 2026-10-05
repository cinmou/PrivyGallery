import Foundation

extension Notification.Name {
    static let vaultDidLock = Notification.Name("vaultDidLock")
    static let vaultDidRefreshAfterImport = Notification.Name("vaultDidRefreshAfterImport")
    static let settingsShouldResetToRoot = Notification.Name("settingsShouldResetToRoot")
}
