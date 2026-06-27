import SwiftUI
import UIKit

struct MediaViewerView<MenuContent: View>: View {
    let items: [VaultItem]
    let initialItemID: UUID
    let policy: MediaViewerSecurePolicy
    let actions: MediaViewerActions<MenuContent>
    let onDismiss: () -> Void

    init(
        items: [VaultItem],
        initialItemID: UUID,
        policy: MediaViewerSecurePolicy,
        actions: MediaViewerActions<MenuContent>,
        onDismiss: @escaping () -> Void
    ) {
        self.items = items
        self.initialItemID = initialItemID
        self.policy = policy
        self.actions = actions
        self.onDismiss = onDismiss
    }

    var body: some View {
        Group {
            if policy.isSecure {
                SecureUIKitMediaViewerRepresentable(
                    items: items,
                    initialItemID: initialItemID,
                    provider: SecureMediaAssetProvider(),
                    onDismiss: onDismiss,
                    onShowDetails: actions.showDetails,
                    detailInfo: actions.detailInfo,
                    exportURL: actions.exportURL
                )
            } else {
                UIKitMediaViewerRepresentable(
                    items: items,
                    initialItemID: initialItemID,
                    provider: PlainMediaAssetProvider(),
                    onDismiss: onDismiss,
                    onShowDetails: actions.showDetails,
                    detailInfo: actions.detailInfo,
                    exportURL: actions.exportURL
                )
            }
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
    }
}

private struct UIKitMediaViewerRepresentable: UIViewControllerRepresentable {
    let items: [VaultItem]
    let initialItemID: UUID
    let provider: MediaAssetProvider
    let onDismiss: () -> Void
    let onShowDetails: (VaultItem) -> Void
    let detailInfo: (VaultItem) -> MediaItemDetailInfo?
    let exportURL: (VaultItem) -> URL?

    func makeUIViewController(context: Context) -> MediaViewerController {
        let controller = MediaViewerController(items: items, initialItemID: initialItemID, provider: provider)
        controller.onDismiss = onDismiss
        controller.onShowDetails = onShowDetails
        controller.detailInfo = detailInfo
        controller.exportURL = exportURL
        return controller
    }

    func updateUIViewController(_ uiViewController: MediaViewerController, context: Context) {
        uiViewController.onDismiss = onDismiss
        uiViewController.onShowDetails = onShowDetails
        uiViewController.detailInfo = detailInfo
        uiViewController.exportURL = exportURL
    }
}

private struct SecureUIKitMediaViewerRepresentable: UIViewControllerRepresentable {
    let items: [VaultItem]
    let initialItemID: UUID
    let provider: MediaAssetProvider
    let onDismiss: () -> Void
    let onShowDetails: (VaultItem) -> Void
    let detailInfo: (VaultItem) -> MediaItemDetailInfo?
    let exportURL: (VaultItem) -> URL?

    func makeUIViewController(context: Context) -> SecureMediaViewerHostController {
        let viewer = MediaViewerController(items: items, initialItemID: initialItemID, provider: provider)
        viewer.onDismiss = onDismiss
        viewer.onShowDetails = onShowDetails
        viewer.detailInfo = detailInfo
        viewer.exportURL = exportURL
        viewer.protectsMediaContentFromCapture = true
        return SecureMediaViewerHostController(viewer: viewer)
    }

    func updateUIViewController(_ uiViewController: SecureMediaViewerHostController, context: Context) {
        uiViewController.viewer.onDismiss = onDismiss
        uiViewController.viewer.onShowDetails = onShowDetails
        uiViewController.viewer.detailInfo = detailInfo
        uiViewController.viewer.exportURL = exportURL
    }
}

private final class SecureMediaViewerHostController: UIViewController {
    let viewer: MediaViewerController

    init(viewer: MediaViewerController) {
        self.viewer = viewer
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersStatusBarHidden: Bool { true }
    override var childForStatusBarHidden: UIViewController? { viewer }
    override var canBecomeFirstResponder: Bool { viewer.canBecomeFirstResponder }
    override var keyCommands: [UIKeyCommand]? { viewer.keyCommands }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        configureSecureCanvas()
        embedViewer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        viewer.becomeFirstResponder()
    }

    private func configureSecureCanvas() {
        // The secure text-field hack is intentionally not used as the root viewer container.
        // Media pages protect only their image/video content, while overlays and gestures stay in normal UIKit layers.
        view.backgroundColor = .black
    }

    private func embedViewer() {
        addChild(viewer)
        viewer.view.translatesAutoresizingMaskIntoConstraints = false
        viewer.view.backgroundColor = .black
        view.addSubview(viewer.view)

        NSLayoutConstraint.activate([
            viewer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            viewer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            viewer.view.topAnchor.constraint(equalTo: view.topAnchor),
            viewer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        viewer.didMove(toParent: self)
    }
}
