import SwiftUI
import LocalAuthentication

struct PrivacySecuritySettingsView: View {
    @ObservedObject var settingsViewModel: SettingsViewModel
    @ObservedObject var session: AppSessionViewModel

    var body: some View {
        PasswordSettingsView(settingsViewModel: settingsViewModel, session: session)
    }
}

private struct SpaceNameEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var primarySpaceName: String
    @Binding var secondarySpaceName: String

    let onSave: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    TextField(String(localized: "主要空间名称"), text: $primarySpaceName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.next)

                    TextField(String(localized: "第二空间名称"), text: $secondarySpaceName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                }
                .padding(20)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.top, 24)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(String(localized: "编辑空间名称"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .fontWeight(.medium)
                }
                    .accessibilityLabel(String(localized: "取消"))
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onSave()
                    dismiss()
                } label: {
                    Image(systemName: "checkmark")
                }
                .tint(.blue)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(String(localized: "保存空间名称"))
            }
        }
    }
}

struct PasswordSettingsView: View {
    @ObservedObject var settingsViewModel: SettingsViewModel
    @ObservedObject var session: AppSessionViewModel
    @AppStorage(AppSettingsKey.autoSubmitNumericPasscode)
    private var autoSubmitNumericPasscode = AppSettingsKey.defaultAutoSubmitNumericPasscode
    @State private var biometricSettings = BiometricUnlockSettings.load()
    @State private var savingSensitiveSettings = false
    @State private var primarySpaceName = ""
    @State private var secondarySpaceName = ""
    @State private var completionAlert: SettingsCompletionAlert?
    @State private var showingChangePassword = false
    @State private var showingCoercionSetup = false
    @State private var showingRemoveCoercionAlert = false
    @State private var showingDirectSecondSpaceSetup = false
    @State private var showingSpaceNameEditor = false

