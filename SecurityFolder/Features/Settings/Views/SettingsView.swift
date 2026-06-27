import SwiftUI
import UniformTypeIdentifiers
import Photos
import UIKit

/// 设置界面
struct SettingsView: View {
    @ObservedObject var settingsViewModel: SettingsViewModel
    @ObservedObject var session: AppSessionViewModel

    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    // MARK: - AppStorage 属性
    
    /// 回收站项目保留天数，与 AppStorage 同步
    @AppStorage(AppSettingsKey.trashRetentionDays)
    private var trashRetentionDays = AppSettingsKey.defaultTrashRetentionDays
    
    /// 自动锁定超时时间（分钟），与 AppStorage 同步
    @AppStorage(AppSettingsKey.autoLockTimeoutSeconds)
    private var autoLockTimeoutSeconds = AppSettingsKey.defaultAutoLockTimeoutSeconds

    /// 应用主题外观，与 AppStorage 同步
    @AppStorage(AppSettingsKey.appTheme)
    private var appTheme = ThemeOption.system.rawValue

    /// 高级数据保护开启后，不再生成任何临时解密媒体文件。
    @AppStorage(AppSettingsKey.advancedDataProtectionEnabled)
    private var advancedDataProtectionEnabled = AppSettingsKey.defaultAdvancedDataProtectionEnabled
    @AppStorage(AppSettingsKey.screenPrivacyProtectionEnabled)
    private var screenPrivacyProtectionEnabled = AppSettingsKey.defaultScreenPrivacyProtectionEnabled
    @AppStorage(AppSettingsKey.deleteImportedSystemAssetsAfterImport)
    private var deleteImportedSystemAssetsAfterImport = AppSettingsKey.defaultDeleteImportedSystemAssetsAfterImport

    /// 上一次备份/恢复异常中断后的恢复提示。
    @AppStorage(AppSettingsKey.lastBackupRecoveryNotice)
    private var lastBackupRecoveryNotice = ""

    // MARK: - 状态属性
    
    /// 显示在界面上的状态消息
    @State private var settingsStatusMessage: String?
    /// 导出密码
    @State private var exportPassword = ""
    /// 导出密码确认
    @State private var exportPasswordConfirmation = ""
    /// 是否显示导出警告框
    @State private var showingExportAlert = false
    /// 是否正在导出保险箱
    @State private var exportingVault = false
    /// 导入密码
    @State private var importPassword = ""
    /// 是否显示导入文件选择器
    @State private var showingImportPicker = false
    /// 是否显示导入警告框
    @State private var showingImportAlert = false
    /// 是否正在导入保险箱
    @State private var importingVault = false
    /// 选择的导入文件 URL。v2 备份可能由多个独立 `.vault` 分片组成，因此这里允许一次选择多个文件。
    @State private var selectedImportURLs: [URL] = []
    /// 备份进度标题
    @State private var backupProgressTitle = ""
    /// 备份进度详情
    @State private var backupProgressDetail = ""
    /// 备份进度值；等待系统面板等无法估算的阶段为 nil。
    @State private var backupProgressValue: Double?
    @State private var backupProgressPart: (current: Int, total: Int) = (0, 0)
    @State private var backupProgressItem: (current: Int, total: Int) = (0, 0)
    @State private var backupProgressBytes: (current: Int64, total: Int64) = (0, 0)
    
    /// 用于验证进入隐私设置的密码
    @State private var privacyAuthPassword = ""
    /// 需要打开的受保护设置目标
    @State private var protectedDestination: ProtectedSettingsDestination?
    /// 是否显示高级数据保护提示
    @State private var showingAdvancedProtectionAlert = false
    /// 用于验证导出操作的当前空间密码
    @State private var exportAuthPassword = ""
    /// 用于验证导入操作的当前空间密码
    @State private var importAuthPassword = ""
    /// 当前显示的密码验证弹窗类型
    @State private var activeAuthPrompt: SettingsAuthPrompt?
    /// 密码验证失败时的弹窗文案
    @State private var authenticationFailureMessage = ""
    /// 是否显示密码验证失败弹窗
    @State private var showingAuthenticationFailureAlert = false
    /// 密码错误弹窗关闭后是否需要立刻锁定
    @State private var authenticationFailureRequiresLock = false
    /// 导出密码校验失败提示
    @State private var exportPasswordValidationMessage = ""
    /// 是否显示导出密码校验失败弹窗
    @State private var showingExportPasswordValidationAlert = false
    /// 当前导入/导出后台任务，用于中途停止。
    @State private var activeBackupTask: Task<Void, Never>?
    /// 当前备份操作结束后的结果弹窗。
    @State private var backupResultAlert: BackupResultAlert?
    /// 等待当前 sheet 完全关闭后再展示的导入/导出结果弹窗。
    @State private var pendingBackupResultAlert: BackupResultAlert?
    /// progress sheet 正在退场时先不要继续 present，避免和 share sheet / alert 相撞。
    @State private var waitingForBackupProgressDismissal = false
    /// 导入额度不足时，等进度页完全关闭后再打开会员中心，避免 presentation 相撞。
    @State private var shouldOpenMembershipAfterBackupDismissal = false
    @State private var selectedSidebarDestination: SettingsSidebarDestination?

