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
        // NavigationStack 提供整个界面的导航结构，包括顶部的导航栏区域
        NavigationStack {
            // List 提供了原生的分组列表样式（iOS 设置页常见的圆角卡片外观，背景灰色/黑色）
            List {
                // 根据当前所处的流程阶段（stage），切换显示该步骤所需的内容区块
                switch stage {
                case .verifyCurrent:
                    // 阶段 1：验证当前密码的界面
                    verifyCurrentSection
                case .chooseKind:
                    // 阶段 2：选择新密码类型（4位数字、6位数字、复杂密码）的界面
                    chooseKindSection
                case .enterPrimaryNew:
                    // 阶段 3：输入主空间新密码的界面
                    // 修改 title 字符串可改变卡片内部的标题，修改 helper 可改变底部的辅助说明文字
                    newPasscodeSection(
                        title: String(localized: "输入新密码"),
                        helper: "",
                        kind: selectedKind,
                        text: $primaryDraft.primaryValue
                    )
                case .confirmPrimaryNew:
                    // 阶段 4：再次确认主空间新密码的界面
                    confirmPasscodeSection(
                        title: String(localized: "确认新密码"),
                        helper: String(localized: "请再次输入同样的密码。"),
                        kind: selectedKind,
                        text: $primaryDraft.confirmationValue
                    )
                case .verifySecondaryCurrent:
                    // 阶段 5：需要验证第二空间当前密码的界面
                    verifySecondarySection
                case .enterSecondaryNew:
                    // 阶段 6：输入另一个空间新密码的界面
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
                    // 阶段 7：确认另一个空间新密码的界面
                    confirmPasscodeSection(
                        title: String.localizedStringWithFormat(String(localized: "确认%@的密码"), counterpartSpaceName),
                        helper: String(localized: "请再次输入同样的密码。"),
                        kind: selectedKind,
                        text: $secondaryDraft.confirmationValue
                    )
                case .enterPrimaryCoercion:
                    // 阶段 8：设置全局胁迫密码的界面
                    newPasscodeSection(
                        title: String(localized: "修改胁迫密码"),
                        helper: String.localizedStringWithFormat(String(localized: "胁迫密码需要改成同样的密码类型：%@。"), selectedKind.title),
                        kind: selectedKind,
                        text: $coercionDraft.primaryValue
                    )
                case .confirmPrimaryCoercion:
                    // 阶段 9：确认全局胁迫密码的界面
                    confirmPasscodeSection(
                        title: String(localized: "确认胁迫密码"),
                        helper: String(localized: "请再次输入胁迫密码。"),
                        kind: selectedKind,
                        text: $coercionDraft.confirmationValue
                    )
                }

                // 如果出现了错误（比如密码校验失败），在紧接着的下一个 Section 显示红色报错文本
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote.weight(.medium)) // 控制报错字体大小与字重
                            .foregroundStyle(.red) // 显示为红色
                            .frame(maxWidth: .infinity, alignment: .center) // 居中显示
                    }
                    .listRowBackground(Color.clear) // 隐藏红色文字的白色卡片底色
                    // 也可以调整间距：.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
            }
            .listStyle(.insetGrouped) // 告诉系统这个 List 应该使用圆角卡片（Inset Grouped）风格
            .navigationTitle(navigationTitle) // 设置顶部导航栏中央的大标题内容（由底部的 navigationTitle 变量控制）
            .navigationBarTitleDisplayMode(.inline) // 让导航栏标题居中显示，不要变成巨大的左侧标题
            .toolbar {
                // ToolbarItem(placement: .topBarLeading) 定义了导航栏左侧位置的按钮
                ToolbarItem(placement: .topBarLeading) {
                    if canGoBack {
                        // 当能“上一步”时，显示一个向左的箭头图标
                        Button {
                            goBack()
                        } label: {
                            // Image 用于显示 SF Symbols 系统图标，修改 "chevron.left" 字符串可以换成其它图标
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel(String(localized: "上一步")) // 让 VoiceOver 朗读“上一步”
                    } else if canCancel {
                        // 不能上一步但允许“取消”时，显示一个错号图标
                        Button {
                            resetDrafts()
                            dismiss() // 关闭当前页面
                        } label: {
                            // Image 用于显示 SF Symbols 系统图标，修改 "xmark" 字符串可以换成其它图标（如 "chevron.down"）
                            Image(systemName: "xmark")
                                .fontWeight(.medium) // 控制图标粗细
                        }
                        .accessibilityLabel(String(localized: "取消")) // 让 VoiceOver 朗读“取消”，帮助视障用户理解这个图标的用途
                    }
                }
                
                // ToolbarItem(placement: .topBarTrailing) 定义了导航栏右侧位置的按钮
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        handlePrimaryAction() // 点击触发验证、继续、或保存等主要操作
                    }) {
                        // 当处于保存中状态时（由于耗时操作），展示系统默认的菊花加载动画
                        if isSaving {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            // 否则，展示一个“对号”图标代表确认或继续，修改 "checkmark" 可以更换图标
                            Image(systemName: "checkmark")
                        }
                    }
                    // .disabled() 根据布尔值决定按钮是否可以点击：
                    // isSaving (保存时禁用) || primaryActionDisabled (例如密码还没输入或者长度不够时禁用)
                    // 按钮被禁用时，系统会自动把对号变成浅灰色；满足条件时会自动恢复为深蓝色（App 强调色）
                    .disabled(isSaving || primaryActionDisabled)
                    .tint(.blue) // 强制使用蓝色作为激活状态的颜色
                    .keyboardShortcut(.defaultAction)
                    // 无障碍朗读：VoiceOver 依然读出“验证并继续”、“完成”等真正的文字意义，而不是念出“对号”
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
            // 以下 onChange 会监听各种输入值的变化，用于控制合法性检查和清理多余字符
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

    // 控制当前顶部导航栏显示的大标题字符串
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

    // 控制当前右上角按钮（或 VoiceOver）代表的操作语义文字
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

    // 控制当前状态下，右上角的按钮是否应该被禁用（返回 true 则代表满足条件，按钮不可点且为灰色）
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

    // “验证当前密码” 阶段特有的自定义界面
    private var verifyCurrentSection: some View {
        // Section 是 List 里的一个分组（一块白色圆角背景区域）
        Section {
            // VStack 用于纵向排列子视图，spacing: 16 控制内部每一项的上下间距
            VStack(spacing: 16) {
                // 1. 顶部的图示。想要换成其他系统图标，把 "lock.rectangle.stack.fill" 换成对应名称即可。
                Image("custom.wheel")
                    .resizable() // 允许图片改变原始尺寸
                    .scaledToFit() // 保持比例缩放
                    .frame(width: 56, height: 56) // 限制长宽大小
                    .foregroundStyle(.tint) // 颜色跟随当前 App 的强调色（默认是蓝色）
                    .padding(.top, 2) // 让图标距离卡片顶部边缘有一定的距离
                    .accessibilityHidden(true) // 告诉 VoiceOver 忽略这个图示，避免向盲人重复播报无意义的装饰信息

                // 2. 中央大标题。更改双引号内的文字可以修改它
                            Text(String(localized: "输入当前密码"))
                    .font(.title3) // title3 提供一个稍微大一点的默认大小
                    .fontWeight(.bold) // 加粗显示

                // 3. 辅助说明文字。
                Text(String(localized: "输入用于解锁此应用的密码"))
                    .font(.subheadline) // subheadline 比 title3 细一点，小一点
                    .foregroundStyle(.secondary) // 次要文字颜色，通常表现为灰色
                    .multilineTextAlignment(.center) // 如果文字太长被折叠到两行，让它们保持居中对齐
                
                // 4. 输入框区域
                // 如果目前的密码类型是“自定复杂密码”
                if currentKind == .custom {
                    // 使用原生密码输入框，带遮挡圆点
                    SecureField(String(localized: "密码"), text: $currentPasscode)
                        .textContentType(.password) // 提示系统键盘这属于密码，允许密码填充
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder) // 给予输入框一个圆角描边
                        .padding(.horizontal) // 让输入框距离左右两边有留白
                } else {
                    // 否则，使用自定义封装的“纯数字/圆点”密码盘
                    // 此处由于上面已经自定义了说明，所以传递空字符串 title 和 prompt 隐藏组件自带的额外说明
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

    // “选择密码类型” 阶段（如4位、6位）的界面
    private var chooseKindSection: some View {
        // 第一部分：让用户通过 Picker 选择密码类型的卡片
        Section {
            // Picker 会生成单选列表。第一参数 "密码类型" 并不会显示在屏幕上（受 labelsHidden 影响），但对无障碍辅助有用
            Picker(String(localized: "密码类型"), selection: $primaryDraft.kind) {
                // 遍历 AppPasscodeKind 里的所有枚举选项并显示为 Text
                ForEach(AppPasscodeKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.inline) // inline 样式可以在 List 分组卡片里展示可勾选的平铺列表
            .labelsHidden() // 隐藏 Picker 左侧默认的前缀文字

            // 下方根据特定场景提供灰色小字提示
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
            // 卡片头部（此处自定义了一个带有图标和大标题的视图结构）
            VStack(spacing: 16) {
                // 大图标
                Image(systemName: "ellipsis.rectangle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                
                // 大标题文字
                Text(String(localized: "密码类型"))
                    .font(.title3)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, alignment: .center) // 居中显示
            }
            .padding(.vertical, 30) // 上下留白
            .textCase(nil) // 阻止系统将 header 文字强制转换为全大写
        }
    }
        
    // “验证另一个空间密码” 的过渡阶段界面
    private var verifySecondarySection: some View {
        // Group 用于把多个 Section 组合在一个函数里返回，它自己不提供任何排版效果
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

            // 使用通用的密码填写组件
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

    // 辅助函数：用于“输入首次新密码”页面的便捷封装
    @ViewBuilder
    private func newPasscodeSection(
        title: String,
        helper: String,
        kind: AppPasscodeKind,
        text: Binding<String>
    ) -> some View {
        // 调用通用的 passcodeEntrySection，并告诉系统如果是文字密码，键盘行为应该是创建新密码（.newPassword）
        passcodeEntrySection(
            title: title,
            helper: helper,
            kind: kind,
            text: text,
            secureTextType: .newPassword
        )
    }

    // 辅助函数：用于“第二次确认密码”页面的便捷封装
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

    // 真正负责渲染标准密码输入框的通用组件（包含新建密码和确认密码等所有阶段）
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

                // 3. 副标题说明文字（使用传入的参数，如果不为空才显示）
                if !helper.isEmpty {
                    Text(helper)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // 4. 密码输入区域
                if kind == .custom {
                    // 如果是任意字符构成的复杂密码，使用系统 SecureField
                    SecureField(String(localized: "密码"), text: text)
                        .textContentType(secureTextType)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)
                } else {
                    // 如果是纯数字类型，调用纯数字组件
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
