import SwiftUI

struct AdaptiveTabDockView: View {
    @Binding var selectedTab: AppTab
    let onLock: () -> Void

    private let centerButtonSize: CGFloat = 60
    private let centerIconSize: CGFloat = 32

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                dockContent
                    .modifier(DockGlassBackground())
            }
        } else {
            dockContent
                .modifier(DockGlassBackground())
        }
    }

    private var dockContent: some View {
        HStack(spacing: 0) {
            dockTabButton(
                title: AppTab.media.title,
                systemImage: AppTab.media.systemImage,
                isSelected: selectedTab == .media
            ) {
                switchToTab(.media)
            }

            centerLockButton

            dockTabButton(
                title: AppTab.settings.title,
                systemImage: AppTab.settings.systemImage,
                isSelected: selectedTab == .settings
            ) {
                switchToTab(.settings)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
    }

    private func dockTabButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color.blue : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isSelected)
        }
        .buttonStyle(DockPressButtonStyle())
    }

    private var centerLockButton: some View {
        Button(action: onLock) {
            Image("custom.wheel")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: centerIconSize, height: centerIconSize)
                .padding(18)
                .modifier(CenterDockGlassBackground())
        }
        .buttonStyle(CenterDockPressButtonStyle())
        .frame(width: centerButtonSize + 22, height: centerButtonSize)
        .accessibilityLabel(Text(String(localized: "锁定相册")))
    }

    private func switchToTab(_ tab: AppTab) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
            selectedTab = tab
        }
    }
}

struct DockPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

struct CenterDockPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.74), value: configuration.isPressed)
    }
}

private struct DockGlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.03), radius: 1, x: 0, y: 1)
        }
    }
}

private struct CenterDockGlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.02), radius: 1, x: 0, y: 1)
        }
    }
}
