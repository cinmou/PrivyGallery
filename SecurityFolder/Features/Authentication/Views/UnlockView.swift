import SwiftUI
import LocalAuthentication

/// 应用未解锁时的总入口。
/// 这个文件同时承载了两套体验：
/// 1. 主空间尚未初始化时的首次引导（欢迎页 -> 隐私政策 -> 选密码类型 -> 设密码 -> Face ID -> 第二空间 -> 完成）
/// 2. 已初始化后的普通锁定页
///
/// 如果你后续要调整首次启动时那几张"卡片"页面，主要就在这个文件里改。
struct UnlockView: View {
    @ObservedObject var session: AppSessionViewModel
    @StateObject private var viewModel = UnlockViewModel()
    @StateObject private var onboardingDraft = PasscodeDraftController()
    @State private var hasAcceptedPrivacyPolicy = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// True on iPad wide layout and macOS — drives more desktop-friendly onboarding sizing.
    private var isWideLayout: Bool {
        AdaptiveLayoutMode.resolve(horizontalSizeClass: horizontalSizeClass).usesWideLayout
    }

    private var onboardingIconSize: CGFloat { isWideLayout ? 46 : 62 }
    private var onboardingSpacing: CGFloat { isWideLayout ? 12 : 16 }

    @AppStorage(AppSettingsKey.autoSubmitNumericPasscode)
    private var autoSubmitNumericPasscode = AppSettingsKey.defaultAutoSubmitNumericPasscode

    @State private var navigationDirection: NavigationDirection = .forward
    @State private var unlockInput = ""
    @State private var isSubmittingUnlock = false
    @State private var isRequestingOnboardingBiometrics = false

    private enum NavigationDirection {
        case forward
        case backward
    }

