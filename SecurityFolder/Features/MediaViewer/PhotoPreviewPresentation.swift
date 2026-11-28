import SwiftUI
import UIKit

/// Looks up the current thumbnail by identity, including after paging in the viewer.
/// The grid owns the view; the lookup closure captures its controller weakly.
final class PhotoPreviewTransitionSource {
    var currentItemID: UUID?
    var thumbnailView: ((UUID, Bool) -> UIView?)?
    var canBeginInteractiveDismiss: (() -> Bool)?

    func image(for itemID: UUID) -> UIImage? {
        (thumbnailView?(itemID, false) as? UIImageView)?.image
    }
}

/// Present explicitly through UIKit so its native zoom transition owns dragging,
/// cancellation and the return animation. SwiftUI still owns the preview content.
struct PhotoPreviewPresentation<Content: View>: UIViewControllerRepresentable {
    @Binding var itemID: UUID?
    let source: PhotoPreviewTransitionSource
    let content: (UUID, @escaping () -> Void) -> Content

    func makeUIViewController(context: Context) -> PhotoPreviewPresenter<Content> {
        PhotoPreviewPresenter(itemID: $itemID, source: source, content: content)
    }

    func updateUIViewController(_ controller: PhotoPreviewPresenter<Content>, context: Context) {
        controller.itemID = $itemID
        controller.content = content
        controller.scheduleUpdate()
    }

    static func dismantleUIViewController(_ controller: PhotoPreviewPresenter<Content>, coordinator: ()) {
        controller.detach()
    }
}

final class PhotoPreviewPresenter<Content: View>: UIViewController {
    var itemID: Binding<UUID?>
    var content: (UUID, @escaping () -> Void) -> Content
    private let source: PhotoPreviewTransitionSource
    private var preview: PhotoPreviewHostingController<Content>?
    private var presentedItemID: UUID?
    private var isDismissing = false
    private var isDetached = false
    private var lockObserver: NSObjectProtocol?

    init(itemID: Binding<UUID?>, source: PhotoPreviewTransitionSource, content: @escaping (UUID, @escaping () -> Void) -> Content) {
        self.itemID = itemID
        self.source = source
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        lockObserver = NotificationCenter.default.addObserver(forName: .vaultDidLock, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.detach() }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scheduleUpdate()
    }

    func scheduleUpdate() {
        // Avoid changing presentation state while SwiftUI is updating its hierarchy.
        DispatchQueue.main.async { [weak self] in self?.updatePresentation() }
    }

    private func resolvePresenter() -> UIViewController? {
        guard let root = view.window?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    private func validSourceView(for itemID: UUID) -> UIView? {
        guard let view = source.thumbnailView?(itemID, true),
              view.window != nil,
              !view.isHidden,
              !view.bounds.isEmpty else {
            return nil
        }
        return view
    }

    private func updatePresentation() {
        guard !isDetached, !isDismissing else { return }
        guard let selectedID = itemID.wrappedValue else {
            if preview != nil { dismissPreview() }
            return
        }
        guard preview == nil, let presenter = resolvePresenter() else { return }
        if let dismissing = presenter.presentedViewController, dismissing.isBeingDismissed {
            if let coordinator = dismissing.transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.scheduleUpdate()
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.updatePresentation()
                }
            }
            return
        }
        if let coordinator = presenter.transitionCoordinator
            ?? navigationController?.transitionCoordinator
            ?? splitViewController?.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.scheduleUpdate()
            }
            return
        }
        source.currentItemID = selectedID
        presentedItemID = selectedID
        let host = PhotoPreviewHostingController(rootView: content(selectedID, { [weak self] in self?.dismissPreview() }))
        host.modalPresentationStyle = .fullScreen
        host.overrideUserInterfaceStyle = .dark
        host.onDismissed = { [weak self, weak host] in
            guard let self, self.preview === host else { return }
            self.finishDismissal()
        }
        let options = UIViewController.Transition.ZoomOptions()
        options.interactiveDismissShouldBegin = { [weak source] context in
            context.willBegin && (source?.canBeginInteractiveDismiss?() ?? false)
        }
        host.preferredTransition = .zoom(options: options) { [weak self] _ in
            guard let self, let currentID = self.source.currentItemID else { return nil }
            return self.validSourceView(for: currentID)
        }
        preview = host
        presenter.present(host, animated: true) { [weak self, weak host] in
            guard let self, let host else { return }
            if self.isDetached {
                host.dismiss(animated: false)
            } else if host.presentingViewController == nil {
                self.finishDismissal()
            }
        }
    }

    private func dismissPreview() {
        guard let preview, !isDismissing else { return }
        isDismissing = true
        preview.dismiss(animated: true) { [weak self] in self?.finishDismissal() }
    }

    private func finishDismissal() {
        guard !isDetached, preview != nil else { return }
        preview?.onDismissed = nil
        preview = nil
        isDismissing = false
        source.canBeginInteractiveDismiss = nil
        let closedID = presentedItemID
        presentedItemID = nil
        // An interactive UIKit dismissal must also clear SwiftUI's selection.
        if itemID.wrappedValue == closedID { itemID.wrappedValue = nil }
        scheduleUpdate()
    }

    func detach() {
        isDetached = true
        if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
        lockObserver = nil
        source.canBeginInteractiveDismiss = nil
        preview?.onDismissed = nil
        preview?.view.isHidden = true
        preview?.dismiss(animated: false)
        preview = nil
    }
}

private final class PhotoPreviewHostingController<Content: View>: UIHostingController<Content> {
    var onDismissed: (() -> Void)?
    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onDismissed?() }
    }
}
