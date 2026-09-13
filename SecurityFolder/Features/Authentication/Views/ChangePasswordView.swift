import SwiftUI

private struct PasswordChangeResultAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let dismissesView: Bool
}

/// 修改密码流程。
/// 这条链路刻意做成和首次设置密码接近的多步流程：
/// 1. 验证当前密码
/// 2. 选择新密码类型
/// 3. 输入新密码
/// 4. 确认新密码
/// 5. 如果当前空间修改了密码类型，再强制补齐另一个空间 / 胁迫密码
///
/// 注意：
/// - 真正的媒体文件不会重加密，只会重新包裹各空间的主密钥。
/// - 如果任一空间修改了密码类型，另一个空间和现有胁迫密码必须依次重设成同一类型。
struct ChangePasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: AppSessionViewModel

    @StateObject private var primaryDraft = PasscodeDraftController()
    @StateObject private var secondaryDraft = PasscodeDraftController()
    @StateObject private var coercionDraft = PasscodeDraftController()

    @State private var stage: Stage = .verifyCurrent
    @State private var currentPasscode = ""
    @State private var secondaryCurrentPasscode = ""
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var resultAlert: PasswordChangeResultAlert?

    init(session: AppSessionViewModel, initialStage: Stage = .verifyCurrent) {
        self.session = session
        self._stage = State(initialValue: initialStage)
    }
    
    enum Stage: Int, CaseIterable {
        case verifyCurrent
        case chooseKind
        case enterPrimaryNew
        case confirmPrimaryNew
        case verifySecondaryCurrent
        case enterSecondaryNew
        case confirmSecondaryNew
        case enterPrimaryCoercion
        case confirmPrimaryCoercion
    }

    var body: some View {
        NavigationStack {
            List {
                switch stage {
                case .verifyCurrent:
                    verifyCurrentSection
                case .chooseKind:
                    chooseKindSection
                case .enterPrimaryNew:
                    newPasscodeSection(
                        title: String(localized: "输入新密码"),
                        helper: "",
                        kind: selectedKind,
                        text: $primaryDraft.primaryValue
                    )
                case .confirmPrimaryNew:
                    confirmPasscodeSection(
                        title: String(localized: "确认新密码"),
                        helper: String(localized: "请再次输入同样的密码。"),
                        kind: selectedKind,
                        text: $primaryDraft.confirmationValue
                    )
                case .verifySecondaryCurrent:
                    verifySecondarySection
                case .enterSecondaryNew:
                    newPasscodeSection(
                        title: String.localizedStringWithFormat(
                            String(localized: "修改%@的密码"),
                            counterpartSpaceName
                        ),
                        helper: String.localizedStringWithFormat(
                            String(localized: "%1$@ 需要改成同样的密码类型：%2$@。"),
                            counterpartSpaceName,
                            selectedKind.title
                        ),
                        kind: selectedKind,
                        text: $secondaryDraft.primaryValue
                    )
                case .confirmSecondaryNew:
                    confirmPasscodeSection(
                        title: String.localizedStringWithFormat(String(localized: "确认%@的密码"), counterpartSpaceName),
                        helper: String(localized: "请再次输入同样的密码。"),
                        kind: selectedKind,
                        text: $secondaryDraft.confirmationValue
                    )
                case .enterPrimaryCoercion:
                    newPasscodeSection(
                        title: String(localized: "修改胁迫密码"),
                        helper: String.localizedStringWithFormat(String(localized: "胁迫密码需要改成同样的密码类型：%@。"), selectedKind.title),
                        kind: selectedKind,
                        text: $coercionDraft.primaryValue
                    )
                case .confirmPrimaryCoercion:
                    confirmPasscodeSection(
                        title: String(localized: "确认胁迫密码"),
                        helper: String(localized: "请再次输入胁迫密码。"),
                        kind: selectedKind,
                        text: $coercionDraft.confirmationValue
                    )
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote.weight(.medium)) // 控制报错字体大小与字重
                            .foregroundStyle(.red) // 显示为红色
                            .frame(maxWidth: .infinity, alignment: .center) // 居中显示
                    }
                    .listRowBackground(Color.clear) // 隐藏红色文字的白色卡片底色
                }
            }
            .listStyle(.insetGrouped) // 告诉系统这个 List 应该使用圆角卡片（Inset Grouped）风格
            .navigationTitle(navigationTitle) // 设置顶部导航栏中央的大标题内容（由底部的 navigationTitle 变量控制）
            .navigationBarTitleDisplayMode(.inline) // 让导航栏标题居中显示，不要变成巨大的左侧标题
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if canGoBack {
                        Button {
                            goBack()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel(String(localized: "上一步")) // 让 VoiceOver 朗读“上一步”
                    } else if canCancel {
                        Button {
                            resetDrafts()
                            dismiss() // 关闭当前页面
                        } label: {
                            Image(systemName: "xmark")
                                .fontWeight(.medium) // 控制图标粗细
                        }
                        .accessibilityLabel(String(localized: "取消")) // 让 VoiceOver 朗读“取消”，帮助视障用户理解这个图标的用途
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        handlePrimaryAction() // 点击触发验证、继续、或保存等主要操作
                    }) {
                        if isSaving {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Image(systemName: "checkmark")
                        }
                    }
                    .disabled(isSaving || primaryActionDisabled)
                    .tint(.blue) // 强制使用蓝色作为激活状态的颜色
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(primaryActionTitle)
                }
            }
            .interactiveDismissDisabled(!canCancel) // 防止在不允许取消时（比如保存中）通过下滑手势关闭页面
            .alert(item: $resultAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text(String(localized: "知道了"))) {
                        if alert.dismissesView {
                            dismiss()
                        }
                    }
                )
            }
            .onAppear {
                resetDrafts()
                primaryDraft.kind = currentKind
            }
            .onChange(of: currentPasscode) { _, newValue in
                sanitizeCurrentPasscode(with: newValue, kind: currentKind, assignToSecondary: false)
            }
            .onChange(of: secondaryCurrentPasscode) { _, newValue in
                sanitizeCurrentPasscode(with: newValue, kind: counterpartKind ?? currentKind, assignToSecondary: true)
            }
            .onChange(of: primaryDraft.kind) { _, _ in
                primaryDraft.sanitize()
                secondaryDraft.kind = primaryDraft.kind
                coercionDraft.kind = primaryDraft.kind
            }
            .onChange(of: primaryDraft.primaryValue) { _, _ in primaryDraft.sanitize() }
            .onChange(of: primaryDraft.confirmationValue) { _, _ in primaryDraft.sanitize() }
            .onChange(of: secondaryDraft.primaryValue) { _, _ in secondaryDraft.sanitize() }
            .onChange(of: secondaryDraft.confirmationValue) { _, _ in secondaryDraft.sanitize() }
            .onChange(of: coercionDraft.primaryValue) { _, _ in coercionDraft.sanitize() }
            .onChange(of: coercionDraft.confirmationValue) { _, _ in coercionDraft.sanitize() }
        }
    }

    private var activeSpace: VaultSpaceKind? {
        session.activeSpace
    }

    private var currentSpace: VaultSpaceKind {
        activeSpace ?? .spaceA
    }

    private var counterpartSpace: VaultSpaceKind {
        currentSpace == .spaceA ? .spaceB : .spaceA
    }

    private var currentSpaceName: String {
        session.displayName(for: currentSpace)
    }

    private var counterpartSpaceName: String {
        session.displayName(for: counterpartSpace)
    }

    private var currentKind: AppPasscodeKind {
        guard let activeSpace else { return .fourDigits }
        return session.configuredPasscodeKind(for: activeSpace) ?? .fourDigits
    }

    private var counterpartKind: AppPasscodeKind? {
        session.configuredPasscodeKind(for: counterpartSpace)
    }

    private var selectedKind: AppPasscodeKind {
        primaryDraft.kind
    }

    private var isChangingKind: Bool {
        selectedKind != currentKind
    }

    private var requiresCounterpartMigration: Bool {
        isChangingKind && session.isPasscodeConfigured(for: counterpartSpace)
    }

    private var requiresCoercionMigration: Bool {
        isChangingKind && session.hasCoercionPasscode(for: .spaceA)
    }

    private var canCancel: Bool {
        !isSaving && stage.rawValue <= Stage.confirmPrimaryNew.rawValue
    }

    private var canGoBack: Bool {
        !isSaving && stage != .verifyCurrent
    }

    private var navigationTitle: String {
        switch stage {
        case .verifyCurrent:
            return String(localized: "验证当前密码")
        case .chooseKind:
            return String(localized: "选择密码类型")
        case .enterPrimaryNew, .confirmPrimaryNew:
            return String(localized: "设置新密码")
        case .verifySecondaryCurrent, .enterSecondaryNew, .confirmSecondaryNew:
            return String.localizedStringWithFormat(String(localized: "更新%@"), counterpartSpaceName)
        case .enterPrimaryCoercion, .confirmPrimaryCoercion:
            return String(localized: "更新胁迫密码")
        }
    }

    private var primaryActionTitle: String {
        switch stage {
        case .verifyCurrent:
            return String(localized: "验证并继续")
        case .chooseKind:
            return String(localized: "继续")
        case .enterPrimaryNew, .enterSecondaryNew, .enterPrimaryCoercion:
            return String(localized: "确认并继续")
        case .confirmPrimaryNew:
            return isChangingKind ? String(localized: "保存并继续") : String(localized: "保存新密码")
        case .verifySecondaryCurrent:
            return String(localized: "验证并继续")
        case .confirmSecondaryNew:
            return String(localized: "保存并继续")
        case .confirmPrimaryCoercion:
            return String(localized: "完成")
        }
    }

    private var primaryActionDisabled: Bool {
        switch stage {
        case .verifyCurrent:
            return currentPasscode.isEmpty
        case .chooseKind:
            return false
        case .enterPrimaryNew:
            return primaryDraft.primaryValue.isEmpty
        case .confirmPrimaryNew:
            return primaryDraft.confirmationValue.isEmpty
        case .verifySecondaryCurrent:
            return secondaryCurrentPasscode.isEmpty
        case .enterSecondaryNew:
            return secondaryDraft.primaryValue.isEmpty
        case .confirmSecondaryNew:
            return secondaryDraft.confirmationValue.isEmpty
        case .enterPrimaryCoercion:
            return coercionDraft.primaryValue.isEmpty
        case .confirmPrimaryCoercion:
            return coercionDraft.confirmationValue.isEmpty
        }
    }

    // MARK: - 局部视图组件 (Subviews)

    private var verifyCurrentSection: some View {
        Section {
            VStack(spacing: 16) {
                Image("custom.wheel")
                    .resizable() // 允许图片改变原始尺寸
                    .scaledToFit() // 保持比例缩放
                    .frame(width: 56, height: 56) // 限制长宽大小
                    .foregroundStyle(.tint) // 颜色跟随当前 App 的强调色（默认是蓝色）
                    .padding(.top, 2) // 让图标距离卡片顶部边缘有一定的距离
                    .accessibilityHidden(true) // 告诉 VoiceOver 忽略这个图示，避免向盲人重复播报无意义的装饰信息

                            Text(String(localized: "输入当前密码"))
                    .font(.title3) // title3 提供一个稍微大一点的默认大小
                    .fontWeight(.bold) // 加粗显示

                Text(String(localized: "输入用于解锁此应用的密码"))
                    .font(.subheadline) // subheadline 比 title3 细一点，小一点
                    .foregroundStyle(.secondary) // 次要文字颜色，通常表现为灰色
                    .multilineTextAlignment(.center) // 如果文字太长被折叠到两行，让它们保持居中对齐
                
                if currentKind == .custom {
                    SecureField(String(localized: "密码"), text: $currentPasscode)
                        .textContentType(.password) // 提示系统键盘这属于密码，允许密码填充
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder) // 给予输入框一个圆角描边
                        .padding(.horizontal) // 让输入框距离左右两边有留白
                } else {
                    NativeNumericPasscodeField(
                        title: "", 
                        prompt: "", 
                        value: $currentPasscode, // 当前的输入值双向绑定
                        expectedLength: expectedLength(for: currentKind), // 期望的长度（4或6）
                        autoFocus: false // 这个页面进来到时候不需要自动弹起键盘
                    )
                    .padding(.vertical, 8) // 上下留出间隙
                }
            }
            .listRowBackground(Color.clear) // 隐藏 List 默认的白色卡片背景，让内容直接显示在灰色底色上
        }
    }

    private var chooseKindSection: some View {
        Section {
            Picker(String(localized: "密码类型"), selection: $primaryDraft.kind) {
                ForEach(AppPasscodeKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.inline) // inline 样式可以在 List 分组卡片里展示可勾选的平铺列表
            .labelsHidden() // 隐藏 Picker 左侧默认的前缀文字

            if isChangingKind && (requiresCounterpartMigration || requiresCoercionMigration) {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "修改%@密码类型后，%@ 和现有胁迫密码也必须依次改成同一类型。"),
                        currentSpaceName,
                        counterpartSpaceName
                    )
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            VStack(spacing: 16) {
                Image(systemName: "ellipsis.rectangle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                
                Text(String(localized: "密码类型"))
                    .font(.title3)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, alignment: .center) // 居中显示
            }
            .padding(.vertical, 30) // 上下留白
            .textCase(nil) // 阻止系统将 header 文字强制转换为全大写
        }
    }
        
    private var verifySecondarySection: some View {
        Group {
            Section {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "%1$@ 密码类型已经更新。下一步需要验证 %2$@ 当前密码，然后把它改成 %3$@。"),
                        currentSpaceName,
                        counterpartSpaceName,
                        selectedKind.title
                    )
                )
                    .foregroundStyle(.secondary) // 灰色文字
            }

            passcodeEntrySection(
                title: String.localizedStringWithFormat(
                    String(localized: "输入%@当前密码"),
                    counterpartSpaceName
                ),
                helper: (counterpartKind ?? selectedKind).helperText(for: counterpartSpaceName),
                kind: counterpartKind ?? selectedKind,
                text: $secondaryCurrentPasscode,
                secureTextType: .password
            )
        }
    }

    @ViewBuilder
    private func newPasscodeSection(
        title: String,
        helper: String,
        kind: AppPasscodeKind,
        text: Binding<String>
    ) -> some View {
        passcodeEntrySection(
            title: title,
            helper: helper,
            kind: kind,
            text: text,
            secureTextType: .newPassword
        )
    }

    @ViewBuilder
    private func confirmPasscodeSection(
        title: String,
        helper: String,
        kind: AppPasscodeKind,
        text: Binding<String>
    ) -> some View {
        passcodeEntrySection(
            title: title,
            helper: helper,
            kind: kind,
            text: text,
            secureTextType: .newPassword
        )
    }

    @ViewBuilder
    private func passcodeEntrySection(
        title: String,
        helper: String, // 底部用来补充说明的小字
        kind: AppPasscodeKind, // 密码类型：4位、6位 或 自定义
        text: Binding<String>, // 和外面哪个变量做双向绑定
        secureTextType: UITextContentType // 系统键盘填充提示
    ) -> some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "key.viewfinder")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.title3)
                    .fontWeight(.bold)

                if !helper.isEmpty {
                    Text(helper)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if kind == .custom {
                    SecureField(String(localized: "密码"), text: text)
                        .textContentType(secureTextType)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
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
            .listRowBackground(Color.clear) // 去除卡片白底
        }
    }

    // MARK: - 业务逻辑和状态变更

    private func handlePrimaryAction() {
        errorMessage = nil

        switch stage {
        case .verifyCurrent:
            verifyCurrentPasscode()
        case .chooseKind:
            continueFromKindSelection()
        case .enterPrimaryNew:
            continuePrimaryNewPasscode()
        case .confirmPrimaryNew:
            savePrimaryPasscode()
        case .verifySecondaryCurrent:
            verifySecondaryPasscode()
        case .enterSecondaryNew:
            continueSecondaryNewPasscode()
        case .confirmSecondaryNew:
            saveSecondaryPasscode()
        case .enterPrimaryCoercion:
            continuePrimaryCoercion()
        case .confirmPrimaryCoercion:
            savePrimaryCoercion()
        }
    }

    private func verifyCurrentPasscode() {
        guard let activeSpace else { return }

        switch session.validatePasscode(currentPasscode, for: activeSpace) {
        case .success:
            stage = .chooseKind
        case let .failure(message):
            clearInputForCurrentStage()
            presentError(message)
        }
    }

    private func continueFromKindSelection() {
        primaryDraft.reset(kind: selectedKind)
        stage = .enterPrimaryNew
    }

    private func continuePrimaryNewPasscode() {
        primaryDraft.sanitize()

        guard selectedKind.isValid(primaryDraft.normalizedPrimaryValue) else {
            clearInputForCurrentStage()
            presentError(String(localized: "密码格式不符合要求。"))
            return
        }

        if primaryDraft.normalizedPrimaryValue == currentPasscode {
            clearInputForCurrentStage()
            presentError(String(localized: "新密码不能与原密码相同。"))
            return
        }

        primaryDraft.confirmationValue = ""
        stage = .confirmPrimaryNew
    }

    private func savePrimaryPasscode() {
        guard activeSpace != nil else { return }
        primaryDraft.sanitize()

        guard primaryDraft.normalizedPrimaryValue == primaryDraft.normalizedConfirmationValue else {
            clearInputForCurrentStage()
            presentError(String(localized: "两次输入的密码不一致。"))
            return
        }

        isSaving = true
        let result = session.changePasscode(
            for: currentSpace,
            currentPasscode: currentPasscode,
            newPasscode: primaryDraft.normalizedPrimaryValue,
            kind: selectedKind,
            allowTemporaryTypeMismatch: isChangingKind
        )
        isSaving = false

        switch result {
        case .success:
            moveToNextMigrationStageAfterPrimarySave()
        case let .failure(message):
            clearInputForCurrentStage()
            presentError(message)
        }
    }

    private func moveToNextMigrationStageAfterPrimarySave() {
        if requiresCounterpartMigration {
            secondaryCurrentPasscode = ""
            secondaryDraft.reset(kind: selectedKind)
            stage = .verifySecondaryCurrent
            return
        }

        if requiresCoercionMigration {
            coercionDraft.reset(kind: selectedKind)
            stage = .enterPrimaryCoercion
            return
        }

        presentSuccessAndDismiss()
    }

    private func verifySecondaryPasscode() {
        switch session.validatePasscode(secondaryCurrentPasscode, for: counterpartSpace) {
        case .success:
            secondaryDraft.reset(kind: selectedKind)
            stage = .enterSecondaryNew
        case let .failure(message):
            clearInputForCurrentStage()
            presentError(message)
        }
    }

    private func continueSecondaryNewPasscode() {
        secondaryDraft.sanitize()

        guard selectedKind.isValid(secondaryDraft.normalizedPrimaryValue) else {
            clearInputForCurrentStage()
            presentError(String(localized: "密码格式不符合要求。"))
            return
        }

        if secondaryDraft.normalizedPrimaryValue == secondaryCurrentPasscode {
            clearInputForCurrentStage()
            presentError(String(localized: "新密码不能与原密码相同。"))
            return
        }

        secondaryDraft.confirmationValue = ""
        stage = .confirmSecondaryNew
    }

    private func saveSecondaryPasscode() {
        secondaryDraft.sanitize()

        guard secondaryDraft.normalizedPrimaryValue == secondaryDraft.normalizedConfirmationValue else {
            clearInputForCurrentStage()
            presentError(String(localized: "两次输入的新密码不一致。"))
            return
        }

        isSaving = true
        let result = session.changePasscode(
            for: counterpartSpace,
            currentPasscode: secondaryCurrentPasscode,
            newPasscode: secondaryDraft.normalizedPrimaryValue,
            kind: selectedKind,
            allowTemporaryTypeMismatch: true
        )
        isSaving = false

        switch result {
        case .success:
            if requiresCoercionMigration {
                coercionDraft.reset(kind: selectedKind)
                stage = .enterPrimaryCoercion
            } else {
                presentSuccessAndDismiss()
            }
        case let .failure(message):
            clearInputForCurrentStage()
            presentError(message)
        }
    }

    private func continuePrimaryCoercion() {
        coercionDraft.sanitize()

        guard selectedKind.isValid(coercionDraft.normalizedPrimaryValue) else {
            clearInputForCurrentStage()
            presentError(String(localized: "密码格式不符合要求。"))
            return
        }

        coercionDraft.confirmationValue = ""
        stage = .confirmPrimaryCoercion
    }

    private func savePrimaryCoercion() {
        coercionDraft.sanitize()

        guard coercionDraft.normalizedPrimaryValue == coercionDraft.normalizedConfirmationValue else {
            clearInputForCurrentStage()
            presentError(String(localized: "两次输入的胁迫密码不一致。"))
            return
        }

        isSaving = true
        let result = session.configureCoercionPasscode(
            coercionDraft.normalizedPrimaryValue,
            kind: selectedKind,
            for: .spaceA,
            allowTemporaryTypeMismatch: true
        )
        isSaving = false

        switch result {
        case .success:
            presentSuccessAndDismiss()
        case let .failure(message):
            clearInputForCurrentStage()
            presentError(message)
        }
    }

    private func goBack() {
        clearInputForCurrentStage()
        errorMessage = nil

        switch stage {
        case .verifyCurrent:
            break
        case .chooseKind:
            stage = .verifyCurrent
        case .enterPrimaryNew:
            stage = .chooseKind
        case .confirmPrimaryNew:
            stage = .enterPrimaryNew
        case .verifySecondaryCurrent:
            stage = .confirmPrimaryNew
        case .enterSecondaryNew:
            stage = .verifySecondaryCurrent
        case .confirmSecondaryNew:
            stage = .enterSecondaryNew
        case .enterPrimaryCoercion:
            stage = requiresCounterpartMigration ? .confirmSecondaryNew : .confirmPrimaryNew
        case .confirmPrimaryCoercion:
            stage = .enterPrimaryCoercion
        }
    }

    private func clearInputForCurrentStage() {
        switch stage {
        case .verifyCurrent:
            currentPasscode = ""
        case .chooseKind:
            break
        case .enterPrimaryNew:
            primaryDraft.primaryValue = ""
        case .confirmPrimaryNew:
            primaryDraft.confirmationValue = ""
        case .verifySecondaryCurrent:
            secondaryCurrentPasscode = ""
        case .enterSecondaryNew:
            secondaryDraft.primaryValue = ""
        case .confirmSecondaryNew:
            secondaryDraft.confirmationValue = ""
        case .enterPrimaryCoercion:
            coercionDraft.primaryValue = ""
        case .confirmPrimaryCoercion:
            coercionDraft.confirmationValue = ""
        }
    }

    private func presentError(_ message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        errorMessage = message
        resultAlert = PasswordChangeResultAlert(
            title: String(localized: "修改失败"),
            message: message,
            dismissesView: false
        )
    }

    private func presentSuccessAndDismiss() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        resultAlert = PasswordChangeResultAlert(
            title: String(localized: "修改成功"),
            message: String(localized: "密码设置已经更新。"),
            dismissesView: true
        )
    }

    private func sanitizeCurrentPasscode(with newValue: String, kind: AppPasscodeKind, assignToSecondary: Bool) {
        let sanitized: String
        switch kind {
        case .fourDigits:
            sanitized = String(newValue.filter(\.isNumber).prefix(4))
        case .sixDigits:
            sanitized = String(newValue.filter(\.isNumber).prefix(6))
        case .custom:
            sanitized = newValue
        }

        if assignToSecondary {
            if secondaryCurrentPasscode != sanitized {
                secondaryCurrentPasscode = sanitized
            }
        } else if currentPasscode != sanitized {
            currentPasscode = sanitized
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

    private func resetDrafts() {
        primaryDraft.reset(kind: currentKind)
        secondaryDraft.reset(kind: currentKind)
        coercionDraft.reset(kind: currentKind)
        currentPasscode = ""
        secondaryCurrentPasscode = ""
        errorMessage = nil
    }

}

#Preview("01. 验证当前密码 (主空间)") {
    ChangePasswordView(session: PreviewSupport.session(), initialStage: .verifyCurrent)
}

