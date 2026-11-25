import Darwin
import Foundation
import UIKit

/// 处理胁迫密码触发后的紧急清空。
/// 这里会清除本地密钥、媒体密文、加密元数据、备份文件、缩略图缓存、用户偏好和遗留明文元数据文件，
/// 然后立即终止进程，让应用回到首次安装后的初始化状态。
struct EmergencyWipeService {
    static let pendingWipeMarkerKey = "pendingEmergencyWipe"

    private let fileManager = FileManager.default

    func performCoercionWipeAndTerminate() -> Never {
        performWipe()
        // 使用 exit(0) 同步退出，避免穿透到解锁流程，也不产生包含胁迫字样的崩溃日志。
        exit(0)
    }

    func completePendingWipeIfNeeded() {
        guard UserDefaults.standard.bool(forKey: Self.pendingWipeMarkerKey) else { return }
        performWipe()
    }

    private func performWipe() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.pendingWipeMarkerKey)
        defaults.synchronize()

        VaultCryptoService.shared.wipeAllPersistentKeys()
        AppLockService().clearCoercionPasscodeStorageForEmergencyWipe()
        MediaThumbnailService.shared.clearCache()
        clearDocumentsDirectory()
        clearApplicationSupportBackupDirectories()
        clearTemporaryDirectory()
        SharedImportStore.shared.wipeAll()
        SecurityFolderApp.wipeLegacyPersistentStoreFiles()
        clearUserDefaults()
    }

    private func clearUserDefaults() {
        let defaults = UserDefaults.standard
        if let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty {
            defaults.removePersistentDomain(forName: bundleIdentifier)
        }
        defaults.removeObject(forKey: Self.pendingWipeMarkerKey)
        defaults.synchronize()
    }

    private func clearDocumentsDirectory() {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        if let contents = try? fileManager.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: nil
        ) {
            contents.forEach { url in
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func clearApplicationSupportBackupDirectories() {
        guard let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        ["BackupFiles", "BackupRecovery"].forEach { directoryName in
            let url = applicationSupportURL.appendingPathComponent(directoryName, isDirectory: true)
            if fileManager.fileExists(atPath: url.path()) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func clearTemporaryDirectory() {
        let temporaryURL = fileManager.temporaryDirectory
        if let contents = try? fileManager.contentsOfDirectory(
            at: temporaryURL,
            includingPropertiesForKeys: nil
        ) {
            contents.forEach { url in
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
