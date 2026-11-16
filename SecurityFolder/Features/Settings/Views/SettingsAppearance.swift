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

extension View {
    @ViewBuilder
    func macSettingsCardBorder(cornerRadius: CGFloat) -> some View {
        #if targetEnvironment(macCatalyst)
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                .allowsHitTesting(false)
        }
        #else
        self
        #endif
    }
}