    init(
        settingsViewModel: SettingsViewModel,
        session: AppSessionViewModel
    ) {
        self.settingsViewModel = settingsViewModel
        self.session = session
    }

    var body: some View {
        NavigationStack {
            settingsListContent
                .navigationTitle(String(localized: "设置"))
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(item: $selectedSidebarDestination) { destination in
                    settingsDestinationView(for: destination)
                }
        }
            .onReceive(NotificationCenter.default.publisher(for: .settingsShouldResetToRoot)) { _ in
                // 大屏媒体库右侧嵌入设置时，左侧点相册前先把设置二级页退回根级。
                selectedSidebarDestination = nil
            }
            .fileImporter(
                isPresented: $showingImportPicker,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case let .success(urls):
                    guard !urls.isEmpty else { return }
                    selectedImportURLs = urls
                    activeAuthPrompt = .import
                case let .failure(error):
                    settingsStatusMessage = error.localizedDescription
                }
            }
            .sheet(item: $activeAuthPrompt) { prompt in
                SettingsPasscodePromptView(
                    title: prompt.title,
                    message: prompt.message,
                    kind: currentPromptPasscodeKind,
                    passcode: binding(for: prompt),
                    onCancel: {
                        cancelAuthPrompt(prompt)
                    },
                    onConfirm: {
                        confirmAuthPrompt(prompt)
                    }
                )
            }
            .alert(String(localized: "设置导出密码"), isPresented: $showingExportAlert) {
                SecureField(String(localized: "输入导出密码"), text: $exportPassword)
                    .textContentType(.newPassword)
                SecureField(String(localized: "再次输入导出密码"), text: $exportPasswordConfirmation)
                    .textContentType(.newPassword)
                Button(String(localized: "取消"), role: .cancel) {
                    resetExportInputs()
                }
                Button(String(localized: "开始导出")) {
                    exportCurrentSpace()
                }
            } message: {
                Text(String(localized: "导出文件会使用你输入的密码进行外层加密保护。这可以是你刚刚验证的空间密码，也可以是一个新的密码。"))
            }
            .alert(String(localized: "输入导入密码"), isPresented: $showingImportAlert) {
                SecureField(String(localized: "导入密码"), text: $importPassword)
                    .textContentType(.password)
                Button(String(localized: "取消"), role: .cancel) {
                    resetImportInputs()
                }
                Button(String(localized: "开始恢复")) {
                    importCurrentSpaceBackup()
                }
            } message: {
                Text(String(localized: "请输入生成该备份文件时设置的导出密码。备份内容会恢复到当前空间，并与现有内容合并。"))
            }
            .alert(String(localized: "启用高级数据保护？"), isPresented: $showingAdvancedProtectionAlert) {
                Button(String(localized: "取消"), role: .cancel) {}
                Button(String(localized: "启用"), role: .destructive) {
                    MediaThumbnailService.shared.clearCache()
                    advancedDataProtectionEnabled = true
                }
            } message: {
                Text(String(localized: "启用后，强加密媒体库与强加密相册会使用更严格的内存解密预览链路；普通媒体库的缩略图、封面和点击预览不会受到影响。"))
            }
            .alert(String(localized: "密码错误"), isPresented: $showingAuthenticationFailureAlert) {
                Button(String(localized: "知道了"), role: .cancel) {
                    if authenticationFailureRequiresLock {
                        authenticationFailureRequiresLock = false
                        session.lock(withMessage: authenticationFailureMessage)
                    }
                }
            } message: {
                Text(authenticationFailureMessage)
            }
            .alert(String(localized: "导出密码无效"), isPresented: $showingExportPasswordValidationAlert) {
                Button(String(localized: "知道了"), role: .cancel) {}
            } message: {
                Text(exportPasswordValidationMessage)
            }
            .alert(item: $backupResultAlert) { result in
                if result.shouldTerminateApplication {
                    return Alert(
                        title: Text(result.title),
                        message: Text(result.message),
                        dismissButton: .default(Text(result.dismissTitle)) {
                            requestTerminateApplication()
                        }
                    )
                }

                return Alert(
                    title: Text(result.title),
                    message: Text(result.message),
                    dismissButton: .default(Text(result.dismissTitle))
                )
            }
            .sheet(isPresented: backupOperationSheetBinding, onDismiss: {
                waitingForBackupProgressDismissal = false
                consumePendingBackupPresentation()
            }) {
                backupOperationSheet
            }
            .onAppear {
                consumeBackupRecoveryNoticeIfNeeded()
            }
            .onChange(of: deleteImportedSystemAssetsAfterImport) { oldValue, newValue in
                guard newValue, !oldValue else { return }
                requestPhotoLibraryAccessForImportCleanupIfNeeded()
            }
    }


    private var settingsListContent: some View {
        List {
            Section(String(localized: "会员管理")) {
                HStack {
                    Text(String(localized: "当前状态"))
                    Spacer()
                    Text(subscriptionManager.currentTier.title)
                        .foregroundStyle(subscriptionManager.currentTier.accentColor)
                }

                settingsNavigationRow(String(localized: "会员中心")) {
                    selectedSidebarDestination = .membership
                }
            }

            SettingsPreferencesSectionView(
                appTheme: $appTheme,
                trashRetentionDays: $trashRetentionDays,
                autoLockTimeoutSeconds: $autoLockTimeoutSeconds,
                themeOptions: ThemeOption.allCases,
                trashRetentionOptions: settingsViewModel.trashRetentionOptions,
                autoLockTimeoutOptions: settingsViewModel.autoLockTimeoutOptions,
                autoLockFooterText: autoLockFooterText,
                autoLockTitle: settingsViewModel.autoLockTitle(for:)
            )

            SettingsPrivacySectionView(
                screenPrivacyProtectionEnabled: $screenPrivacyProtectionEnabled,
                deleteImportedSystemAssetsAfterImport: $deleteImportedSystemAssetsAfterImport,
                advancedProtectionBinding: advancedProtectionBinding,
                advancedProtectionEnabled: advancedDataProtectionEnabled,
                canUseAdvancedProtection: subscriptionManager.currentTier == .fullMember,
                advancedProtectionFooterText: advancedProtectionFooterText,
                onOpenPassword: {
                    protectedDestination = .password
                    activeAuthPrompt = .privacy
                },
                onAttemptEnableAdvancedProtection: {
                    selectedSidebarDestination = .membership
                }
            )

            SettingsBackupSectionView(
                exportingVault: exportingVault,
                importingVault: importingVault,
                backupFooterText: backupFooterText,
                onExport: {
                    activeAuthPrompt = .export
                },
                onImport: {
                    showingImportPicker = true
                },
                onOpenBackupFiles: {
                    selectedSidebarDestination = .backupFiles
                }
            )

            Section(String(localized: "关于")) {
                settingsNavigationRow(String(localized: "使用指南")) {
                    selectedSidebarDestination = .guide
                }

                settingsNavigationRow(String(localized: "法律与隐私")) {
                    selectedSidebarDestination = .legal
                }

                settingsNavigationRow(String(localized: "版本信息"), trailingText: AppMetadata.versionDisplay) {
                    selectedSidebarDestination = .about
                }
            }

            if let settingsStatusMessage {
                Section {
                    Text(settingsStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        #endif
    }

    private var settingsPreferencesDetailView: some View {
        List {
            SettingsPreferencesSectionView(
                appTheme: $appTheme,
                trashRetentionDays: $trashRetentionDays,
                autoLockTimeoutSeconds: $autoLockTimeoutSeconds,
                themeOptions: ThemeOption.allCases,
                trashRetentionOptions: settingsViewModel.trashRetentionOptions,
                autoLockTimeoutOptions: settingsViewModel.autoLockTimeoutOptions,
                autoLockFooterText: autoLockFooterText,
                autoLockTitle: settingsViewModel.autoLockTitle(for:)
            )
        }
        #if targetEnvironment(macCatalyst)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        #endif
        .navigationTitle(String(localized: "偏好设置"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func settingsDestinationView(for destination: SettingsSidebarDestination) -> some View {
        switch destination {
        case .membership:
            MembershipCenterView()
        case .preferences:
            settingsPreferencesDetailView
        case .password:
            PasswordSettingsView(settingsViewModel: settingsViewModel, session: session)
        case .backupFiles:
            StoredVaultBackupFilesView()
        case .guide:
            AppInformationView()
        case .legal:
            LegalInformationView()
        case .about:
            AboutAppView()
        }
    }

    // MARK: - Private Helpers

    private func settingsNavigationRow(
        _ title: String,
        trailingText: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .foregroundStyle(.primary)

                Spacer()

                if let trailingText {
                    Text(trailingText)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 验证进入隐私设置
    private func authenticateForPrivacySettings() {
        guard let activeSpace = session.activeSpace else {
            settingsStatusMessage = String(localized: "当前没有已解锁空间。")
            privacyAuthPassword = ""
            protectedDestination = nil
            return
        }

        let result = AppLockService().validate(passcode: privacyAuthPassword, for: activeSpace)
        privacyAuthPassword = ""
        switch result {
        case .success:
            switch protectedDestination {
            case .password:
                selectedSidebarDestination = .password
            case .none:
                break
            }
            protectedDestination = nil
        case let .failure(message):
            settingsStatusMessage = String(localized: "密码错误，应用已锁定。")
            protectedDestination = nil
            authenticationFailureMessage = message
            authenticationFailureRequiresLock = true
            showingAuthenticationFailureAlert = true
        }
    }
    
    /// 验证导出权限
    private func authenticateForExport() {
        guard let activeSpace = session.activeSpace else {
            settingsStatusMessage = String(localized: "当前没有已解锁空间。")
            exportAuthPassword = ""
            return
        }

        let result = AppLockService().validate(passcode: exportAuthPassword, for: activeSpace)
        exportAuthPassword = ""
        switch result {
        case .success:
            resetExportInputs()
            showingExportAlert = true
        case let .failure(message):
            settingsStatusMessage = String(localized: "密码错误，应用已锁定。")
            authenticationFailureMessage = message
            authenticationFailureRequiresLock = true
            showingAuthenticationFailureAlert = true
        }
    }
    
    /// 验证导入权限
    private func authenticateForImport() {
        guard let activeSpace = session.activeSpace else {
            settingsStatusMessage = String(localized: "当前没有已解锁空间。")
            importAuthPassword = ""
            selectedImportURLs = []
            return
        }

        let result = AppLockService().validate(passcode: importAuthPassword, for: activeSpace)
        importAuthPassword = ""
        switch result {
        case .success:
            showingImportAlert = true
        case let .failure(message):
            settingsStatusMessage = String(localized: "密码错误，应用已锁定。")
            selectedImportURLs = []
            authenticationFailureMessage = message
            authenticationFailureRequiresLock = true
            showingAuthenticationFailureAlert = true
        }
    }

    /// 导出当前空间
    private func exportCurrentSpace() {
        let trimmedPassword = exportPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedConfirmation = exportPasswordConfirmation.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPassword.isEmpty, !trimmedConfirmation.isEmpty else {
            exportPasswordValidationMessage = String(localized: "请输入导出密码，并重复输入一次确认。")
            showingExportPasswordValidationAlert = true
            return
        }

        guard trimmedPassword.count >= 4 else {
            exportPasswordValidationMessage = String(localized: "导出密码至少需要 4 位。")
            showingExportPasswordValidationAlert = true
            return
        }

        guard trimmedPassword == trimmedConfirmation else {
            exportPasswordValidationMessage = String(localized: "两次输入的导出密码不一致。")
            showingExportPasswordValidationAlert = true
            return
        }

        exportingVault = true
        settingsStatusMessage = nil
        updateBackupProgress(VaultTransferProgress(phase: .scanning, message: String(localized: "正在准备导出"), fractionCompleted: 0))

        activeBackupTask = Task {
            do {
                let result = try await VaultExportService().exportCurrentSpace(
                    space: settingsViewModel.space,
                    password: trimmedPassword,
                    onProgress: { progress in
                        Task { @MainActor in
                            updateBackupProgress(progress)
                        }
                    }
                )
                await MainActor.run {
                    #if DEBUG
                    VaultTransferLog.mark("export.saved", "fileCount=\(result.fileURLs.count)")
                    #endif
                    updateBackupProgress(VaultTransferProgress(
                        phase: .completed,
                        currentPart: result.fileURLs.count,
                        totalParts: result.fileURLs.count,
                        message: String.localizedStringWithFormat(String(localized: "备份已保存，已生成 %lld 个备份文件。"), result.fileURLs.count),
                        fractionCompleted: 1
                    ))
                    pendingBackupResultAlert = .backupSaved(fileCount: result.fileURLs.count)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        waitingForBackupProgressDismissal = true
                        exportingVault = false
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    pendingBackupResultAlert = .exportStopped
                    waitingForBackupProgressDismissal = true
                    exportingVault = false
                }
            } catch let error as VaultExportError {
                await MainActor.run {
                    switch error {
                    case .cancelled:
                        pendingBackupResultAlert = .exportStopped
                    default:
                        pendingBackupResultAlert = .failure(title: String(localized: "导出失败"), message: error.localizedDescription)
                    }
                    waitingForBackupProgressDismissal = true
                    exportingVault = false
                }
            } catch {
                await MainActor.run {
                    pendingBackupResultAlert = .failure(
                        title: String(localized: "导出失败"),
                        message: String(localized: "备份文件生成失败，请重试。")
                    )
                    waitingForBackupProgressDismissal = true
                    exportingVault = false
                }
            }

            await MainActor.run {
                activeBackupTask = nil
                resetExportInputs()
                consumePendingBackupPresentation()
            }
        }
    }

    /// 重置导出输入
    private func resetExportInputs() {
        exportPassword = ""
        exportPasswordConfirmation = ""
    }

    private func consumePendingBackupPresentation() {
        guard !waitingForBackupProgressDismissal else { return }
        guard !exportingVault, !importingVault else { return }

        if shouldOpenMembershipAfterBackupDismissal {
            shouldOpenMembershipAfterBackupDismissal = false
            DispatchQueue.main.async {
                selectedSidebarDestination = .membership
            }
            return
        }

        if let pendingAlert = pendingBackupResultAlert {
            pendingBackupResultAlert = nil
            DispatchQueue.main.async {
                backupResultAlert = pendingAlert
            }
        }
    }

    /// 导入当前空间备份
    private func importCurrentSpaceBackup() {
        guard !selectedImportURLs.isEmpty else {
            settingsStatusMessage = String(localized: "请先选择备份文件。")
            resetImportInputs()
            return
        }

        importingVault = true
        settingsStatusMessage = nil
        updateBackupProgress(VaultTransferProgress(phase: .reading, message: String(localized: "正在打开备份文件"), fractionCompleted: 0))

        activeBackupTask = Task {
            do {
                let importService = VaultImportService()
                let currentTier = await MainActor.run { subscriptionManager.currentTier }
                if currentTier != .fullMember {
                    let currentMediaCount = await MainActor.run { currentTotalMediaItemCount() }
                    let inspection = try await importService.inspectBackupsForImport(
                        from: selectedImportURLs,
                        password: importPassword,
                        onProgress: { progress in
                            Task { @MainActor in
                                updateBackupProgress(progress)
                            }
                        }
                    )
                    let requestedMediaCount = inspection.mediaItemCount
                    #if DEBUG
                    VaultTransferLog.mark(
                        "import.limit.check",
                        "current=\(currentMediaCount) incoming=\(requestedMediaCount) limit=\(SharedImportConstants.freeMediaLimit)"
                    )
                    #endif
                    if currentMediaCount + requestedMediaCount > SharedImportConstants.freeMediaLimit {
                        await MainActor.run {
                            settingsStatusMessage = String(localized: "当前备份会超过免费版 20 个媒体项目上限，请开通会员后再恢复。")
                            shouldOpenMembershipAfterBackupDismissal = true
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            waitingForBackupProgressDismissal = true
                            importingVault = false
                        }
                        return
                    }
                }

                let result = try await importService.importBackups(
                    from: selectedImportURLs,
                    into: settingsViewModel.space,
                    password: importPassword,
                    onProgress: { progress in
                        Task { @MainActor in
                            updateBackupProgress(progress)
                        }
                    }
                )
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .vaultDidRefreshAfterImport,
                        object: nil,
                        userInfo: ["spaceRawValue": settingsViewModel.space.rawValue]
                    )
                    pendingBackupResultAlert = .importSucceeded(
                        mediaCount: result.importedMediaCount,
                        albumCount: result.importedAlbumCount,
                        strongProtectedMediaCount: result.importedStrongProtectedMediaCount,
                        strongProtectedAlbumCount: result.importedStrongProtectedAlbumCount,
                        regularPhotoCount: result.importedRegularPhotoCount,
                        regularVideoCount: result.importedRegularVideoCount,
                        skippedItemCount: result.skippedItemCount,
                        failedItemCount: result.failedItemCount,
                        requiresMembershipReminder: subscriptionManager.currentTier != .fullMember
                    )
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch is CancellationError {
                await MainActor.run {
                    pendingBackupResultAlert = .importStopped
                }
            } catch let error as VaultImportError {
                await MainActor.run {
                    switch error {
                    case .cancelled:
                        pendingBackupResultAlert = .importStopped
                    default:
                        pendingBackupResultAlert = .failure(title: String(localized: "恢复失败"), message: error.localizedDescription)
                    }
                }
            } catch {
                await MainActor.run {
                    pendingBackupResultAlert = .failure(title: String(localized: "恢复失败"), message: error.localizedDescription)
                }
            }

            await MainActor.run {
                waitingForBackupProgressDismissal = true
                importingVault = false
                activeBackupTask = nil
                resetImportInputs()
                consumePendingBackupPresentation()
            }
        }
    }

    /// 重置导入输入
    private func resetImportInputs() {
        importPassword = ""
        selectedImportURLs = []
    }

    /// 更新备份进度
    private func updateBackupProgress(_ progress: VaultTransferProgress) {
        backupProgressTitle = progress.localizedTitle
        backupProgressDetail = progress.message
        backupProgressValue = progress.fractionCompleted
        backupProgressPart = (progress.currentPart, progress.totalParts)
        backupProgressItem = (progress.currentItem, progress.totalItems)
        backupProgressBytes = (progress.currentBytes, progress.totalBytes)
    }

    private func consumeBackupRecoveryNoticeIfNeeded() {
        guard !lastBackupRecoveryNotice.isEmpty else { return }
        backupResultAlert = .failure(title: String(localized: "备份提示"), message: lastBackupRecoveryNotice)
        lastBackupRecoveryNotice = ""
    }

    private var advancedProtectionBinding: Binding<Bool> {
        Binding(
            get: { advancedDataProtectionEnabled },
            set: { newValue in
                if newValue {
                    guard subscriptionManager.currentTier == .fullMember else {
                        selectedSidebarDestination = .membership
                        return
                    }
                    showingAdvancedProtectionAlert = true
                } else {
                    MediaThumbnailService.shared.clearCache()
                    advancedDataProtectionEnabled = false
                }
            }
        )
    }

    private var currentPromptPasscodeKind: AppPasscodeKind {
        guard let activeSpace = session.activeSpace else {
            return .custom
        }
        return session.configuredPasscodeKind(for: activeSpace) ?? .custom
    }


    private var backupFooterText: String {
        String(localized: "备份功能仅可以备份当前空间，请妥善保存导出的 `.vault` 文件。恢复数据时会把备份合并到当前空间。")
    }

    private func currentTotalMediaItemCount() -> Int {
        let state = SharedImportStore.shared.appState
        return state.spaceACount + state.spaceBCount
    }

    private var autoLockFooterText: String {
        String(localized: "如果开启无操作后锁定，在设定时间内没有交互，应用会自动返回锁定页。")
    }

    private var advancedProtectionFooterText: String {
        String(localized: "开启高级数据保护后，强加密媒体会使用更严格的预览链路；普通媒体库仍会正常显示缩略图和预览。")
    }


    private var backupOperationSheetBinding: Binding<Bool> {
        Binding(
            get: { exportingVault || importingVault },
            set: { _ in }
        )
    }

    private var backupOperationSheet: some View {
        BackupOperationSheetView(
            title: defaultBackupOverlayTitle,
            progressTitle: backupProgressTitle,
            progressDetail: backupProgressDetail,
            progressValue: backupProgressValue,
            currentPart: backupProgressPart.current,
            totalParts: backupProgressPart.total,
            currentItem: backupProgressItem.current,
            totalItems: backupProgressItem.total,
            currentBytes: backupProgressBytes.current,
            totalBytes: backupProgressBytes.total,
            onCancel: {
                activeBackupTask?.cancel()
            }
        )
    }

    private var defaultBackupOverlayTitle: String {
        exportingVault ? String(localized: "正在导出") : String(localized: "正在恢复")
    }

    private func requestTerminateApplication() {
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            exit(0)
        }
    }

    private func requestPhotoLibraryAccessForImportCleanupIfNeeded() {
        Task {
            let status = await SystemPhotoLibraryCleanupService.shared.ensureReadWriteAuthorization()
            await MainActor.run {
                guard deleteImportedSystemAssetsAfterImport else { return }
                if status != .authorized && status != .limited {
                    deleteImportedSystemAssetsAfterImport = false
                    settingsStatusMessage = String(localized: "如果你想在导入后删除系统图库原件，请先允许本应用访问\u{201C}照片\u{201D}。")
                }
            }
        }
    }

    private func binding(for prompt: SettingsAuthPrompt) -> Binding<String> {
        switch prompt {
        case .privacy:
            return $privacyAuthPassword
        case .export:
            return $exportAuthPassword
        case .import:
            return $importAuthPassword
        }
    }

    private func cancelAuthPrompt(_ prompt: SettingsAuthPrompt) {
        switch prompt {
        case .privacy:
            privacyAuthPassword = ""
            protectedDestination = nil
        case .export:
            exportAuthPassword = ""
        case .import:
            importAuthPassword = ""
            selectedImportURLs = []
        }
        activeAuthPrompt = nil
    }

    private func confirmAuthPrompt(_ prompt: SettingsAuthPrompt) {
        activeAuthPrompt = nil
        switch prompt {
        case .privacy:
            authenticateForPrivacySettings()
        case .export:
            authenticateForExport()
        case .import:
            authenticateForImport()
        }
    }
}

// MARK: - 法律与隐私视图 (直接附在文件末尾)
private struct LegalInformationView: View {
    var body: some View {
        List {
            
            Section(String(localized: "隐私与数据安全")) {
                Text(String(localized: "本应用采用本地加密存储机制。除系统生成的预览图外，导入的媒体文件及相关元数据会使用 CryptoKit 提供的 AES-GCM 加密后保存在设备本地。"))
                Text(String(localized: "本应用不设云端服务器，也不会主动上传您的照片、视频或相册数据。加密所需的密钥保存在设备本地的 Keychain 中，开发者无法访问或解密您的本地内容。"))
                Text(String(localized: "您可以随时通过删除 App 清除本地数据；如果启用了胁迫密码，也可以在触发后清空本地保险箱内容。数据删除后通常无法恢复，谨记数据无价。"))
            }
            Section(String(localized: "免责声明")) {
                Text(String(localized: "您须对所有自行导入的素材（包括但不限于图片、视频及相关信息）承担全部连带责任。请务必确保您的使用行为及存储内容符合所在国家或地区的法律法规，并对此承担全部法律责任。"))
                Text(String(localized: "您因存储违规内容而产生的任何法律纠纷、行政处罚或第三方索赔，均由您本人自行承担，开发者不承担任何直接或连带责任。"))
                Text(String(localized: "任何因设备丢失、硬件损坏、系统故障、主动卸载应用、忘记空间密码或触发\u{201C}胁迫密码\u{201D}自毁机制导致的数据遗失，均属于不可逆转的操作。开发者无权也无法提供数据恢复服务，亦不对任何形式的数据损失承担赔偿责任。"))
                Text(String(localized: "请务必定期使用\u{201C}导出备份\u{201D}功能生成加密的 .vault 文件并妥善保存。备份文件的安全性及保存情况由用户自行负责。"))
            }
            Section(String(localized: "正式条款")) {
                Link(String(localized: "隐私政策 (Privacy Policy)"), destination: URL(string: AppMetadata.privacyPolicyURLString)!)
                Link(String(localized: "标准用户协议 (EULA)"), destination: URL(string: AppMetadata.standardEULAURLString)!)
                Text(String(localized: "一旦您下载、安装或开始使用本应用，即视为您已充分阅读、理解并同意接受上述隐私政策与免责声明的所有条款约束。"))
            }
        }
        .navigationTitle(String(localized: "法律与隐私"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
