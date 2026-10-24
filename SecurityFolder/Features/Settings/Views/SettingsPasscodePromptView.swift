import SwiftUI

/// 设置页里所有“进入敏感功能前先验证一次密码”的统一弹层。
/// 它会根据当前空间的密码类型，自动切换为数字圆点输入或复杂密码输入。
struct SettingsPasscodePromptView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let message: String
    let kind: AppPasscodeKind
    @Binding var passcode: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "hand.raised.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 62, height: 62)
                        .foregroundStyle(.tint)
                        .padding(.top, 2)
                        .accessibilityHidden(true)

                    Text(String(localized: "输入当前密码"))
                        .font(.title3)
                        .fontWeight(.bold)

                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if kind == .custom {
                        AutoFocusSecureField(
                            title: "",
                            text: $passcode,
                            textContentType: .password
                        )
                        .padding(.horizontal)
                    } else {
                        NativeNumericPasscodeField(
                            title: "",
                            prompt: "",
                            value: $passcode,
                            expectedLength: expectedLength(for: kind),
                            autoFocus: true,
                            onCompleted: nil
                        )
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 42)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(SettingsAppearance.pageBackground.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                        onCancel()
                    } label: {
                        #if targetEnvironment(macCatalyst)
                        Text(String(localized: "取消"))
                        #else
                        Image(systemName: "xmark")
                            .fontWeight(.medium)
                        #endif
                    }
                    .accessibilityLabel(String(localized: "取消"))
                    #if targetEnvironment(macCatalyst)
                    .keyboardShortcut(.cancelAction)
                    #endif
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                        onConfirm()
                    } label: {
                        #if targetEnvironment(macCatalyst)
                        Text(String(localized: "验证并继续"))
                        #else
                        Image(systemName: "checkmark")
                        #endif
                    }
                    .disabled(isConfirmDisabled)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(String(localized: "验证并继续"))
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 400)
        #endif
    }

    private var isConfirmDisabled: Bool {
        kind == .custom ? passcode.isEmpty : passcode.count != expectedLength(for: kind)
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
}

#if DEBUG
#Preview {
    SettingsPasscodePromptView(
        title: "验证权限",
        message: "为了确保数据安全，请验证当前空间的密码。",
        kind: .fourDigits,
        passcode: .constant("12"),
        onCancel: {},
        onConfirm: {}
    )
}
#endif
