import SwiftUI

/// 设置首页的“偏好设置”分组。
/// 只负责界面呈现和交互转发，不承载导入导出或密码验证之类的业务状态。
struct SettingsPreferencesSectionView: View {
    @Binding var appTheme: String
    @Binding var trashRetentionDays: Int
    @Binding var autoLockTimeoutSeconds: Int

    let themeOptions: [ThemeOption]
    let trashRetentionOptions: [Int]
    let autoLockTimeoutOptions: [Int]
    let autoLockFooterText: String
    let autoLockTitle: (Int) -> String

    var body: some View {
        Group {
        #if targetEnvironment(macCatalyst)
        MacSettingsSection(String(localized: "偏好设置")) {
            HStack {
                Text(String(localized: "应用主题"))
                Spacer()
            Picker(String(localized: "应用主题"), selection: $appTheme) {
                ForEach(themeOptions) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
                .labelsHidden()
            }

            HStack {
                Text(String(localized: "回收站文件保留"))
                Spacer()
            Picker(String(localized: "回收站文件保留"), selection: $trashRetentionDays) {
                ForEach(trashRetentionOptions, id: \.self) { days in
                    Text(String.localizedStringWithFormat(String(localized: "%lld 天"), Int64(days))).tag(days)
                }
            }
                .labelsHidden()
            }

            HStack {
                Text(String(localized: "无操作后锁定"))
                Spacer()
            Picker(String(localized: "无操作后锁定"), selection: $autoLockTimeoutSeconds) {
                ForEach(autoLockTimeoutOptions, id: \.self) { seconds in
                    Text(autoLockTitle(seconds)).tag(seconds)
                }
            }
                .labelsHidden()
            }
            Text(autoLockFooterText).font(.footnote).foregroundStyle(.secondary)

        }
        .controlSize(.small)
        .pickerStyle(.menu)
        #else
        Section {
            Picker(String(localized: "应用主题"), selection: $appTheme) {
                ForEach(themeOptions) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }

            Picker(String(localized: "回收站文件保留"), selection: $trashRetentionDays) {
                ForEach(trashRetentionOptions, id: \.self) { days in
                    Text(String.localizedStringWithFormat(String(localized: "%lld 天"), Int64(days))).tag(days)
                }
            }

            Picker(String(localized: "无操作后锁定"), selection: $autoLockTimeoutSeconds) {
                ForEach(autoLockTimeoutOptions, id: \.self) { seconds in
                    Text(autoLockTitle(seconds)).tag(seconds)
                }
            }
        } header: {
            Text(String(localized: "偏好设置"))
        }
        #endif
        }
    }
}

/// 设置首页的“隐私与安全”分组。
/// 这里把开关和入口按钮拆出来后，主设置页就不需要继续堆一大段行内 UI 代码。
struct SettingsPrivacySectionView: View {
    @AppStorage(AppSettingsKey.hideContentDuringCapture)
    private var hideContentDuringCapture = AppSettingsKey.defaultHideContentDuringCapture
    @Binding var lockAfterScreenshotEnabled: Bool
    @Binding var deleteImportedSystemAssetsAfterImport: Bool
    let advancedProtectionBinding: Binding<Bool>
    let advancedProtectionEnabled: Bool
    let canUseAdvancedProtection: Bool
    let advancedProtectionFooterText: String
    let onOpenPassword: () -> Void
    let onAttemptEnableAdvancedProtection: () -> Void

