import SwiftUI
import UIKit

enum SettingsAppearance {
    static var pageBackground: Color {
        #if targetEnvironment(macCatalyst)
        Color(uiColor: .systemBackground)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }
}
