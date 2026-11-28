import Combine
import SwiftUI
import UIKit

/// 统一收口密码输入草稿，供首次引导、修改密码、第二空间创建和胁迫密码设置复用。
final class PasscodeDraftController: ObservableObject {
    @Published var kind: AppPasscodeKind
    @Published var primaryValue = ""
    @Published var confirmationValue = ""

    init(kind: AppPasscodeKind = .fourDigits) {
        self.kind = kind
    }

    var normalizedPrimaryValue: String {
        kind.normalized(primaryValue)
    }

    var normalizedConfirmationValue: String {
        kind.normalized(confirmationValue)
    }

    func reset(kind: AppPasscodeKind? = nil) {
        if let kind {
            self.kind = kind
        }
        primaryValue = ""
        confirmationValue = ""
    }

    func sanitize() {
        primaryValue = kind.sanitized(primaryValue)
        confirmationValue = kind.sanitized(confirmationValue)
    }
}

/// 使用系统数字键盘的密码输入区。
/// 显示层只保留 iOS 常见的圆点/空心圆，真正的输入由隐藏的 TextField 承担。
/// 首次引导、锁定页、第二空间设置里凡是 4 位/6 位输入，基本都复用它。
struct NativeNumericPasscodeField: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let prompt: String
    @Binding var value: String
    let expectedLength: Int
    var autoFocus: Bool = true
    var shakeTrigger: Int = 0
    var onCompleted: (() -> Void)? = nil

    @State private var focusRequestCount = 0

    var body: some View {
        VStack(spacing: 18) {
            if !title.isEmpty {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
            }

            ZStack {
                HStack(spacing: 14) {
                    ForEach(0..<expectedLength, id: \.self) { index in
                        Circle()
                            .fill(index < value.count ? Color.primary : Color.clear)
                            .frame(width: 14, height: 14)
                            .overlay {
                                Circle()
                                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1.5)
                            }
                    }
                }
                .modifier(PasscodeShakeModifier(trigger: shakeTrigger))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .overlay {
                HiddenNumericTextField(
                    text: $value,
                    expectedLength: expectedLength,
                    isEnabled: isEnabled,
                    focusRequestCount: focusRequestCount
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard isEnabled else { return }
                focusRequestCount += 1
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title.isEmpty ? String(localized: "密码") : title)
            .accessibilityValue(
                String.localizedStringWithFormat(
                    String(localized: "已输入 %lld / %lld 位"),
                    Int64(value.count),
                    Int64(expectedLength)
                )
            )
            .accessibilityHint(isEnabled ? String(localized: "轻点以输入密码") : "")
            .accessibilityAddTraits(isEnabled ? [] : .isStaticText)
            .accessibilityAction {
                guard isEnabled else { return }
                focusRequestCount += 1
            }

            if !prompt.isEmpty {
                Text(prompt)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .onAppear {
            requestFocusIfAllowed()
        }
        .onChange(of: autoFocus) { _, shouldFocus in
            if shouldFocus {
                requestFocusIfAllowed()
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if enabled && autoFocus {
                requestFocusIfAllowed()
            }
        }
        .onChange(of: value) { _, newValue in
            let filtered = AppPasscodeKind.filterASCIIDigits(newValue, maxLength: expectedLength)
            if filtered != value {
                value = filtered
                return
            }

            if isEnabled, filtered.count == expectedLength {
                onCompleted?()
            }
        }
    }

    private func requestFocusIfAllowed() {
        guard autoFocus, isEnabled else { return }
        DispatchQueue.main.async {
            guard autoFocus, isEnabled else { return }
            focusRequestCount += 1
        }
    }
}

private struct HiddenNumericTextField: UIViewRepresentable {
    @Binding var text: String
    let expectedLength: Int
    let isEnabled: Bool
    let focusRequestCount: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, maxLength: expectedLength, isEnabled: isEnabled)
    }

    func makeUIView(context: Context) -> HiddenKeyboardTextField {
        let textField = HiddenKeyboardTextField(frame: .zero)
        textField.keyboardType = .numberPad
        textField.isSecureTextEntry = true
        textField.textContentType = nil
        textField.textColor = .clear
        textField.tintColor = .clear
        textField.backgroundColor = .clear
        textField.borderStyle = .none
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.spellCheckingType = .no
        textField.smartQuotesType = .no
        textField.smartDashesType = .no
        textField.smartInsertDeleteType = .no
        textField.inputAssistantItem.leadingBarButtonGroups = []
        textField.inputAssistantItem.trailingBarButtonGroups = []
        textField.isEnabled = isEnabled
        textField.isAccessibilityElement = false
        textField.delegate = context.coordinator
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
        return textField
    }

    func updateUIView(_ uiView: HiddenKeyboardTextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }

        if uiView.isEnabled != isEnabled {
            uiView.isEnabled = isEnabled
        }

        context.coordinator.text = $text
        context.coordinator.maxLength = expectedLength
        context.coordinator.isEnabled = isEnabled

        if !isEnabled {
            uiView.cancelPendingFocus()
            if uiView.isFirstResponder {
                DispatchQueue.main.async {
                    uiView.resignFirstResponder()
                }
            }
            return
        }

        if context.coordinator.lastFocusRequestCount != focusRequestCount {
            context.coordinator.lastFocusRequestCount = focusRequestCount
            uiView.requestFocus()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var maxLength: Int
        var isEnabled: Bool
        var lastFocusRequestCount = 0

        init(text: Binding<String>, maxLength: Int, isEnabled: Bool) {
            self.text = text
            self.maxLength = maxLength
            self.isEnabled = isEnabled
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            guard isEnabled else { return false }
            if string.isEmpty { return true }

            let filteredReplacement = AppPasscodeKind.filterASCIIDigits(string)
            guard !filteredReplacement.isEmpty else { return false }

            let currentText = textField.text ?? ""
            guard let stringRange = Range(range, in: currentText) else { return false }
            let updatedText = currentText.replacingCharacters(in: stringRange, with: filteredReplacement)

            if filteredReplacement == string {
                return updatedText.count <= maxLength
            }

            let truncated = String(updatedText.prefix(maxLength))
            textField.text = truncated
            text.wrappedValue = truncated
            return false
        }

        @objc
        func textDidChange(_ textField: UITextField) {
            guard isEnabled else {
                textField.text = text.wrappedValue
                return
            }
            let sanitized = AppPasscodeKind.filterASCIIDigits(textField.text ?? "", maxLength: maxLength)
            if textField.text != sanitized {
                textField.text = sanitized
            }
            if text.wrappedValue != sanitized {
                text.wrappedValue = sanitized
            }
        }
    }
}

private final class HiddenKeyboardTextField: UITextField {
    private var pendingFocus = false
    private var pendingFocusGeneration = 0

    override var intrinsicContentSize: CGSize {
        .zero
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        .zero
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, pendingFocus {
            attemptFocusIfPending(generation: pendingFocusGeneration, remainingRetries: 6)
        }
    }

    func requestFocus() {
        pendingFocus = true
        pendingFocusGeneration += 1
        let generation = pendingFocusGeneration
        DispatchQueue.main.async { [weak self] in
            self?.attemptFocusIfPending(generation: generation, remainingRetries: 6)
        }
    }

    func cancelPendingFocus() {
        pendingFocus = false
        pendingFocusGeneration += 1
    }

    private func attemptFocusIfPending(generation: Int, remainingRetries: Int) {
        guard pendingFocus, generation == pendingFocusGeneration else { return }
        guard isEnabled else {
            pendingFocus = false
            return
        }
        guard let window else {
            // Defer until didMoveToWindow() once UIKit attaches this field.
            return
        }
        if isFirstResponder {
            pendingFocus = false
            return
        }

        // Wait for any modal sheet covering this field (e.g., SettingsPasscodePromptView
        // dismissing while locking back to UnlockView) to finish before claiming focus.
        if let coveringVC = coveringPresentedController(in: window) {
            if let coordinator = coveringVC.transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.attemptFocusIfPending(generation: generation, remainingRetries: remainingRetries)
                    }
                }
                return
            }
            if remainingRetries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.attemptFocusIfPending(generation: generation, remainingRetries: remainingRetries - 1)
                }
                return
            }
            pendingFocus = false
            return
        }

        if becomeFirstResponder() {
            pendingFocus = false
            return
        }

        guard remainingRetries > 0 else {
            pendingFocus = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.attemptFocusIfPending(generation: generation, remainingRetries: remainingRetries - 1)
        }
    }

    private func coveringPresentedController(in window: UIWindow) -> UIViewController? {
        var current = window.rootViewController
        while let presented = current?.presentedViewController {
            if !isDescendant(of: presented.view) {
                return presented
            }
            current = presented
        }
        return nil
    }
}