    var body: some View {
        Group {
        #if targetEnvironment(macCatalyst)
        MacSettingsSection(String(localized: "隐私与安全")) {
            HStack {
                Text(String(localized: "侦测到截屏后锁定"))
                Spacer()
                Toggle(String(localized: "侦测到截屏后锁定"), isOn: $lockAfterScreenshotEnabled).labelsHidden()
            }
            HStack {
                Text(String(localized: "录屏或投屏时隐藏内容"))
                Spacer()
                Toggle(String(localized: "录屏或投屏时隐藏内容"), isOn: $hideContentDuringCapture).labelsHidden()
            }
            HStack {
                Text(String(localized: "导入后删除"))
                Spacer()
                Toggle(String(localized: "导入后删除"), isOn: $deleteImportedSystemAssetsAfterImport).labelsHidden()
            }

            if canUseAdvancedProtection {
                HStack {
                Text(String(localized: "安全预览模式"))
                Spacer()
                Toggle(String(localized: "安全预览模式"), isOn: advancedProtectionBinding).labelsHidden()
            }
            } else {
                Button(action: onAttemptEnableAdvancedProtection) {
                    HStack {
                        Text(String(localized: "安全预览模式"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Toggle("", isOn: .constant(advancedProtectionEnabled))
                            .labelsHidden()
                            .disabled(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button(action: onOpenPassword) {
                HStack {
                    Text(String(localized: "密码与空间"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.primary)
            Text(advancedProtectionFooterText).font(.footnote).foregroundStyle(.secondary)

        }
        .controlSize(.small)
        .toggleStyle(.switch)
        #else
        Section {
            Toggle(String(localized: "侦测到截屏后锁定"), isOn: $lockAfterScreenshotEnabled)
            Toggle(String(localized: "录屏或投屏时隐藏内容"), isOn: $hideContentDuringCapture)
            Toggle(String(localized: "导入后删除"), isOn: $deleteImportedSystemAssetsAfterImport)

            if canUseAdvancedProtection {
                Toggle(String(localized: "安全预览模式"), isOn: advancedProtectionBinding)
            } else {
                Button(action: onAttemptEnableAdvancedProtection) {
                    HStack {
                        Text(String(localized: "安全预览模式"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Toggle("", isOn: .constant(advancedProtectionEnabled))
                            .labelsHidden()
                            .disabled(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button(action: onOpenPassword) {
                HStack {
                    Text(String(localized: "密码与空间"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.primary)
        } header: {
            Text(String(localized: "隐私与安全"))
        }
        // Render the toggles as trailing switches (macOS puts the control on the
        // right) instead of the Mac idiom's default leading checkbox.
        .toggleStyle(.switch)
        #endif
        }
    }
}

/// 设置首页的“备份与恢复”分组。
/// 这里只负责按钮展示和禁用状态，把真正的导入导出流程继续留在设置页协调。
struct SettingsBackupSectionView: View {
    let exportingVault: Bool
    let importingVault: Bool
    let backupFooterText: String
    let onExport: () -> Void
    let onImport: () -> Void
    let onOpenBackupFiles: () -> Void

    var body: some View {
        Group {
        #if targetEnvironment(macCatalyst)
        MacSettingsSection(String(localized: "备份与恢复")) {
            Button(exportingVault ? String(localized: "正在导出...") : String(localized: "备份当前空间")) {
                onExport()
            }
            .disabled(exportingVault)

            Button(importingVault ? String(localized: "正在恢复备份...") : String(localized: "恢复到当前空间")) {
                onImport()
            }
            .disabled(importingVault)

            Button(action: onOpenBackupFiles) {
                HStack {
                    Text(String(localized: "当前备份文件"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(backupFooterText).font(.footnote).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        #else
        Section {
            Button(exportingVault ? String(localized: "正在导出...") : String(localized: "备份当前空间")) {
                onExport()
            }
            .disabled(exportingVault)

            Button(importingVault ? String(localized: "正在恢复备份...") : String(localized: "恢复到当前空间")) {
                onImport()
            }
            .disabled(importingVault)

            Button(action: onOpenBackupFiles) {
                HStack {
                    Text(String(localized: "当前备份文件"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text(String(localized: "备份与恢复"))
        } footer: {
            Text(backupFooterText)
        }
        #endif
        }
    }
}

#if targetEnvironment(macCatalyst)
struct MacSettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
#endif