    var body: some View {
        // “设置 -> 隐私与安全 -> 密码”子页。
        // 这里承接修改密码、自动提交数字密码、胁迫密码三类与密码直接相关的设置。
        List {
            Section {
                Button(String(localized: "修改密码")) {
                    showingChangePassword = true
                }

                Toggle(String(localized: "数字密码输入完成后自动解锁"), isOn: $autoSubmitNumericPasscode)
            } header: {
                Text(String(localized: "密码管理"))
            }

            if session.isPasscodeConfigured(for: .spaceB) {
                Section {
                    LabeledContent(String(localized: "主要空间")) {
                        Text(session.displayName(for: .spaceA))
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent(String(localized: "第二空间")) {
                        Text(session.displayName(for: .spaceB))
                            .foregroundStyle(.secondary)
                    }

                    Button(String(localized: "编辑空间名称")) {
                        reloadSpaceSettingsState()
                        showingSpaceNameEditor = true
                    }
                } header: {
                    Text(String(localized: "空间管理"))
                } footer: {
                    Text(String.localizedStringWithFormat(String(localized: "当前空间：%@"), session.displayName(for: currentSpace)))
                }
            } else {
                Section {
                    Button(String(localized: "设置第二空间")) {
                        showingDirectSecondSpaceSetup = true
                    }
                } header: {
                    Text(String(localized: "第二空间"))
                } footer: {
                    Text(String(localized: "第二空间会拥有独立密码、独立密钥和独立媒体数据。"))
                }
            }

            Section {
                Toggle(String.localizedStringWithFormat(String(localized: "允许 %@ 解锁"), currentBiometricDisplayName()), isOn: biometricEnabledBinding)
                    .disabled(savingSensitiveSettings || !session.canUseBiometrics)

                if session.isBiometricUnlockEnabled {
                    Picker(String.localizedStringWithFormat(String(localized: "%@ 模式"), currentBiometricDisplayName()), selection: $biometricSettings.mode) {
                        ForEach(BiometricUnlockMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    if biometricSettings.mode == .manual {
                        Picker(String(localized: "默认解锁空间"), selection: $biometricSettings.manualSpace) {
                            ForEach(availableSpaces) { space in
                                Text(session.displayName(for: space)).tag(space)
                            }
                        }
                    } else {
                        Picker(String(localized: "时段内解锁空间"), selection: $biometricSettings.scheduledPrimarySpace) {
                            ForEach(availableSpaces) { space in
                                Text(session.displayName(for: space)).tag(space)
                            }
                        }

                        DatePicker(String(localized: "开始时间"), selection: scheduleStartBinding, displayedComponents: .hourAndMinute)
                        DatePicker(String(localized: "结束时间"), selection: scheduleEndBinding, displayedComponents: .hourAndMinute)
                    }

                    Button(savingSensitiveSettings ? String(localized: "正在验证...") : String.localizedStringWithFormat(String(localized: "验证身份并保存 %@ 设置"), currentBiometricDisplayName())) {
                        saveBiometricSettings()
                    }
                    .disabled(savingSensitiveSettings)
                }
            } header: {
                Text(currentBiometricDisplayName())
            } footer: {
                Text(String.localizedStringWithFormat(String(localized: "使用 %@ 解锁你的私密空间。%@ 仅用于本机身份验证，我们不会访问或保存你的生物识别数据。"), currentBiometricDisplayName(), currentBiometricDisplayName()))
            }

            Section {
                Button(session.hasCoercionPasscode(for: .spaceA) ? String(localized: "修改胁迫密码") : String(localized: "设置胁迫密码")) {
                    showingCoercionSetup = true
                }

                if session.hasCoercionPasscode(for: .spaceA) {
                    Button(String(localized: "关闭胁迫密码"), role: .destructive) {
                        showingRemoveCoercionAlert = true
                    }
                }
            } header: {
                Text(String(localized: "胁迫密码"))
            } footer: {
                Text(String(localized: "胁迫密码是全局唯一的。当你被迫解锁应用时，输入这个预设密码，系统会立即触发并抹除所有数据，请谨慎使用。"))
            }
        }
        .listStyle(.insetGrouped)
        .toggleStyle(.switch)
        .navigationTitle(String(localized: "密码与空间"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            reloadSpaceSettingsState()
        }
        .sheet(isPresented: $showingDirectSecondSpaceSetup) {
            NavigationStack {
                SecondSpaceSetupView(session: session) {
                    showingDirectSecondSpaceSetup = false
                    reloadSpaceSettingsState()
                    completionAlert = SettingsCompletionAlert(message: String(localized: "第二空间创建完成"))
                }
            }
        }
        .fullScreenCover(isPresented: $showingSpaceNameEditor) {
            NavigationStack {
                SpaceNameEditorView(
                    primarySpaceName: $primarySpaceName,
                    secondarySpaceName: $secondarySpaceName
                ) {
                    session.updateDisplayName(primarySpaceName, for: .spaceA)
                    session.updateDisplayName(secondarySpaceName, for: .spaceB)
                    reloadSpaceSettingsState()
                    completionAlert = SettingsCompletionAlert(message: String(localized: "空间名称已更新"))
                }
            }
        }
        .sheet(isPresented: $showingChangePassword) {
            ChangePasswordView(session: session)
        }
        .sheet(isPresented: $showingCoercionSetup) {
            CoercionPasscodeSetupView(session: session) {
                showingCoercionSetup = false
                completionAlert = SettingsCompletionAlert(message: String(localized: "胁迫密码创建完成"))
            }
        }
        .alert(String(localized: "关闭胁迫密码？"), isPresented: $showingRemoveCoercionAlert) {
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "关闭"), role: .destructive) {
                session.removeCoercionPasscode(for: .spaceA)
                completionAlert = SettingsCompletionAlert(message: String(localized: "胁迫密码已关闭"))
            }
        } message: {
            Text(String(localized: "关闭后，输入胁迫密码将不再触发自动清空。"))
        }
        .alert(item: $completionAlert) { alert in
            Alert(title: Text(alert.message), dismissButton: .default(Text(String(localized: "知道了"))))
        }
    }

    private var availableSpaces: [VaultSpaceKind] {
        VaultSpaceKind.allCases.filter { session.isPasscodeConfigured(for: $0) }
    }

    private var currentSpace: VaultSpaceKind {
        session.activeSpace ?? .spaceA
    }

    private var biometricEnabledBinding: Binding<Bool> {
        Binding(
            get: { session.isBiometricUnlockEnabled },
            set: { newValue in
                if newValue {
                    requestEnableBiometricUnlock()
                } else {
                    session.setBiometricUnlockEnabled(false)
                    reloadSpaceSettingsState()
                    completionAlert = SettingsCompletionAlert(message: String.localizedStringWithFormat(String(localized: "%@ 解锁未开启"), currentBiometricDisplayName()))
                }
            }
        )
    }

    private var scheduleStartBinding: Binding<Date> {
        Binding(
            get: { dateFromMinutes(biometricSettings.scheduleStartMinutes) },
            set: { biometricSettings = BiometricUnlockSettings(
                mode: biometricSettings.mode,
                manualSpace: biometricSettings.manualSpace,
                scheduledPrimarySpace: biometricSettings.scheduledPrimarySpace,
                scheduleStartMinutes: minutesFromDate($0),
                scheduleEndMinutes: biometricSettings.scheduleEndMinutes
            ) }
        )
    }

    private var scheduleEndBinding: Binding<Date> {
        Binding(
            get: { dateFromMinutes(biometricSettings.scheduleEndMinutes) },
            set: { biometricSettings = BiometricUnlockSettings(
                mode: biometricSettings.mode,
                manualSpace: biometricSettings.manualSpace,
                scheduledPrimarySpace: biometricSettings.scheduledPrimarySpace,
                scheduleStartMinutes: biometricSettings.scheduleStartMinutes,
                scheduleEndMinutes: minutesFromDate($0)
            ) }
        )
    }

    private func reloadSpaceSettingsState() {
        biometricSettings = adjustedBiometricSettings(BiometricUnlockSettings.load())
        primarySpaceName = session.displayName(for: .spaceA)
        secondarySpaceName = session.displayName(for: .spaceB)
    }

    private func saveBiometricSettings() {
        savingSensitiveSettings = true

        settingsViewModel.authenticateForSensitiveSettings(reason: String.localizedStringWithFormat(String(localized: "修改 %@ 解锁设置"), currentBiometricDisplayName())) { success in
            savingSensitiveSettings = false
            if success {
                let adjusted = adjustedBiometricSettings(biometricSettings)
                biometricSettings = adjusted
                adjusted.save()
                completionAlert = SettingsCompletionAlert(message: String.localizedStringWithFormat(String(localized: "%@ 设置已更新"), currentBiometricDisplayName()))
            } else {
                biometricSettings = adjustedBiometricSettings(BiometricUnlockSettings.load())
                completionAlert = SettingsCompletionAlert(message: String(localized: "身份验证未通过，设置没有变更。"))
            }
        }
    }

    private func requestEnableBiometricUnlock() {
        savingSensitiveSettings = true
        requestFaceIDUnlockPermission(reason: String.localizedStringWithFormat(String(localized: "使用 %@ 解锁你的私密空间"), currentBiometricDisplayName())) { success in
            savingSensitiveSettings = false
            session.setBiometricUnlockEnabled(success)
            reloadSpaceSettingsState()
            if success {
                completionAlert = SettingsCompletionAlert(message: String.localizedStringWithFormat(String(localized: "%@ 解锁已开启"), currentBiometricDisplayName()))
            } else {
                completionAlert = SettingsCompletionAlert(message: String.localizedStringWithFormat(String(localized: "%@ 验证失败，请继续使用密码解锁"), currentBiometricDisplayName()))
            }
        }
    }

    private func adjustedBiometricSettings(_ settings: BiometricUnlockSettings) -> BiometricUnlockSettings {
        guard availableSpaces.contains(.spaceB) else {
            return BiometricUnlockSettings(
                mode: settings.mode,
                manualSpace: .spaceA,
                scheduledPrimarySpace: .spaceA,
                scheduleStartMinutes: settings.scheduleStartMinutes,
                scheduleEndMinutes: settings.scheduleEndMinutes
            )
        }
        return settings
    }

    private func dateFromMinutes(_ minutes: Int) -> Date {
        var components = DateComponents()
        components.hour = (minutes / 60) % 24
        components.minute = minutes % 60
        return Calendar.current.date(from: components) ?? .now
    }

    private func minutesFromDate(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

private struct SettingsCompletionAlert: Identifiable {
    let id = UUID()
    let message: String
}

private func currentBiometricDisplayName() -> String {
    let context = LAContext()
    var error: NSError?
    _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

    switch context.biometryType {
    case .faceID:
        return String(localized: "Face ID")
    case .touchID:
        return String(localized: "Touch ID")
    case .opticID:
        return String(localized: "Optic ID")
    default:
        return String(localized: "生物识别")
    }
}

private func requestFaceIDUnlockPermission(
    reason: String,
    completion: @escaping @MainActor (Bool) -> Void
) {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
        Task { @MainActor in
            completion(false)
        }
        return
    }

    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
        Task { @MainActor in
            completion(success)
        }
    }
}

/// 第二空间初始化流程。
/// 如果空间 B 还没有密码，设置页会把用户带到这里完成创建。
/// 它和首次引导类似，但密码类型固定跟随主空间，不再允许用户选择。
private struct SecondSpaceSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: AppSessionViewModel
    @StateObject private var draft = PasscodeDraftController()

    let onCreated: () -> Void

    @State private var stage: Stage = .introduction
    @State private var errorMessage: String?

    private enum Stage {
        case introduction
        case passcodeEntry
        case passcodeConfirmation
    }

    var body: some View {
        NavigationStack {
            List {
                // 这个 switch 控制“说明 -> 第一次输入 -> 确认输入”三步流程。
                switch stage {
                case .introduction:
                    Section {
                        Text(session.displayName(for: .spaceB))
                            .font(.title3)
                            .fontWeight(.bold)
                            .listRowSeparator(.hidden)
                        Text(String(localized: "第二空间适合需要两套媒体库的用户。它会拥有自己的密码以及自己的媒体库。"))
                            .foregroundStyle(.secondary)
                    }
                    .listStyle(.plain)

                    Section {
                        Button(String(localized: "继续")) {
                            draft.reset(kind: resolvedKind)
                            errorMessage = nil
                            stage = .passcodeEntry
                        }
                    }
                case .passcodeEntry:

                    passcodeSection(
                        title: String.localizedStringWithFormat(
                            String(localized: "设置%@密码"),
                            session.displayName(for: .spaceB)
                        ),
                        text: $draft.primaryValue,
                        kind: resolvedKind,
                        prompt: resolvedKind == .custom
                            ? String(localized: "请使用大于 6 位且至少包含 1 个字母的密码。")
                            : String.localizedStringWithFormat(
                                String(localized: "%1$@的密码类型需要和%2$@保持一致。"),
                                session.displayName(for: .spaceB),
                                session.displayName(for: .spaceA)
                            )
                    )

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .listRowBackground(Color.clear)
                    }

                case .passcodeConfirmation:
                    passcodeSection(
                        title: String(localized: "确认密码"),
                        text: $draft.confirmationValue,
                        kind: resolvedKind,
                        prompt: resolvedKind == .custom
                            ? String(localized: "请再次输入密码。")
                            : String.localizedStringWithFormat(
                                String(localized: "输入完成后点击右上角创建%@。"),
                                session.displayName(for: .spaceB)
                            )
                    )

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(stage == .introduction ? String.localizedStringWithFormat(String(localized: "设置%@"), session.displayName(for: .spaceB)) : String(localized: "设置密码"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if stage == .introduction {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .fontWeight(.medium)
                        }
                        .accessibilityLabel(String(localized: "取消"))
                    } else {
                        Button {
                            goBack()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel(String(localized: "上一步"))
                    }
                }

                if stage != .introduction {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if stage == .passcodeEntry {
                                continueToConfirmation()
                            } else {
                                create()
                            }
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .disabled(primaryActionDisabled)
                        .tint(.blue)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel(stage == .passcodeEntry ? "确认并继续" : "创建\(session.displayName(for: .spaceB))")
                    }
                }
            }
            .onChange(of: draft.primaryValue) { _, _ in
                draft.sanitize()
            }
            .onChange(of: draft.confirmationValue) { _, _ in
                draft.sanitize()
            }
            .onAppear {
                draft.reset(kind: resolvedKind)
            }
        }
    }

    private var primaryActionDisabled: Bool {
        if stage == .passcodeEntry {
            return draft.primaryValue.isEmpty
        } else if stage == .passcodeConfirmation {
            return draft.confirmationValue.isEmpty
        }
        return false
    }

    private var resolvedKind: AppPasscodeKind {
        session.configuredPasscodeKind(for: .spaceA) ?? .fourDigits
    }

    private func expectedLength(for kind: AppPasscodeKind) -> Int {
        switch kind {
        case .fourDigits:
            return 4
        case .sixDigits:
            return 6
        case .custom:
            return 8
        }
    }

    private func create() {
        draft.sanitize()

        guard draft.normalizedPrimaryValue == draft.normalizedConfirmationValue else {
            errorMessage = String(localized: "两次输入的密码不一致。")
            return
        }

        switch session.createSpacePasscode(for: .spaceB, passcode: draft.normalizedPrimaryValue, kind: resolvedKind) {
        case .success:
            onCreated()
            dismiss()
        case let .failure(message):
            errorMessage = message
        }
    }

    private func continueToConfirmation() {
        draft.sanitize()

        guard resolvedKind.isValid(draft.normalizedPrimaryValue) else {
            errorMessage = String(localized: "密码格式不符合要求。")
            return
        }

        errorMessage = nil
        draft.confirmationValue = ""
        stage = .passcodeConfirmation
    }

    private func goBack() {
        errorMessage = nil
        switch stage {
        case .introduction:
            break
        case .passcodeEntry:
            stage = .introduction
        case .passcodeConfirmation:
            stage = .passcodeEntry
        }
    }

    @ViewBuilder
    private func passcodeSection(
        title: String,
        text: Binding<String>,
        kind: AppPasscodeKind,
        prompt: String
    ) -> some View {
        Section {
            VStack(spacing: 16) {
                // 1. 图标
                Image(systemName: "key.viewfinder")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                // 2. 标题（使用传入的参数）
                Text(title)
                    .font(.title3)
                    .fontWeight(.bold)

                // 3. 副标题说明文字
                Text(prompt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                // 4. 密码输入区域
                if kind == .custom {
                    AutoFocusSecureField(
                        title: String(localized: "密码"),
                        text: text,
                        textContentType: .newPassword
                    )
                        .padding(.horizontal)
                } else {
                    NativeNumericPasscodeField(
                        title: "",
                        prompt: "",
                        value: text,
                        expectedLength: expectedLength(for: kind),
                        autoFocus: false
                    )
                    .padding(.vertical, 8)
                }
            }
            .listRowBackground(Color.clear)
        }
    }
}

private struct CoercionPasscodeSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: AppSessionViewModel
    @StateObject private var draft = PasscodeDraftController()

    let onSaved: (() -> Void)?
    @State var stage: Stage = .warningOne
    @State private var remainingSeconds: Int = 10
    @State private var progressTask: Task<Void, Never>?
    @State private var errorMessage: String?

    enum Stage {
        case warningOne
        case warningTwo
        case passcodeEntry
        case passcodeConfirmation
    }

    var body: some View {
        NavigationStack {
            List {
                switch stage {
                case .warningOne:
                    warningSection(
                        title: String(localized: "风险提示"),
                        message: String(localized: "胁迫密码不会解锁您的相册，相反，只要输入正确，应用就会立即清空所有数据并让退出。此过程中会丢失所有的数据，谨记数据无价。"),
                        buttonTitle: String(localized: "我已理解")
                    ) {
                        stage = .warningTwo
                    }
                case .warningTwo:
                    warningSection(
                        title: String(localized: "风险提示"),
                        message: String(localized: "胁迫密码一旦触发，所有本地媒体、空间密码和设置都会被抹除。请定时做好备份工作，被抹除的数据无法恢复。"),
                        buttonTitle: String(localized: "我已完全知晓")
                    ) {
                        stage = .passcodeEntry
                    }
                case .passcodeEntry:
                    passcodeSection(
                        title: String(localized: "设置胁迫密码"),
                        message: String(localized: "胁迫密码类型必须和两个空间保持一致，而且不能和任何一个空间的解锁密码相同。"),
                        text: $draft.primaryValue,
                        kind: resolvedKind,
                        secureTextType: .newPassword
                    )
                    errorSection
                case .passcodeConfirmation:
                    passcodeSection(
                        title: String(localized: "确认胁迫密码"),
                        message: String(localized: "请再次输入胁迫密码。"),
                        text: $draft.confirmationValue,
                        kind: resolvedKind,
                        secureTextType: .newPassword
                    )
                    errorSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(stage == .warningOne || stage == .warningTwo ? String(localized: "风险确认") : String(localized: "设置胁迫密码"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if stage == .warningTwo {
                            stage = .warningOne
                        } else if stage == .passcodeEntry {
                            stage = .warningTwo
                            draft.primaryValue = ""
                            errorMessage = nil
                        } else if stage == .passcodeConfirmation {
                            stage = .passcodeEntry
                            draft.confirmationValue = ""
                            errorMessage = nil
                        } else {
                            dismiss()
                        }
                    } label: {
                        if stage == .warningOne {
                            Image(systemName: "xmark")
                                .fontWeight(.medium)
                        } else {
                            Image(systemName: "chevron.left")
                        }
                    }
                    .accessibilityLabel(stage == .warningOne ? String(localized: "取消") : String(localized: "上一步"))
                }
                if stage == .passcodeEntry || stage == .passcodeConfirmation {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if stage == .passcodeEntry {
                                continueToConfirmation()
                            } else {
                                saveCoercionPasscode()
                            }
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .disabled(primaryActionDisabled)
                        .tint(.blue)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel(stage == .passcodeEntry ? String(localized: "确认并继续") : String(localized: "保存胁迫密码"))
                    }
                }
            }
            .onAppear {
                startConsentCountdown()
                draft.reset(kind: resolvedKind)
            }
            .onChange(of: stage) { _, _ in
                if stage == .warningOne || stage == .warningTwo {
                    startConsentCountdown()
                } else {
                    progressTask?.cancel()
                }
            }
            .onChange(of: draft.primaryValue) { _, _ in
                draft.sanitize()
            }
            .onChange(of: draft.confirmationValue) { _, _ in
                draft.sanitize()
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let errorMessage {
            Section {
                Text(errorMessage)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func warningSection(
        title: String,
        message: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                Text(
                    remainingSeconds > 0
                    ? String.localizedStringWithFormat(String(localized: "请阅读 %lld 秒"), Int64(remainingSeconds))
                    : String(localized: "已阅读完成")
                )
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            
            Button(action: action) {
                Text(buttonTitle)
                    // 使用 .infinity 宽度以及 center 对齐来保证整个按钮居中
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .disabled(remainingSeconds > 0)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var resolvedKind: AppPasscodeKind {
        session.configuredPasscodeKind(for: .spaceA) ?? .fourDigits
    }

    private var primaryActionDisabled: Bool {
        switch stage {
        case .warningOne, .warningTwo:
            return false
        case .passcodeEntry:
            return resolvedKind == .custom ? draft.primaryValue.isEmpty : draft.primaryValue.count != expectedLength(for: resolvedKind)
        case .passcodeConfirmation:
            return resolvedKind == .custom ? draft.confirmationValue.isEmpty : draft.confirmationValue.count != expectedLength(for: resolvedKind)
        }
    }

    private func expectedLength(for kind: AppPasscodeKind) -> Int {
        switch kind {
        case .fourDigits:
            return 4
        case .sixDigits:
            return 6
        case .custom:
            return 8
        }
    }

    private func startConsentCountdown() {
        progressTask?.cancel()
        remainingSeconds = 10

        progressTask = Task {
            for step in (0..<10).reversed() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !Task.isCancelled {
                    await MainActor.run {
                        remainingSeconds = step
                    }
                }
            }
        }
    }

    private func continueToConfirmation() {
        draft.sanitize()

        guard resolvedKind.isValid(draft.normalizedPrimaryValue) else {
            presentError(String(localized: "密码格式错误。"))
            return
        }

        errorMessage = nil
        draft.confirmationValue = ""
        stage = .passcodeConfirmation
    }

    private func saveCoercionPasscode() {
        draft.sanitize()

        guard draft.normalizedPrimaryValue == draft.normalizedConfirmationValue else {
            presentError(String(localized: "两次输入的密码不一致。"))
            return
        }

        switch session.configureCoercionPasscode(draft.normalizedPrimaryValue, kind: resolvedKind, for: .spaceA) {
        case .success:
            onSaved?()
            dismiss()
        case let .failure(message):
            presentError(message)
        }
    }

    @ViewBuilder
    private func passcodeSection(
        title: String,
        message: String,
        text: Binding<String>,
        kind: AppPasscodeKind,
        secureTextType: UITextContentType
    ) -> some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.shield")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 62, height: 62)
                    .foregroundStyle(.red)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.title3)
                    .fontWeight(.bold)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if kind == .custom {
                    AutoFocusSecureField(
                        title: String(localized: "密码"),
                        text: text,
                        textContentType: secureTextType
                    )
                        .padding(.horizontal)
                } else {
                    NativeNumericPasscodeField(
                        title: "",
                        prompt: "",
                        value: text,
                        expectedLength: expectedLength(for: kind),
                        autoFocus: true,
                        onCompleted: nil
                    )
                    .padding(.vertical, 8)
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    private func presentError(_ message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        errorMessage = message
    }
}

#Preview("风险确认1") {
    CoercionPasscodeSetupView(session: PreviewSupport.session(), onSaved: nil, stage: .warningOne)
}

#Preview("风险确认2") {
    CoercionPasscodeSetupView(session: PreviewSupport.session(), onSaved: nil, stage: .warningTwo)
}

#Preview("设置胁迫密码") {
    CoercionPasscodeSetupView(session: PreviewSupport.session(), onSaved: nil, stage: .passcodeEntry)
}

#Preview("密码设置") {
    NavigationStack {
        PasswordSettingsView(
            settingsViewModel: PreviewSupport.settingsViewModel(),
            session: PreviewSupport.session()
        )
    }
}

#Preview("空间设置") {
    NavigationStack {
        PrivacySecuritySettingsView(
            settingsViewModel: PreviewSupport.settingsViewModel(),
            session: PreviewSupport.session()
        )
    }
}
