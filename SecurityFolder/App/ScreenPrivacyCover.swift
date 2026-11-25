import QuartzCore
import SwiftUI
import UIKit

/// A scene-scoped window covers UIKit presentations as well as the SwiftUI root.
/// It never becomes key, so showing it cannot interrupt Face ID or keyboard focus.
struct ScreenPrivacyCover: UIViewRepresentable {
    let session: AppSessionViewModel
    @AppStorage(AppSettingsKey.hideContentDuringCapture)
    private var hideContentDuringCapture = AppSettingsKey.defaultHideContentDuringCapture

    func makeUIView(context: Context) -> PrivacyWindowAnchor {
        PrivacyWindowAnchor(session: session, hideContentDuringCapture: hideContentDuringCapture)
    }

    func updateUIView(_ uiView: PrivacyWindowAnchor, context: Context) {
        uiView.setCaptureProtection(hideContentDuringCapture)
    }

    static func dismantleUIView(_ uiView: PrivacyWindowAnchor, coordinator: ()) {
        uiView.detach()
    }
}

final class PrivacyWindowAnchor: UIView {
    private let session: AppSessionViewModel
    private weak var observedScene: UIWindowScene?
    private var coverWindow: UIWindow?
    private var observers: [NSObjectProtocol] = []
    private var isSceneActive = false
    private var hideContentDuringCapture: Bool

    init(session: AppSessionViewModel, hideContentDuringCapture: Bool) {
        self.session = session
        self.hideContentDuringCapture = hideContentDuringCapture
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let scene = window?.windowScene else {
            detach()
            return
        }
        guard observedScene !== scene else { return }
        detach()
        observedScene = scene
        isSceneActive = scene.activationState == .foregroundActive
        // Mounting can happen during a SwiftUI update. Publish the initial phase afterwards.
        Task { @MainActor [weak self] in
            guard let self, self.observedScene === scene else { return }
            if scene.activationState == .background {
                self.session.handleDidEnterBackground()
            } else {
                self.session.handleScenePhaseChange(isActive: scene.activationState == .foregroundActive)
            }
            #if targetEnvironment(macCatalyst)
            self.updateMacWindowSharingType()
            #endif
        }
        observe(UIScene.willDeactivateNotification) { anchor in
            // A biometric prompt can deactivate the scene while the lock screen is visible.
            if anchor.session.isAuthenticating && !anchor.session.isUnlocked { return }
            anchor.isSceneActive = false
            anchor.updateCover()
            anchor.session.handleScenePhaseChange(isActive: false)
        }
        observe(UIScene.didEnterBackgroundNotification) { anchor in
            anchor.isSceneActive = false
            anchor.updateCover()
            anchor.session.handleDidEnterBackground()
        }
        observe(UIScene.didActivateNotification) { anchor in
            anchor.isSceneActive = true
            anchor.session.handleScenePhaseChange(isActive: true)
            anchor.updateCover()
            #if targetEnvironment(macCatalyst)
            anchor.updateMacWindowSharingType()
            #endif
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification, object: scene.screen, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCover() }
        })
        updateCover()
        #if targetEnvironment(macCatalyst)
        updateMacWindowSharingType()
        #endif
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor (PrivacyWindowAnchor) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: observedScene, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        })
    }

    func setCaptureProtection(_ enabled: Bool) {
        hideContentDuringCapture = enabled
        updateCover()
        #if targetEnvironment(macCatalyst)
        updateMacWindowSharingType()
        #endif
    }

    private func updateCover() {
        guard let scene = observedScene else { return }
        let isCaptured = hideContentDuringCapture && scene.screen.isCaptured
        guard !isSceneActive || isCaptured else {
            coverWindow?.isHidden = true
            coverWindow = nil
            return
        }
        // 零延迟立即遮罩，避免录屏或切出瞬间出现淡入暴露窗口。
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            if coverWindow == nil {
                let cover = UIWindow(windowScene: scene)
                cover.windowLevel = .alert + 1
                cover.overrideUserInterfaceStyle = window?.traitCollection.userInterfaceStyle ?? .unspecified
                cover.backgroundColor = .systemBackground
                cover.rootViewController = UIHostingController(rootView: PrivacyCoverContent(isCaptured: isCaptured))
                coverWindow = cover
            } else if let host = coverWindow?.rootViewController as? UIHostingController<PrivacyCoverContent> {
                host.rootView = PrivacyCoverContent(isCaptured: isCaptured)
            }
            coverWindow?.layer.removeAllAnimations()
            coverWindow?.isHidden = false
            coverWindow?.layoutIfNeeded()
        }
    }

    #if targetEnvironment(macCatalyst)
    private func updateMacWindowSharingType() {
        // NSWindowSharingNone = 0, NSWindowSharingReadOnly = 1 (AppKit 默认值)
        let sharingType: UInt = hideContentDuringCapture ? 0 : 1
        let sharedAppSelector = NSSelectorFromString("sharedApplication")
        guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
              nsAppClass.responds(to: sharedAppSelector),
              let sharedApp = nsAppClass.perform(sharedAppSelector)?.takeUnretainedValue() as? NSObject else {
            return
        }

        let windowsSelector = NSSelectorFromString("windows")
        guard sharedApp.responds(to: windowsSelector),
              let nsWindows = sharedApp.perform(windowsSelector)?.takeUnretainedValue() as? [NSObject] else {
            return
        }

        let setSharingTypeSelector = NSSelectorFromString("setSharingType:")
        for nsWindow in nsWindows {
            guard nsWindow.responds(to: setSharingTypeSelector) else { continue }
            nsWindow.setValue(NSNumber(value: sharingType), forKey: "sharingType")
        }
    }
    #endif

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        coverWindow?.isHidden = true
        coverWindow = nil
        observedScene = nil
    }
}

private struct PrivacyCoverContent: View {
    let isCaptured: Bool

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: isCaptured ? "record.circle" : "lock.fill")
                    .font(.system(size: 28, weight: .semibold))
                Text(isCaptured ? String(localized: "已隐藏内容") : String(localized: "已锁定"))
                    .font(.headline)
                if isCaptured {
                    Text(String(localized: "检测到录屏或投屏，已隐藏应用内容。"))
                        .font(.footnote)
                }
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
        }
    }
}
