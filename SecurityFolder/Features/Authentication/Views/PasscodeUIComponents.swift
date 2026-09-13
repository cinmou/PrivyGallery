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
