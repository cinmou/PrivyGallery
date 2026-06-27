import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    let space: VaultSpaceKind
    let trashRetentionOptions = [7, 15, 30, 60, 90]
    let autoLockTimeoutOptions = [0, 30, 60, 120, 180, 300]
    private let lockService = AppLockService()

    init(space: VaultSpaceKind) {
        self.space = space
    }

    var items: [SettingsItem] {
        [
            SettingsItem(
                title: String(localized: "整体加密备份"),
                detail: String(localized: "当前可整体导出当前空间，也可把 `.vault` 备份恢复到当前空间；恢复时会自动避开同名冲突。"),
                isEnabled: space.allowsFullBackup
            ),
            SettingsItem(
                title: String(localized: "分块文件加密"),
                detail: String(localized: "导入后的图片、视频和文件都会以分块密文写入沙盒。"),
                isEnabled: true
            )
        ]
    }

    func authenticateForSensitiveSettings(reason: String, completion: @escaping (Bool) -> Void) {
        lockService.authenticateOwner(reason: reason) { success in
            Task { @MainActor in
                completion(success)
            }
        }
    }

    func autoLockTitle(for seconds: Int) -> String {
        switch seconds {
        case 0:
            return String(localized: "无")
        case 30:
            return String(localized: "30 秒")
        case 60:
            return String(localized: "1 分钟")
        default:
            return String.localizedStringWithFormat(String(localized: "%lld 分钟"), Int64(seconds / 60))
        }
    }
}