struct AutoFocusSecureField: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    @Binding var text: String
    var textContentType: UITextContentType? = nil
    var autoFocus: Bool = true
    var submitLabel: SubmitLabel = .done
    var shakeTrigger: Int = 0
    var onSubmit: (() -> Void)? = nil

    @FocusState private var isFocused: Bool
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        SecureField(title, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(textContentType)
            .submitLabel(submitLabel)
            .textFieldStyle(.roundedBorder)
            .modifier(PasscodeShakeModifier(trigger: shakeTrigger))
            .focused($isFocused)
            .onSubmit {
                guard isEnabled else { return }
                onSubmit?()
            }
            .onAppear {
                requestFocusIfAllowed()
            }
            .onDisappear {
                focusTask?.cancel()
                focusTask = nil
            }
            .onChange(of: autoFocus) { _, shouldFocus in
                if shouldFocus {
                    requestFocusIfAllowed()
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    focusTask?.cancel()
                    focusTask = nil
                    isFocused = false
                } else if autoFocus {
                    requestFocusIfAllowed()
                }
            }
    }

    private func requestFocusIfAllowed() {
        focusTask?.cancel()
        guard autoFocus, isEnabled else { return }
        focusTask = Task { @MainActor in
            await Task.yield()
            for attempt in 0..<5 {
                guard !Task.isCancelled, autoFocus, isEnabled else { return }
                isFocused = true
                if isFocused || attempt == 4 { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}

private struct PasscodeShakeEffect: GeometryEffect {
    var travelDistance: CGFloat = 10
    var shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = travelDistance * sin(animatableData * .pi * 2 * shakesPerUnit)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

private struct PasscodeShakeModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let trigger: Int
    @State private var shakePhase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .modifier(PasscodeShakeEffect(animatableData: reduceMotion ? 0 : shakePhase))
            .onChange(of: trigger) { _, _ in
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.36)) {
                    shakePhase += 1
                }
            }
    }
}

#Preview("数字密码输入") {
    NativeNumericPasscodeField(
        title: "输入 4 位密码",
        prompt: "输入完成后会自动继续。",
        value: .constant("12"),
        expectedLength: 4,
        autoFocus: false
    )
    .padding()
}
