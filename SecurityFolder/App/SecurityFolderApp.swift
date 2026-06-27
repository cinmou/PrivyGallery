import SwiftUI

@main
struct SecurityFolderApp: App {
    @StateObject private var session: AppSessionViewModel

    init() {
        AppLockService().reconcilePersistentSecurityState()
        let recoveryNotice = BackupOperationRecoveryService.shared.recoverIfNeeded()
        if let recoveryNotice {
            UserDefaults.standard.set(recoveryNotice, forKey: AppSettingsKey.lastBackupRecoveryNotice)
        } else {
            UserDefaults.standard.removeObject(forKey: AppSettingsKey.lastBackupRecoveryNotice)
        }
        _session = StateObject(wrappedValue: AppSessionViewModel())
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(session: session)
        }
        // On Mac Catalyst the initial window size and minimum are set at runtime
        // via UIWindowScene (requestGeometryUpdate / sizeRestrictions) in
        // AppRootView; SwiftUI's .defaultSize is ignored in the Mac idiom.

    }

    /// 旧版本使用 SwiftData 将明文元数据写入 Application Support/default.store。
    /// 新版本已经迁移到每个空间单独的加密 manifest，这里只保留一个遗留清理入口，
    /// 方便紧急抹除或未来做一次性迁移收尾。
    static func legacyPersistentStoreURL() throws -> URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        try FileManager.default.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: true
        )

        return applicationSupportURL.appendingPathComponent("default.store")
    }

    static func wipeLegacyPersistentStoreFiles() {
        guard let storeURL = try? legacyPersistentStoreURL() else { return }

        let fileManager = FileManager.default
        let siblingURLs = [
            storeURL,
            storeURL.appendingPathExtension("shm"),
            storeURL.appendingPathExtension("wal")
        ]

        siblingURLs.forEach { url in
            if fileManager.fileExists(atPath: url.path()) {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
