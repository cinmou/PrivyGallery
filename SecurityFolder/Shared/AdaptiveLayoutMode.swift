import SwiftUI
import UIKit

/// Stable layout decisions that must not react to keyboard-compressed SwiftUI geometry.
enum AdaptiveLayoutMode {
    case compact
    case wide

    var usesWideLayout: Bool {
        self == .wide
    }

    static func resolve(horizontalSizeClass: UserInterfaceSizeClass?) -> Self {
        #if targetEnvironment(macCatalyst)
        return .wide
        #else
        guard UIDevice.current.userInterfaceIdiom == .pad else { return .compact }
        return horizontalSizeClass == .regular ? .wide : .compact
        #endif
    }
}
