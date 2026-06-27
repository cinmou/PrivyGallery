import SwiftUI

/// 媒体库主标签页容器
struct LibraryTabView: View {
    let space: VaultSpaceKind
    @ObservedObject var session: AppSessionViewModel

    var body: some View {
        LibraryTabContent(
            space: space,
            session: session
        )
    }
}

private struct LibraryTabContent: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AppSettingsKey.lockButtonHintShown) private var lockButtonHintShown = false
    @StateObject private var viewModel: MediaLibraryViewModel
    @ObservedObject var session: AppSessionViewModel
    @State private var showingLockHint = false
    @State private var lastContentTab: AppTab = .media

    init(space: VaultSpaceKind, session: AppSessionViewModel) {
        _viewModel = StateObject(
            wrappedValue: MediaLibraryViewModel(
                space: space
            )
        )
        self.session = session
    }

    var body: some View {
        tabContainer
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.keyboard, edges: .bottom)
        .onChange(of: session.selectedTab) { _, _ in
            session.registerInteraction()
        }
        .onChange(of: session.selectedTab) { oldValue, newValue in
            handleTabSelectionChange(from: oldValue, to: newValue)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            viewModel.importSharedPendingItemsIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultDidRefreshAfterImport)) { notification in
            guard let importedSpaceRawValue = notification.userInfo?["spaceRawValue"] as? String,
                  importedSpaceRawValue == viewModel.space.rawValue else {
                return
            }

            viewModel.refresh()
        }
        .fullScreenCover(isPresented: purchaseNoticeBinding) {
            NavigationStack {
                MembershipCenterView(isPresentedAsSheet: true)
            }
        }
        .alert(String(localized: "锁定相册"), isPresented: $showingLockHint) {
            Button(String(localized: "确认并锁定")) {
                lockButtonHintShown = true
                triggerLock()
            }
            Button(String(localized: "取消"), role: .cancel) { }
        } message: {
            Text(String(localized: "点击这里锁定当前空间"))
        }
    }

    @ViewBuilder
    private var tabContainer: some View {
        if usesPadSidebarLayout {
            largePadContentView
        } else {
            // 普通尺寸设备继续交给系统原生 TabView。
            baseTabView
        }
    }

    private var largePadContentView: some View {
        MediaLibraryView(
            viewModel: viewModel,
            adaptiveLayoutMode: adaptiveLayoutMode,
            onOpenSettings: macOpenSettingsAction,
            embeddedSettingsView: AnyView(
                SettingsView(
                    settingsViewModel: SettingsViewModel(space: viewModel.space),
                    session: session
                )
            )
        )
    }

    private var baseTabView: some View {
        TabView(selection: $session.selectedTab) {
            MediaLibraryView(viewModel: viewModel, adaptiveLayoutMode: adaptiveLayoutMode)
                .tabItem { Label(AppTab.media.title, systemImage: AppTab.media.systemImage) }
                .tag(AppTab.media)

            currentContentView(for: lastResolvedContentTab)
                .tabItem {
                    // 中间锁定按钮沿用系统 tab item，只把标题拿掉，
                    // 图标换成我们自己的 custom.wheel。
                    //
                    // 如果你后面想继续微调这个图标大小，优先改下面这个 frame。
                    // 这里建议只做小范围调整，不要大到超过系统 tab bar 的安全高度，
                    // 否则不同尺寸设备上的垂直对齐会开始飘。
                    Image("custom.wheel")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                }
                .tag(AppTab.lock)

            SettingsView(
                settingsViewModel: SettingsViewModel(space: viewModel.space),
                session: session
            )
            .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage) }
            .tag(AppTab.settings)
        }
    }

    private var purchaseNoticeBinding: Binding<Bool> {
        Binding(
            get: {
                viewModel.isMembershipUpsellPresented
            },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissMembershipUpsell()
                }
            }
        )
    }

    @ViewBuilder
    private func currentContentView(for tab: AppTab) -> some View {
        switch tab {
        case .settings:
            SettingsView(
                settingsViewModel: SettingsViewModel(space: viewModel.space),
                session: session
            )
        case .lock, .media:
            MediaLibraryView(viewModel: viewModel, adaptiveLayoutMode: adaptiveLayoutMode)
        }
    }

    private var lastResolvedContentTab: AppTab {
        lastContentTab == .lock ? .media : lastContentTab
    }

    private var usesPadSidebarLayout: Bool {
        adaptiveLayoutMode.usesWideLayout
    }

    private var adaptiveLayoutMode: AdaptiveLayoutMode {
        AdaptiveLayoutMode.resolve(horizontalSizeClass: horizontalSizeClass)
    }

    private var macOpenSettingsAction: (() -> Void)? {
        // Settings is shown embedded in the main window's right content area on all platforms.
        return nil
    }

    private func handleTabSelectionChange(from oldValue: AppTab, to newValue: AppTab) {
        if newValue != .lock {
            lastContentTab = newValue
            return
        }

        let fallbackTab: AppTab = oldValue == .lock ? lastResolvedContentTab : oldValue
        if session.selectedTab != fallbackTab {
            session.selectedTab = fallbackTab
        }
        handleLockButtonTap()
    }

    private func handleLockButtonTap() {
        if lockButtonHintShown {
            triggerLock()
        } else {
            showingLockHint = true
        }
    }
    private func triggerLock() {
        session.registerInteraction()
        session.lock()
    }
}

#Preview {
    LibraryTabView(space: .spaceA, session: PreviewSupport.session())
}
