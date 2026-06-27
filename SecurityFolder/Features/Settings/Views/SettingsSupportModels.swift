import Foundation

/// 设置首页里受保护入口的路由目标。
/// 目前只剩密码子页，但单独保留类型后，后续继续拆分设置模块会更稳。
enum ProtectedSettingsDestination {
    case password
}

enum SettingsSidebarDestination: String, Identifiable {
    case membership
    case preferences
    case password
    case backupFiles
    case guide
    case legal
    case about

    var id: String { rawValue }
}

/// 设置页里需要先输当前空间密码的几类弹层。
/// 这里把标题、提示语也一起收口，避免主设置页继续堆文案判断。
enum SettingsAuthPrompt: Identifiable {
    case privacy
    case export
    case `import`

    var id: String {
        switch self {
        case .privacy:
            return "privacy"
        case .export:
            return "export"
        case .import:
            return "import"
        }
    }

    var title: String {
        switch self {
        case .privacy:
            return String(localized: "需要验证")
        case .export, .import:
            return String(localized: "验证权限")
        }
    }

    var message: String {
        switch self {
        case .privacy:
            return String(localized: "验证密码，以进入密码与空间选项。")
        case .export:
            return String(localized: "请验证当前空间的密码，妥善保存导出的文件。")
        case .import:
            return String(localized: "请验证当前空间的密码，确保导入是由您本人操作。")
        }
    }
}

/// 备份导入导出结束后的结果模型。
/// 之所以抽成独立类型，是因为设置首页和后续备份模块都可能复用相同的结果弹窗文案。
struct BackupResultAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let dismissTitle: String
    let shouldTerminateApplication: Bool

    static func failure(title: String, message: String) -> BackupResultAlert {
        BackupResultAlert(
            title: title,
            message: message,
            dismissTitle: String(localized: "确认"),
            shouldTerminateApplication: false
        )
    }

    static func importSucceeded(
        mediaCount: Int,
        albumCount: Int,
        strongProtectedMediaCount: Int,
        strongProtectedAlbumCount: Int,
        regularPhotoCount: Int = 0,
        regularVideoCount: Int = 0,
        skippedItemCount: Int = 0,
        failedItemCount: Int = 0,
        requiresMembershipReminder: Bool
    ) -> BackupResultAlert {
        var lines: [String] = [
            String(localized: "已恢复："),
            String.localizedStringWithFormat(String(localized: "普通图片：%lld 项"), regularPhotoCount),
            String.localizedStringWithFormat(String(localized: "普通视频：%lld 项"), regularVideoCount),
            String.localizedStringWithFormat(String(localized: "强加密项目：%lld 项"), strongProtectedMediaCount)
        ]

        if albumCount > 0 {
            lines.append(String.localizedStringWithFormat(String(localized: "相册：%lld 项"), albumCount))
        }
        if skippedItemCount > 0 {
            lines.append(String.localizedStringWithFormat(String(localized: "跳过：%lld 项"), skippedItemCount))
        }
        if failedItemCount > 0 {
            lines.append(String.localizedStringWithFormat(String(localized: "失败：%lld 项"), failedItemCount))
        }

        let baseMessage = lines.joined(separator: "\n")

        let advancedProtectionMessage: String
        if strongProtectedMediaCount > 0 || strongProtectedAlbumCount > 0 {
            if requiresMembershipReminder {
                advancedProtectionMessage = String.localizedStringWithFormat(
                    String(localized: "其中包含 %1$lld 个高级数据保护媒体和 %2$lld 个强加密相册；这部分内容需要会员并开启高级数据保护后才能查看。"),
                    strongProtectedMediaCount,
                    strongProtectedAlbumCount
                )
            } else {
                advancedProtectionMessage = String.localizedStringWithFormat(
                    String(localized: "其中包含 %1$lld 个高级数据保护媒体和 %2$lld 个强加密相册；查看这部分内容前，请确保高级数据保护保持开启。"),
                    strongProtectedMediaCount,
                    strongProtectedAlbumCount
                )
            }
        } else {
            advancedProtectionMessage = ""
        }

        return BackupResultAlert(
            title: String(localized: "恢复完成"),
            message: advancedProtectionMessage.isEmpty
                ? baseMessage
                : baseMessage + "\n\n" + advancedProtectionMessage,
            dismissTitle: String(localized: "确认"),
            shouldTerminateApplication: false
        )
    }

    static func backupSaved(fileCount: Int) -> BackupResultAlert {
        BackupResultAlert(
            title: String(localized: "备份已保存"),
            message: String.localizedStringWithFormat(String(localized: "备份已保存，已生成 %lld 个备份文件。"), fileCount),
            dismissTitle: String(localized: "知道了"),
            shouldTerminateApplication: false
        )
    }

    static let exportStopped = BackupResultAlert(
        title: String(localized: "导出已停止"),
        message: String(localized: "导出已取消，未完成的导出文件会自动清理。"),
        dismissTitle: String(localized: "知道了"),
        shouldTerminateApplication: false
    )

    static let importStopped = BackupResultAlert(
        title: String(localized: "恢复已停止"),
        message: String(localized: "恢复已取消，未完成的恢复文件会自动清理。"),
        dismissTitle: String(localized: "知道了"),
        shouldTerminateApplication: false
    )
}
