import SwiftUI
import UIKit

struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var session: AppSessionViewModel
    @State private var isScreenCaptured = UIScreen.main.isCaptured

    @AppStorage(AppSettingsKey.appTheme)
    private var appTheme = ThemeOption.system.rawValue
    @AppStorage(AppSettingsKey.screenPrivacyProtectionEnabled)
    private var screenPrivacyProtectionEnabled = AppSettingsKey.defaultScreenPrivacyProtectionEnabled

    var body: some View {
        ZStack {
            rootContent

            // 当 App 进入切后台 / 多任务切换时，先盖一层原生材质，
            // 避免系统抓取到未锁定的媒体内容快照。
            if session.isSnapshotObscured && session.isUnlocked {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    // Purely visual — must never consume touches so that
                    // the lock screen below remains interactive.
                    .allowsHitTesting(false)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 28, weight: .semibold))
                            Text(String(localized: "已锁定"))
                                .font(.headline)
                        }
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                    }
            }

            if shouldObscureForCapture {
                Rectangle()
                    .fill(.thickMaterial)
                    .ignoresSafeArea()
                    // Purely visual privacy screen — must never consume touches.
                    // Without this, the material fill blocks all taps on every
                    // screen (including locked/onboarding) on iOS 17 when
                    // screen capture is active or isCaptured returns true.
                    .allowsHitTesting(false)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "record.circle")
                                .font(.system(size: 28, weight: .semibold))
                            Text(String(localized: "已隐藏内容"))
                                .font(.headline)
                            Text(String(localized: "检测到录屏或投屏，屏幕隐私保护已生效。"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .allowsHitTesting(false)
                    }
            }
        }
        .preferredColorScheme(ThemeOption(rawValue: appTheme)?.colorScheme)
        .overlay {
            InteractionCaptureView {
                session.registerInteraction()
            }
            .ignoresSafeArea()
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                session.registerInteraction()
            },
            including: .subviews
        )
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                StoreKitManager.shared.activate()
            }
            session.handleScenePhaseChange(isActive: newPhase == .active)
        }
        .task {
            StoreKitManager.shared.activate()
        }
        #if targetEnvironment(macCatalyst)
        .onAppear {
            configureMacWindow()
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            session.handleDidEnterBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            isScreenCaptured = UIScreen.main.isCaptured
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            guard screenPrivacyProtectionEnabled else { return }
            session.lock(withMessage: String(localized: "检测到截屏，应用已锁定。"))
        }
        #if targetEnvironment(macCatalyst)
        .sheet(isPresented: macUnlockPresentationBinding) {
            UnlockView(session: session)
                // Wider sheet so the onboarding content is not squeezed into
                // a phone-like narrow card inside a desktop window.
                .frame(minWidth: 560, idealWidth: 600, maxWidth: 660, minHeight: 560, idealHeight: 660)
                .interactiveDismissDisabled(true)
        }
        #endif
    }

    @ViewBuilder
    private var rootContent: some View {
        #if targetEnvironment(macCatalyst)
        if session.isUnlocked, let activeSpace = session.activeSpace {
            LibraryTabView(space: activeSpace, session: session)
        } else {
            ContentUnavailableView(
                String(localized: "保险箱已锁定"),
                systemImage: "lock.fill",
                description: Text(String(localized: "请在解锁窗口中输入密码。"))
            )
        }
        #else
        if session.isUnlocked, let activeSpace = session.activeSpace {
            LibraryTabView(space: activeSpace, session: session)
        } else {
            UnlockView(session: session)
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Configure the main macOS window: enforce a sensible minimum size and hide
    /// the title bar so the sidebar background can extend flush to the top-left
    /// traffic-light area, matching native Mac app conventions.
    private func configureMacWindow() {
        for windowScene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            // Free resize: intentionally set NEITHER minimumSize nor maximumSize so
            // the user can size the window however they like — only macOS's own
            // natural limits apply. We just pick a roomy initial size on first
            // launch (the Mac idiom ignores SwiftUI's .defaultSize).
            if !Self.didSetInitialMacWindowSize {
                Self.didSetInitialMacWindowSize = true
                let origin = windowScene.windows.first?.frame.origin ?? CGPoint(x: 80, y: 80)
                let preferred = CGRect(origin: origin, size: CGSize(width: 1280, height: 840))
                windowScene.requestGeometryUpdate(.Mac(systemFrame: preferred))
            }

            // Native macOS title bar (Finder/Photos/Settings): hidden title,
            // unified toolbar so the sidebar's items sit by the traffic lights,
            // and no separator so the sidebar material flows up continuously.
            if let titlebar = windowScene.titlebar {
                titlebar.titleVisibility = .hidden
                titlebar.toolbarStyle = .unified
                titlebar.separatorStyle = .none
            }
        }
    }

    private static var didSetInitialMacWindowSize = false
    #endif

    private var shouldObscureForCapture: Bool {
        screenPrivacyProtectionEnabled && isScreenCaptured
    }

    #if targetEnvironment(macCatalyst)
    private var macUnlockPresentationBinding: Binding<Bool> {
        Binding(
            get: { !session.isUnlocked },
            set: { _ in }
        )
    }
    #endif
}

private struct InteractionCaptureView: UIViewRepresentable {
    let onInteraction: () -> Void

    func makeUIView(context: Context) -> InteractionCaptureUIView {
        let view = InteractionCaptureUIView()
        view.onInteraction = onInteraction
        return view
    }

    func updateUIView(_ uiView: InteractionCaptureUIView, context: Context) {
        uiView.onInteraction = onInteraction
    }
}

private final class InteractionCaptureUIView: UIView, UIGestureRecognizerDelegate {
    var onInteraction: (() -> Void)?

    private lazy var tapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleInteractionGesture))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var panRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleInteractionGesture))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var hoverRecognizer: UIHoverGestureRecognizer = {
        let recognizer = UIHoverGestureRecognizer(target: self, action: #selector(handleHoverGesture(_:)))
        recognizer.delegate = self
        return recognizer
    }()

    private weak var installedWindow: UIWindow?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if installedWindow !== window {
            detachRecognizers()
            installRecognizersIfNeeded()
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }

    @objc
    private func handleInteractionGesture() {
        onInteraction?()
    }

    @objc
    private func handleHoverGesture(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        onInteraction?()
    }

    private func installRecognizersIfNeeded() {
        guard let window else { return }
        installedWindow = window
        window.addGestureRecognizer(tapRecognizer)
        window.addGestureRecognizer(panRecognizer)
        if #available(iOS 13.4, *) {
            window.addGestureRecognizer(hoverRecognizer)
        }
    }

    private func detachRecognizers() {
        installedWindow?.removeGestureRecognizer(tapRecognizer)
        installedWindow?.removeGestureRecognizer(panRecognizer)
        if #available(iOS 13.4, *) {
            installedWindow?.removeGestureRecognizer(hoverRecognizer)
        }
        installedWindow = nil
    }

    deinit {
        detachRecognizers()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
