import Foundation
import SwiftUI

/// 应用主题外观选项
enum ThemeOption: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    /// 在设置中显示的标题
    var title: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .light: String(localized: "浅色模式")
        case .dark: String(localized: "深色模式")
        }
    }

    /// 对应的 SwiftUI ColorScheme
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
