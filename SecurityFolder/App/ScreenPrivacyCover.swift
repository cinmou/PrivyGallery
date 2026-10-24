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
        }
        observe(UIScene.willDeactivateNotification) { anchor in
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
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification, object: scene.screen, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCover() }
        })
        updateCover()
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
    }

    private func updateCover() {
        guard let scene = observedScene else { return }
        let isCaptured = hideContentDuringCapture && scene.screen.isCaptured
        guard !isSceneActive || isCaptured else {
            coverWindow?.isHidden = true
            coverWindow = nil
            return
        }
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
        coverWindow?.isHidden = false
    }

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