#Preview("02. 选择新密码类型") {
    ChangePasswordView(session: PreviewSupport.session(), initialStage: .chooseKind)
}

#Preview("03. 设置新密码 (主空间)") {
    ChangePasswordView(session: PreviewSupport.session(), initialStage: .enterPrimaryNew)
}

#Preview("04. 确认新密码 (主空间)") {
    ChangePasswordView(session: PreviewSupport.session(), initialStage: .confirmPrimaryNew)
}

#Preview("05. 验证当前密码 (第二空间)") {
    ChangePasswordView(session: PreviewSupport.session(), initialStage: .verifySecondaryCurrent)
}

#Preview("06. 设置新密码 (第二空间)") {
    ChangePasswordView(session: PreviewSupport.session(), initialStage: .enterSecondaryNew)
}

#Preview("07. 确认新密码 (第二空间)") {
    ChangePasswordView(session: PreviewSupport.session(), initialStage: .confirmSecondaryNew)
}

#Preview("08. 设置全局胁迫密码") {
    ChangePasswordView(session: PreviewSupport.session(), initialStage: .enterPrimaryCoercion)
}

#Preview("09. 确认全局胁迫密码") {
    ChangePasswordView(session: PreviewSupport.session(), initialStage: .confirmPrimaryCoercion)
}
