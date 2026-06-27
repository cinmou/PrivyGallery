import Foundation
import UIKit

/// 处理胁迫密码触发后的紧急清空。
/// 这里会清除本地密钥、媒体密文、加密元数据、备份文件、缩略图缓存、用户偏好和遗留明文元数据文件，
/// 然后立即终止进程，让应用回到首次安装后的初始化状态。
struct EmergencyWipeService {
    private let fileManager = FileManager.default

    func performCoercionWipeAndTerminate() {
        VaultCryptoService.shared.wipeAllPersistentKeys()
        AppLockService().clearCoercionPasscodeStorageForEmergencyWipe()
        MediaThumbnailService.shared.clearCache()
        clearUserDefaults()
        clearDocumentsDirectory()
        clearApplicationSupportBackupDirectories()
        clearTemporaryDirectory()
        SecurityFolderApp.wipeLegacyPersistentStoreFiles()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            // 用 fatalError 主动终止，确保应用不会继续停留在可交互状态。
            fatalError("Emergency wipe triggered.")
        }
    }

    private func clearUserDefaults() {
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
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