    var body: some View {
        NavigationStack {
            ZStack {
                stageView
                    .id(viewModel.stage)
                    .transition(stageTransition)
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.9), value: viewModel.stage)
            .onAppear {
                prepareForCurrentSession()
            }
            .onChange(of: session.activeSpace) { _, _ in
                if !session.isUnlocked {
                    prepareForCurrentSession()
                }
            }
            .onChange(of: session.shouldRunPrimaryOnboarding) { _, _ in
                // 设置完主空间密码后 shouldRunPrimaryOnboarding 会变成 false。
                // 如果此时重跑 prepare，会把第 6/7 页直接打断成普通锁定页。
                guard !viewModel.stage.isOnboardingFlow else { return }
                prepareForCurrentSession()
            }
            // 自动 Face ID 只在锁定页、scene 已经 active、并且用户还没开始手动输入时触发。
            // 这里使用 task(id:) 是为了在前后台切换、锁定状态变化、输入状态变化后自动重新评估。
            .task(id: automaticBiometricAttemptTrigger) {
                guard viewModel.stage == .locked,
                      session.isSceneActive,
                      session.canUseBiometrics,
                      session.isBiometricUnlockEnabled,
                      session.canAutomaticallyAttemptBiometricUnlock,
                      !session.requiresPasscodeAfterBiometricFailures,
                      !viewModel.hasAttemptedAutomaticBiometricUnlock,
                      !viewModel.availableSpaces(using: session).isEmpty else {
                    return
                }

                // 热启动时给系统一点恢复时间，避免 scene 刚回到前台就立刻 evaluatePolicy，
                // 导致 Face ID 还没准备好便直接返回失败。
                try? await Task.sleep(nanoseconds: 500_000_000)

                guard !Task.isCancelled,
                      viewModel.stage == .locked,
                      session.isSceneActive,
                      unlockInput.isEmpty,
                      session.canUseBiometrics,
                      session.isBiometricUnlockEnabled,
                      session.canAutomaticallyAttemptBiometricUnlock,
                      !session.requiresPasscodeAfterBiometricFailures,
                      !viewModel.hasAttemptedAutomaticBiometricUnlock,
                      !viewModel.availableSpaces(using: session).isEmpty else {
                    return
                }

                viewModel.hasAttemptedAutomaticBiometricUnlock = true
                session.markAutomaticBiometricUnlockAttempted()
                viewModel.unlockWithBiometrics(using: session, isAutomaticAttempt: true)
            }
            .task(id: viewModel.stage == .onboardingComplete) {
                guard viewModel.stage == .onboardingComplete else { return }
                try? await Task.sleep(nanoseconds: 1_250_000_000)
                viewModel.unlockPrimaryAfterOnboarding(using: session)
            }
            .onChange(of: onboardingDraft.kind) { _, _ in
                onboardingDraft.sanitize()
            }
            .onChange(of: onboardingDraft.primaryValue) { _, _ in
                onboardingDraft.sanitize()
            }
            .onChange(of: onboardingDraft.confirmationValue) { _, _ in
                onboardingDraft.sanitize()
            }
            .onChange(of: unlockInput) { _, newValue in
                switch unlockKind {
                case .fourDigits:
                    unlockInput = String(newValue.filter(\.isNumber).prefix(4))
                case .sixDigits:
                    unlockInput = String(newValue.filter(\.isNumber).prefix(6))
                case .custom:
                    break
                }
            }
            .onChange(of: viewModel.errorMessage) { _, newValue in
                if newValue != nil {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    @ViewBuilder
    private var stageView: some View {
        // 首次引导的每一页和普通锁定页都从这里分发。
        switch viewModel.stage {
        case .onboardingWelcome:
            onboardingWelcomeView
        case .onboardingPrivacy:
            privacyPlaceholderView
        case .onboardingPasscodeType:
            onboardingPasscodeTypeView
        case .onboardingPasscodeEntry:
            onboardingPasscodeEntryView
        case .onboardingPasscodeConfirmation:
            onboardingPasscodeConfirmationView
        case .onboardingBiometrics:
            biometricsView
        case .onboardingSecondSpace:
            secondSpaceIntroductionView
        case .onboardingComplete:
            completionView
        case .locked:
            lockView
        }
    }

    private var stageTransition: AnyTransition {
        switch navigationDirection {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .backward:
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }

    private var onboardingWelcomeView: some View {
        // 首次启动第 1 页：纯欢迎页。
        List {
            Section {
                VStack(spacing: onboardingSpacing) {
                    Image("custom.wheel")
                        .resizable()
                        .scaledToFit()
                        .frame(width: onboardingIconSize, height: onboardingIconSize)
                        .foregroundStyle(.tint)
                        .padding(.top, isWideLayout ? 0 : 2)
                        .accessibilityHidden(true)

                    Text(String(localized: "欢迎使用私影相册"))
                        .font(.title3)
                        .fontWeight(.bold)

                    Text(String(localized: "把照片和视频加密保留在设备本地。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(String(localized: "步骤 1 / 7"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, isWideLayout ? 4 : 8)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color(red: 1, green: 1, blue: 1, opacity: 0))
            }

            Section {
                centeredActionButton(title: String(localized: "下一步")) {
                    advanceOnboarding()
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "欢迎"))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(OnboardingContainerModifier(isWide: isWideLayout))
    }

    private var privacyPlaceholderView: some View {
        // 首次启动第 2 页：隐私政策与同意页。
        List {
            Section {
                VStack(spacing: onboardingSpacing) {
                    Image(systemName: "hand.raised.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: onboardingIconSize, height: onboardingIconSize)
                        .foregroundStyle(.tint)
                        .padding(.top, isWideLayout ? 0 : 2)
                        .accessibilityHidden(true)

                    Text(String(localized: "隐私承诺"))
                        .font(.title3)
                        .fontWeight(.bold)

                    Text(String(localized: "所有文件均加密后存储于本地。应用不提供云端服务，也不会上传任何媒体。所以请妥善保管密码，遗忘密码将导致无法解密数据，开发者也无法协助恢复。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(String(localized: "步骤 2 / 7"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, isWideLayout ? 4 : 8)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(SwiftUI.Color.clear)
            }

            Section {
                if let privacyPolicyURL = URL(string: AppMetadata.privacyPolicyURLString) {
                    Link(String(localized: "查看隐私政策"), destination: privacyPolicyURL)
                }

                Toggle(String(localized: "我已阅读并同意"), isOn: $hasAcceptedPrivacyPolicy)
            }

            Section {
                centeredActionButton(title: String(localized: "我已阅读并知晓")) {
                    advanceOnboarding()
                }
                .disabled(!hasAcceptedPrivacyPolicy)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "隐私"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            onboardingBackToolbar
        }
        .modifier(OnboardingContainerModifier(isWide: isWideLayout))
    }

    private var onboardingPasscodeTypeView: some View {
        // 首次启动第 3 页：选择主空间的密码类型。
        List {
            Section {
                VStack(spacing: onboardingSpacing) {
                    Image(systemName: "ellipsis.rectangle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: onboardingIconSize, height: onboardingIconSize)
                        .foregroundStyle(.tint)
                        .padding(.top, isWideLayout ? 0 : 2)
                        .accessibilityHidden(true)

                    Text(String(localized: "选择密码类型"))
                        .font(.title3)
                        .fontWeight(.bold)

                    Text(String(localized: "选择你想使用的密码类型。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(String(localized: "步骤 3 / 7"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, isWideLayout ? 4 : 8)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(SwiftUI.Color.clear)
            }

            Section {
                Picker(String(localized: "密码类型"), selection: $onboardingDraft.kind) {
                    ForEach(AppPasscodeKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section {
                centeredActionButton(title: String(localized: "下一步")) {
                    performOnboardingStageChange(direction: .forward) {
                        viewModel.continueFromPasscodeType(with: onboardingDraft)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "密码类型"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            onboardingBackToolbar
        }
        .modifier(OnboardingContainerModifier(isWide: isWideLayout))
    }

    private var onboardingPasscodeEntryView: some View {
        // 首次启动第 4 页：第一次输入密码。
        List {
            Section {
                VStack(spacing: onboardingSpacing) {
                    Image(systemName: "key.viewfinder")
                        .resizable()
                        .scaledToFit()
                        .frame(width: onboardingIconSize, height: onboardingIconSize)
                        .foregroundStyle(.tint)
                        .padding(.top, isWideLayout ? 0 : 2)
                        .accessibilityHidden(true)

                    Text(String(localized: "输入密码"))
                        .font(.title3)
                        .fontWeight(.bold)

                    Text(String(localized: "请输入新密码。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if onboardingDraft.kind == .custom {
                        AutoFocusSecureField(
                            title: onboardingDraft.kind.prompt,
                            text: $onboardingDraft.primaryValue,
                            textContentType: .newPassword
                        )
                            .padding(.horizontal)
                    } else {
                        NativeNumericPasscodeField(
                            title: "",
                            prompt: "",
                            value: $onboardingDraft.primaryValue,
                            expectedLength: expectedLength(for: onboardingDraft.kind),
                            autoFocus: true,
                            onCompleted: nil
                        )
                        .padding(.vertical, 8)
                    }
                    
                    Text(String(localized: "步骤 4 / 7"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, isWideLayout ? 4 : 8)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(SwiftUI.Color.clear)
            }

            if let errorMessage = viewModel.errorMessage {
                errorSection(message: errorMessage)
            }

            Section {
                centeredActionButton(title: String(localized: "确认并继续")) {
                    performOnboardingStageChange(direction: .forward) {
                        viewModel.submitPrimaryOnboardingPasscodeEntry(draft: onboardingDraft)
                    }
                }
                .disabled(onboardingDraft.kind == .custom ? onboardingDraft.primaryValue.isEmpty : onboardingDraft.primaryValue.count != expectedLength(for: onboardingDraft.kind))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "设置密码"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            onboardingBackToolbar
        }
        .modifier(OnboardingContainerModifier(isWide: isWideLayout))
    }

    private var onboardingPasscodeConfirmationView: some View {
        // 首次启动第 5 页：确认密码。
        List {
            Section {
                VStack(spacing: onboardingSpacing) {
                    Image(systemName: "key.viewfinder")
                        .resizable()
                        .scaledToFit()
                        .frame(width: onboardingIconSize, height: onboardingIconSize)
                        .foregroundStyle(.tint)
                        .padding(.top, isWideLayout ? 0 : 2)
                        .accessibilityHidden(true)

                    Text(String(localized: "确认密码"))
                        .font(.title3)
                        .fontWeight(.bold)

                    Text(String(localized: "请再次输入密码。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    if onboardingDraft.kind == .custom {
                        AutoFocusSecureField(
                            title: onboardingDraft.kind.confirmationPrompt,
                            text: $onboardingDraft.confirmationValue,
                            textContentType: .newPassword
                        )
                            .padding(.horizontal)
                    } else {
                        NativeNumericPasscodeField(
                            title: "",
                            prompt: "",
                            value: $onboardingDraft.confirmationValue,
                            expectedLength: expectedLength(for: onboardingDraft.kind),
                            autoFocus: true,
                            onCompleted: nil
                        )
                        .padding(.vertical, 8)
                    }
                    
                    Text(String(localized: "步骤 5 / 7"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, isWideLayout ? 4 : 8)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(SwiftUI.Color.clear)
            }

            if let errorMessage = viewModel.errorMessage {
                errorSection(message: errorMessage)
            }

            Section {
                centeredActionButton(title: String(localized: "完成设置")) {
                    performOnboardingStageChange(direction: .forward) {
                        viewModel.submitPrimaryOnboardingPasscode(draft: onboardingDraft, using: session)
                    }
                }
                .disabled(onboardingDraft.kind == .custom ? onboardingDraft.confirmationValue.isEmpty : onboardingDraft.confirmationValue.count != expectedLength(for: onboardingDraft.kind))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "确认密码"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            onboardingBackToolbar
        }
        .modifier(OnboardingContainerModifier(isWide: isWideLayout))
    }

    private var biometricsView: some View {
        // 首次启动第 6 页：先解释生物识别用途；只有用户点"使用"才请求系统权限。
        List {
            Section {
                VStack(spacing: onboardingSpacing) {
                    Image(systemName: biometricIconName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: onboardingIconSize, height: onboardingIconSize)
                        .foregroundStyle(.tint)
                        .padding(.top, isWideLayout ? 0 : 2)
                        .accessibilityHidden(true)

                    Text(String.localizedStringWithFormat(String(localized: "%@ 解锁"), biometricDisplayName))
                        .font(.title3)
                        .fontWeight(.bold)

                    Text(session.canUseBiometrics
                         ? String.localizedStringWithFormat(String(localized: "%@ 可用于快速解锁应用，你仍然可以随时使用密码解锁。"), biometricDisplayName)
                         : String(localized: "当前设备暂不支持生物识别，请跳过。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(String(localized: "步骤 6 / 7"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, isWideLayout ? 4 : 8)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            if let errorMessage = viewModel.errorMessage {
                errorSection(message: errorMessage)
            }

            Section {
                centeredActionButton(
                    title: isRequestingOnboardingBiometrics
                        ? String(localized: "验证中")
                        : String.localizedStringWithFormat(String(localized: "使用 %@"), biometricDisplayName)
                ) {
                    requestOnboardingBiometrics()
                }
                .disabled(!session.canUseBiometrics || isRequestingOnboardingBiometrics)
                .alignmentGuide(.listRowSeparatorLeading) { _ in
                    0
                }

                centeredActionButton(title: String(localized: "跳过")) {
                    performOnboardingStageChange(direction: .forward) {
                        viewModel.finishBiometricOnboarding(enabled: false, using: session)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(biometricDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            onboardingBackToolbar
        }
        .modifier(OnboardingContainerModifier(isWide: isWideLayout))
    }

    private var secondSpaceIntroductionView: some View {
        // 首次启动第 7 页：只说明第二空间，不在这里强制创建。
        List {
            Section {
                VStack(spacing: onboardingSpacing) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: onboardingIconSize, height: onboardingIconSize)
                        .foregroundStyle(.tint)
                        .padding(.top, isWideLayout ? 0 : 2)
                        .accessibilityHidden(true)

                    Text(String(localized: "第二空间"))
                        .font(.title3)
                        .fontWeight(.bold)

                    Text(String.localizedStringWithFormat(String(localized: "第二空间是一个独立的空间。可以在\u{201C}设置 / 密码与空间\u{201D}中创建，可以根据需要切换 %@ 默认解锁的空间。"), biometricDisplayName))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(String(localized: "步骤 7 / 7"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, isWideLayout ? 4 : 8)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            if let errorMessage = viewModel.errorMessage {
                errorSection(message: errorMessage)
            }

            Section {
                centeredActionButton(title: String(localized: "确认")) {
                    performOnboardingStageChange(direction: .forward) {
                        viewModel.finishOnboarding(using: session)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "第二空间"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            onboardingBackToolbar
        }
        .modifier(OnboardingContainerModifier(isWide: isWideLayout))
    }

    private var completionView: some View {
        // 首次启动完成页。短暂停留后会自动进入已解锁态。
        List {
            Section {
                VStack(spacing: onboardingSpacing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: isWideLayout ? 52 : 64, weight: .semibold))
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: viewModel.stage)
                        .frame(maxWidth: .infinity)

                    Text(String(localized: "欢迎"))
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.vertical, isWideLayout ? 18 : 24)
            }
            .listRowBackground(SwiftUI.Color.clear)
        }
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(OnboardingContainerModifier(isWide: isWideLayout))
    }

    private var lockView: some View {
        // 普通锁定页：根据当前密码类型选择数字圆点输入或复杂密码输入。
        LockScreenContent(
            canUseBiometrics: session.canUseBiometrics,
            biometricEnabled: session.isBiometricUnlockEnabled,
            biometricDisplayName: biometricDisplayName,
            requiresPasscodeAfterBiometricFailures: session.requiresPasscodeAfterBiometricFailures,
            unlockKind: unlockKind,
            unlockInput: $unlockInput,
            autoSubmitNumericPasscode: autoSubmitNumericPasscode,
            isSubmittingUnlock: isSubmittingUnlock,
            errorMessage: viewModel.errorMessage,
            expectedLength: expectedLength(for: unlockKind),
            onBiometricUnlock: { viewModel.unlockWithBiometrics(using: session) },
            onUnlock: submitUnlock
        )
    }

    private func centeredActionButton(title: String, action: @escaping () -> Void) -> some View {
        // On wide layouts cap the tappable area at a desktop-friendly width instead
        // of stretching a button across the entire list row.
        Button(title, action: action)
            .frame(maxWidth: isWideLayout ? 400 : .infinity, alignment: .center)
            .frame(maxWidth: .infinity)
            .keyboardShortcut(.defaultAction)
    }

    private func errorSection(message: String) -> some View {
        Section {
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .listRowBackground(SwiftUI.Color.clear)
    }

    @ToolbarContentBuilder
    private var onboardingBackToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(String(localized: "上一步")) {
                performOnboardingStageChange(direction: .backward) {
                    viewModel.retreatOnboarding()
                }
            }
        }
    }
    
    private var unlockKind: AppPasscodeKind {
        viewModel.preferredUnlockKind(using: session)
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

    private func prepareForCurrentSession() {
        // 每次回到未解锁态时，重新根据 session 判断：
        // 是进入首次引导，还是进入普通锁定页。
        navigationDirection = .forward
        viewModel.prepare(using: session)
        unlockInput = ""
        isSubmittingUnlock = false

        if session.shouldRunPrimaryOnboarding {
            onboardingDraft.reset(kind: .fourDigits)
            viewModel.errorMessage = nil
            hasAcceptedPrivacyPolicy = false
        } else {
            viewModel.errorMessage = session.consumePendingUnlockMessage()
        }
    }

    private func submitUnlock() {
        // 普通锁定页的密码提交流程。
        guard !isSubmittingUnlock else { return }
        isSubmittingUnlock = true
        viewModel.submitUnlock(passcode: unlockInput, using: session)
        isSubmittingUnlock = false

        if session.isUnlocked {
            unlockInput = ""
        }
    }

    private func advanceOnboarding() {
        performOnboardingStageChange(direction: .forward) {
            viewModel.advanceOnboarding()
        }
    }

    private func requestOnboardingBiometrics() {
        guard !isRequestingOnboardingBiometrics else { return }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            viewModel.errorMessage = String.localizedStringWithFormat(String(localized: "%@ 验证失败，请继续使用密码解锁"), biometricDisplayName)
            return
        }

        isRequestingOnboardingBiometrics = true
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: String.localizedStringWithFormat(String(localized: "使用 %@ 解锁你的私密空间"), biometricDisplayName)
        ) { success, _ in
            Task { @MainActor in
                isRequestingOnboardingBiometrics = false
                if success {
                    performOnboardingStageChange(direction: .forward) {
                        viewModel.finishBiometricOnboarding(enabled: true, using: session)
                    }
                } else {
                    session.setBiometricUnlockEnabled(false)
                    viewModel.onboardingBiometricsEnabled = false
                    viewModel.errorMessage = String.localizedStringWithFormat(String(localized: "%@ 验证失败，请继续使用密码解锁"), biometricDisplayName)
                }
            }
        }
    }

    private func performOnboardingStageChange(
        direction: NavigationDirection,
        action: () -> Void
    ) {
        navigationDirection = direction
        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) {
            action()
        }
    }

    private var automaticBiometricAttemptTrigger: String {
        // 把会影响"是否应该自动唤起 Face ID"的条件都压进一个 task id 里，
        // 这样条件变化时 SwiftUI 会自动取消旧任务并重新评估。
        [
            String(describing: viewModel.stage),
            session.isSceneActive ? "active" : "inactive",
            session.canAutomaticallyAttemptBiometricUnlock ? "auto" : "manual",
            session.requiresPasscodeAfterBiometricFailures ? "passcodeOnly" : "biometricOK",
            unlockInput.isEmpty ? "idle" : "typing"
        ].joined(separator: "|")
    }

    private var biometricDisplayName: String {
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

    private var biometricIconName: String {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        switch context.biometryType {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        case .opticID:
            return "opticid"
        default:
            return session.canUseBiometrics ? "person.badge.key.fill" : "lock.slash.fill"
        }
    }
}


// MARK: - Onboarding layout helper

/// On wide layouts (iPad regular size class, macOS), wraps the onboarding
/// page List inside a constrained, centered container so it doesn't appear as
/// a phone-like narrow card inside a large window. On compact layouts it is a
/// no-op and the List fills its parent unchanged.
private struct OnboardingContainerModifier: ViewModifier {
    let isWide: Bool

    func body(content: Content) -> some View {
        if isWide {
            ZStack {
                // Fill the full window area with the same colour the
                // insetGrouped List uses as its background.
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                // The list itself is capped at a desktop-comfortable width
                // and centered inside the full-width ZStack.
                content
                    .frame(maxWidth: 620)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
        }
    }
}

/// 普通锁定页内容。
/// 如果你想改"解锁"这一页的文案、布局、按钮或错误提示，主要就在这里动。
private struct LockScreenContent: View {
    let canUseBiometrics: Bool
    let biometricEnabled: Bool
    let biometricDisplayName: String
    let requiresPasscodeAfterBiometricFailures: Bool
    let unlockKind: AppPasscodeKind
    @Binding var unlockInput: String
    let autoSubmitNumericPasscode: Bool
    let isSubmittingUnlock: Bool
    let errorMessage: String?
    let expectedLength: Int
    let onBiometricUnlock: () -> Void
    let onUnlock: () -> Void

    @State private var iconRotation: Double = 0
    @State private var isAnimatingUnlock = false

    private let unlockIconAnimationDuration: Double = 0.3

    var body: some View {
        List {
            headerSection

            if let errorMessage {
                errorSection(message: errorMessage)
            }

            actionSection
        }

        .listStyle(.insetGrouped)

    }

    private var headerSection: some View {
        Section {
            VStack(spacing: 16) {
                Image("custom.wheel")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 62, height: 62)
                    .foregroundStyle(.tint)
                    .rotationEffect(.degrees(iconRotation))
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                Text(String(localized: "应用已锁定"))
                    .font(.title3)
                    .fontWeight(.bold)

                Text(canUseBiometrics && biometricEnabled && !requiresPasscodeAfterBiometricFailures
                     ? String.localizedStringWithFormat(String(localized: "输入密码，或使用 %@ 解锁"), biometricDisplayName)
                     : String(localized: "输入密码以解锁应用"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if unlockKind == .custom {
                    AutoFocusSecureField(
                        title: String(localized: "输入密码"),
                        text: $unlockInput,
                        textContentType: .password
                    )
                    .padding(.horizontal)
                } else {
                    NativeNumericPasscodeField(
                        title: "",
                        prompt: "",
                        value: $unlockInput,
                        expectedLength: expectedLength,
                        autoFocus: true,
                        onCompleted: autoSubmitNumericPasscode ? { performUnlockWithIconAnimation() } : nil
                    )
                    .padding(.vertical, 8)
                    
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(SwiftUI.Color.clear)
        }
    }

    private func errorSection(message: String) -> some View {
        Section {
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var actionSection: some View {
        Section {
            if canUseBiometrics && biometricEnabled && !requiresPasscodeAfterBiometricFailures {
                Button(String.localizedStringWithFormat(String(localized: "使用 %@ 解锁"), biometricDisplayName)) {
                    performUnlockWithIconAnimation(action: onBiometricUnlock)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .disabled(isAnimatingUnlock || isSubmittingUnlock)
                .alignmentGuide(.listRowSeparatorLeading) { _ in
                    return 0 // 强制分割线从 0（最左侧）开始
                }
            }

            if unlockKind == .custom || !autoSubmitNumericPasscode {
                Button(String(localized: "解锁")) {
                    performUnlockWithIconAnimation()
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .disabled(unlockInput.isEmpty || isSubmittingUnlock || isAnimatingUnlock)
                .keyboardShortcut(.defaultAction)
                .alignmentGuide(.listRowSeparatorLeading) { _ in
                    return 0 // 强制分割线从 0（最左侧）开始
                }
            }
        }
    }

    private func performUnlockWithIconAnimation() {
        performUnlockWithIconAnimation(action: onUnlock)
    }

    private func performUnlockWithIconAnimation(action: @escaping () -> Void) {
        guard !isAnimatingUnlock else { return }
        isAnimatingUnlock = true

        withAnimation(.linear(duration: unlockIconAnimationDuration)) {
            iconRotation += 360
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(unlockIconAnimationDuration * 1_000_000_000))
            action()
            isAnimatingUnlock = false
        }
    }
}

// MARK: - Previews

#Preview("普通锁定页") {
    UnlockView(session: PreviewSupport.session())
}


#Preview("引导 - 欢迎页") {
    struct OnboardingWrapper: View {
        @StateObject private var session = AppSessionViewModel()
        
        var body: some View {
            UnlockView(session: session)
                .onAppear {
                    session.clearAllState()
                }
        }
    }
    return OnboardingWrapper()
}
