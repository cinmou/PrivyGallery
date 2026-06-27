import Foundation

/// 支持的密码形态。数字密码会使用更直接的键盘和长度限制。
enum AppPasscodeKind: String, CaseIterable, Identifiable {
    case fourDigits
    case sixDigits
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fourDigits: String(localized: "四位数字")
        case .sixDigits: String(localized: "六位数字")
        case .custom: String(localized: "复杂密码")
        }
    }

    var prompt: String {
        switch self {
        case .fourDigits: String(localized: "输入 4 位数字密码")
        case .sixDigits: String(localized: "输入 6 位数字密码")
        case .custom: String(localized: "输入复杂密码")
        }
    }

    var confirmationPrompt: String {
        switch self {
        case .fourDigits: String(localized: "再次输入 4 位数字密码")
        case .sixDigits: String(localized: "再次输入 6 位数字密码")
        case .custom: String(localized: "再次输入复杂密码")
        }
    }

    func normalized(_ value: String) -> String {
        switch self {
        case .fourDigits, .sixDigits:
            return value.filter(\.isNumber)
        case .custom:
            return value
        }
    }

    func isValid(_ value: String) -> Bool {
        let normalizedValue = normalized(value)
        switch self {
        case .fourDigits:
            return normalizedValue.count == 4
        case .sixDigits:
            return normalizedValue.count == 6
        case .custom:
            return normalizedValue.count > 6 && normalizedValue.contains(where: \.isLetter)
        }
    }

    func helperText(for space: VaultSpaceKind) -> String {
        helperText(for: space.title)
    }

    func helperText(for displayName: String) -> String {
        switch self {
        case .fourDigits:
            return String.localizedStringWithFormat(String(localized: "%@ 使用 4 位数字密码。"), displayName)
        case .sixDigits:
            return String.localizedStringWithFormat(String(localized: "%@ 使用 6 位数字密码。"), displayName)
        case .custom:
            return String.localizedStringWithFormat(String(localized: "%@ 使用大于 6 位且至少包含 1 个字母的复杂密码。"), displayName)
        }
    }
}
