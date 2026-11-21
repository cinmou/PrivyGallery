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
        MacSettingsSection(String(localized: "偏好设置"), footer: autoLockFooterText) {
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

            Divider()

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

            Divider()

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

/// 验证当前空间密码后才显示的隐私控制项。
struct SettingsPrivacySectionView: View {
    @AppStorage(AppSettingsKey.hideContentDuringCapture)
    private var hideContentDuringCapture = AppSettingsKey.defaultHideContentDuringCapture
    @Binding var lockAfterScreenshotEnabled: Bool
    @Binding var deleteImportedSystemAssetsAfterImport: Bool
    let advancedProtectionBinding: Binding<Bool>
    let advancedProtectionEnabled: Bool
    let canUseAdvancedProtection: Bool
    let advancedProtectionFooterText: String

    var body: some View {
        Group {
        #if targetEnvironment(macCatalyst)
        MacSettingsSection(footer: advancedProtectionFooterText) {
            MacSettingsToggleRow(String(localized: "侦测到截屏后锁定"), isOn: $lockAfterScreenshotEnabled)
            Divider()
            MacSettingsToggleRow(String(localized: "录屏或投屏时隐藏内容"), isOn: $hideContentDuringCapture)
            Divider()
            MacSettingsToggleRow(String(localized: "导入后删除"), isOn: $deleteImportedSystemAssetsAfterImport)
            Divider()

            if canUseAdvancedProtection {
                MacSettingsToggleRow(String(localized: "安全预览模式"), isOn: advancedProtectionBinding)
            } else {
                NavigationLink {
                    MembershipCenterView()
                } label: {
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
        }
        .toggleStyle(.switch)
        #else
        Section {
            Toggle(String(localized: "侦测到截屏后锁定"), isOn: $lockAfterScreenshotEnabled)
            Toggle(String(localized: "录屏或投屏时隐藏内容"), isOn: $hideContentDuringCapture)
            Toggle(String(localized: "导入后删除"), isOn: $deleteImportedSystemAssetsAfterImport)

            if canUseAdvancedProtection {
                Toggle(String(localized: "安全预览模式"), isOn: advancedProtectionBinding)
            } else {
                NavigationLink {
                    MembershipCenterView()
                } label: {
                    HStack {
                        Text(String(localized: "安全预览模式"))
                        Spacer()
                        Toggle("", isOn: .constant(advancedProtectionEnabled))
                            .labelsHidden()
                            .disabled(true)
                    }
                }
                .navigationLinkIndicatorVisibility(.hidden)
            }
        }
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
        MacSettingsSection(String(localized: "备份与恢复"), footer: backupFooterText) {
            MacSettingsActionRow(
                String(localized: "备份当前空间"),
                buttonTitle: exportingVault ? String(localized: "正在导出...") : String(localized: "导出"),
                isDisabled: exportingVault,
                action: onExport
            )

            Divider()

            MacSettingsActionRow(
                String(localized: "恢复到当前空间"),
                buttonTitle: importingVault ? String(localized: "正在恢复备份...") : String(localized: "恢复"),
                isDisabled: importingVault,
                action: onImport
            )

            Divider()

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
        }
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
struct MacSettingsPageContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(SettingsAppearance.pageBackground.ignoresSafeArea())
    }
}

struct MacSettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var isDisabled: Bool = false

    init(_ title: String, isOn: Binding<Bool>, isDisabled: Bool = false) {
        self.title = title
        self._isOn = isOn
        self.isDisabled = isDisabled
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(isDisabled)
        }
    }
}

struct MacSettingsActionRow: View {
    let title: String
    let buttonTitle: String
    let role: ButtonRole?
    let isDisabled: Bool
    let action: () -> Void

    init(
        _ title: String,
        buttonTitle: String,
        role: ButtonRole? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.buttonTitle = buttonTitle
        self.role = role
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(buttonTitle, role: role, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDisabled)
        }
    }
}

struct MacSettingsSection<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .macSettingsCardBorder(cornerRadius: 10)
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }
}
#endif
