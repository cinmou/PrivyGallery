import SwiftUI
import UIKit

/// Stable layout decisions that must not react to keyboard-compressed SwiftUI geometry.
enum AdaptiveLayoutMode {
    case compact
    case wide

    var usesWideLayout: Bool {
        self == .wide
    }

    static func resolve(horizontalSizeClass: UserInterfaceSizeClass?, hasDeviceHinge: Bool = false) -> Self {
        #if targetEnvironment(macCatalyst)
        return .wide
        #else
        guard UIDevice.current.userInterfaceIdiom == .pad || hasDeviceHinge else { return .compact }
        return horizontalSizeClass == .regular ? .wide : .compact
        #endif
    }
}

/// Limits Duo adaptations to a hierarchy that reports the system hinge capability.
struct DeviceHingeObserver: ViewModifier {
    @Binding var hasDeviceHinge: Bool

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
        #else
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                hasDeviceHinge = context.hinge != nil
            }
        } else {
            content
        }
        #endif
    }
}
