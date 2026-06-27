import Combine
import SwiftUI
import UIKit

/// 统一收口密码输入草稿，供首次引导、修改密码、第二空间创建和胁迫密码设置复用。
/// 如果你后续要改“第一次输入”和“确认输入”的状态流转，优先看这个对象。
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

    func appendDigit(_ digit: String, toConfirmation: Bool) {
        guard digit.allSatisfy(\.isNumber) else { return }

        switch kind {
        case .fourDigits, .sixDigits:
            let maximumLength = kind == .fourDigits ? 4 : 6
            if toConfirmation {
                guard confirmationValue.count < maximumLength else { return }
                confirmationValue.append(digit)
            } else {
                guard primaryValue.count < maximumLength else { return }
                primaryValue.append(digit)
            }
        case .custom:
            break
        }
    }

    func deleteLastDigit(fromConfirmation: Bool) {
        if fromConfirmation {
            guard !confirmationValue.isEmpty else { return }
            confirmationValue.removeLast()
        } else {
            guard !primaryValue.isEmpty else { return }
            primaryValue.removeLast()
        }
    }

    func sanitize() {
        primaryValue = kind.normalized(primaryValue)
        confirmationValue = kind.normalized(confirmationValue)

        switch kind {
        case .fourDigits:
            primaryValue = String(primaryValue.prefix(4))
            confirmationValue = String(confirmationValue.prefix(4))
        case .sixDigits:
            primaryValue = String(primaryValue.prefix(6))
            confirmationValue = String(confirmationValue.prefix(6))
        case .custom:
            break
        }
    }
}

struct AuthenticationBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(.systemGroupedBackground),
                    Color(.secondarySystemGroupedBackground),
                    Color(.systemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: 220, height: 220)
                .blur(radius: 32)
                .offset(x: -140, y: -240)

            Circle()
                .fill(Color.teal.opacity(0.12))
                .frame(width: 200, height: 200)
                .blur(radius: 30)
                .offset(x: 150, y: 250)
        }
        .ignoresSafeArea()
    }
}

/// 认证类页面的统一卡片容器，避免多个流程各自维护一套样式。
/// 当前应用大多数界面已经回归原生 List，这个组件主要作为历史保留。
struct AuthenticationCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(28)
            .frame(maxWidth: 540)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.06), radius: 24, x: 0, y: 14)
            .padding(.horizontal, 24)
    }
}

struct AuthenticationPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }
}

/// 使用系统数字键盘的密码输入区。
/// 显示层只保留 iOS 常见的圆点/空心圆，真正的输入由隐藏的 TextField 承担。
/// 首次引导、锁定页、第二空间设置里凡是 4 位/6 位输入，基本都复用它。
struct NativeNumericPasscodeField: View {
    let title: String
    let prompt: String
    @Binding var value: String
    let expectedLength: Int
    var autoFocus: Bool = true
    var onCompleted: (() -> Void)? = nil

    @State private var focusRequestID = UUID()

    var body: some View {
        VStack(spacing: 18) {
            // 只有当 title 不为空时才渲染，避免产生多余的间距
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
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)

            }
            .overlay {
                HiddenNumericTextField(
                    text: $value,
                    focusRequestID: focusRequestID
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                focusRequestID = UUID()
            }

            // 只有当 prompt 不为空时才渲染，避免产生多余的间距
            if !prompt.isEmpty {
                Text(prompt)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .onAppear {
            guard autoFocus else { return }
            DispatchQueue.main.async {
                focusRequestID = UUID()
            }
        }
        .onChange(of: value) { _, newValue in
            let filtered = String(newValue.filter(\.isNumber).prefix(expectedLength))
            if filtered != value {
                value = filtered
                return
            }

            if filtered.count == expectedLength {
                onCompleted?()
            }
        }
    }
}

private struct HiddenNumericTextField: UIViewRepresentable {
    @Binding var text: String
    let focusRequestID: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = HiddenKeyboardTextField(frame: .zero)
        textField.keyboardType = .numberPad
        textField.textContentType = .password
        textField.isSecureTextEntry = true
        textField.textColor = .clear
        textField.tintColor = .clear
        textField.backgroundColor = .clear
        textField.borderStyle = .none
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.spellCheckingType = .no
        textField.isAccessibilityElement = false
        textField.delegate = context.coordinator
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }

        context.coordinator.text = $text

        if context.coordinator.lastFocusRequestID != focusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                guard uiView.window != nil else { return }
                if !uiView.isFirstResponder {
                    uiView.becomeFirstResponder()
                }
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var lastFocusRequestID: UUID?

        init(text: Binding<String>) {
            self.text = text
        }

        @objc
        func textDidChange(_ textField: UITextField) {
            text.wrappedValue = textField.text ?? ""
        }
    }
}

private final class HiddenKeyboardTextField: UITextField {
    override var intrinsicContentSize: CGSize {
        .zero
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        .zero
    }
}

struct AutoFocusSecureField: View {
    let title: String
    @Binding var text: String
    var textContentType: UITextContentType
    var autoFocus: Bool = true

    @FocusState private var isFocused: Bool

    var body: some View {
        SecureField(title, text: $text)
            .textContentType(textContentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onAppear {
                guard autoFocus else { return }
                DispatchQueue.main.async {
                    isFocused = true
                }
            }
    }
}

/// 数字密码专用圆点输入区，用来替代普通文本框。
/// 它主要服务于“修改密码”“胁迫密码”这种一个页面里要切换多个数字输入目标的场景。
struct NumericPasscodeIndicatorRow: View {
    let title: String
    let value: String
    let expectedLength: Int
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 14) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                HStack(spacing: 12) {
                    ForEach(0..<expectedLength, id: \.self) { index in
                        Circle()
                            .fill(index < value.count ? Color.primary : Color.secondary.opacity(0.22))
                            .frame(width: 14, height: 14)
                            .overlay {
                                Circle()
                                    .stroke(isActive ? Color.accentColor.opacity(0.9) : Color.clear, lineWidth: 6)
                                    .blur(radius: isActive ? 0 : 2)
                                    .opacity(isActive ? 0.15 : 0)
                            }
                    }
                }
            }
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.08) : Color(.tertiarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
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

#Preview("数字密码指示器") {
    VStack(spacing: 16) {
        NumericPasscodeIndicatorRow(
            title: "输入新密码",
            value: "1234",
            expectedLength: 4,
            isActive: true,
            onTap: {}
        )

        NumericPasscodeIndicatorRow(
            title: "确认新密码",
            value: "12",
            expectedLength: 4,
            isActive: false,
            onTap: {}
        )
    }
    .padding()
}

/// 数字密码专用键盘，避免系统键盘打散居中的认证布局。
/// 当前主要用于修改密码页和胁迫密码页。
struct NumericKeypadView: View {
    let onDigit: (String) -> Void
    let onDelete: () -> Void

    private let rows = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["", "0", "delete.left.fill"]
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(row, id: \.self) { item in
                        keypadButton(for: item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keypadButton(for item: String) -> some View {
        if item.isEmpty {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 58)
        } else if item == "delete.left.fill" {
            Button(action: onDelete) {
                Image(systemName: item)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        } else {
            Button(action: { onDigit(item) }) {
                Text(item)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }
}
