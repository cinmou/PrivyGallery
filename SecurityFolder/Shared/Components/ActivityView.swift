import SwiftUI
import UIKit

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    var excludedActivityTypes: [UIActivity.ActivityType]? = nil
    var onPresented: (() -> Void)? = nil
    var onFinish: ((Bool) -> Void)? = nil
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        controller.excludedActivityTypes = excludedActivityTypes
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onFinish?(completed)
            onComplete?()
        }
        DispatchQueue.main.async {
            onPresented?()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct NativeActivitySheetConfiguration {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    var excludedActivityTypes: [UIActivity.ActivityType]? = nil
    var onPresented: (() -> Void)? = nil
    var onFinish: ((Bool) -> Void)? = nil
    var onComplete: (() -> Void)? = nil
}

extension View {
    /// Presents `UIActivityViewController` directly through UIKit rather than nesting it
    /// inside a SwiftUI `.sheet`, avoiding iOS's first-presentation blank Share Sheet bug
    /// and sheet-transition races.
    func nativeActivitySheet<Item: Identifiable>(
        item: Binding<Item?>,
        configuration: @escaping (Item) -> NativeActivitySheetConfiguration
    ) -> some View {
        background {
            NativeActivitySheetPresenter(item: item, configuration: configuration)
                .frame(width: 0, height: 0)
        }
    }
}

private struct NativeActivitySheetPresenter<Item: Identifiable>: UIViewControllerRepresentable {
    @Binding var item: Item?
    let configuration: (Item) -> NativeActivitySheetConfiguration

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let coordinator = context.coordinator

        guard let currentItem = item else {
            if let presented = coordinator.presentedController, !presented.isBeingDismissed {
                presented.dismiss(animated: true)
            }
            coordinator.presentedItemID = nil
            coordinator.presentedController = nil
            return
        }

        guard coordinator.presentedItemID != currentItem.id else { return }
        coordinator.presentedItemID = currentItem.id

        let config = configuration(currentItem)
        guard !config.activityItems.isEmpty else {
            coordinator.presentedItemID = nil
            DispatchQueue.main.async {
                if self.item?.id == currentItem.id {
                    self.item = nil
                }
            }
            return
        }

        let itemID = currentItem.id
        DispatchQueue.main.async {
            presentActivity(
                from: uiViewController,
                itemID: itemID,
                config: config,
                coordinator: coordinator
            )
        }
    }

    private func presentActivity(
        from hostController: UIViewController,
        itemID: Item.ID,
        config: NativeActivitySheetConfiguration,
        coordinator: Coordinator,
        retryCount: Int = 0
    ) {
        guard coordinator.presentedItemID == itemID, item?.id == itemID else { return }
        guard hostController.viewIfLoaded?.window != nil else {
            if retryCount < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    presentActivity(
                        from: hostController,
                        itemID: itemID,
                        config: config,
                        coordinator: coordinator,
                        retryCount: retryCount + 1
                    )
                }
            } else {
                coordinator.presentedItemID = nil
                config.onComplete?()
                if item?.id == itemID { item = nil }
            }
            return
        }

        var presenter: UIViewController = hostController
        while let next = presenter.presentedViewController {
            if next.isBeingDismissed || next.isBeingPresented {
                if let transitionCoordinator = next.transitionCoordinator {
                    transitionCoordinator.animate(alongsideTransition: nil) { _ in
                        DispatchQueue.main.async {
                            presentActivity(
                                from: hostController,
                                itemID: itemID,
                                config: config,
                                coordinator: coordinator,
                                retryCount: retryCount + 1
                            )
                        }
                    }
                    return
                }
                if retryCount < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        presentActivity(
                            from: hostController,
                            itemID: itemID,
                            config: config,
                            coordinator: coordinator,
                            retryCount: retryCount + 1
                        )
                    }
                    return
                }
                break
            }
            presenter = next
        }

        let activityController = UIActivityViewController(
            activityItems: config.activityItems,
            applicationActivities: config.applicationActivities
        )
        activityController.excludedActivityTypes = config.excludedActivityTypes

        if let popover = activityController.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }

        var didFinish = false
        let finishOnce: @MainActor (Bool) -> Void = { completed in
            guard !didFinish else { return }
            didFinish = true
            coordinator.presentedController = nil
            if coordinator.presentedItemID == itemID {
                coordinator.presentedItemID = nil
            }
            config.onFinish?(completed)
            config.onComplete?()
            if self.item?.id == itemID {
                self.item = nil
            }
        }

        activityController.completionWithItemsHandler = { _, completed, _, _ in
            Task { @MainActor in
                finishOnce(completed)
            }
        }

        coordinator.presentedController = activityController
        presenter.present(activityController, animated: true) {
            config.onPresented?()
        }
    }

    final class Coordinator {
        var presentedItemID: Item.ID?
        weak var presentedController: UIActivityViewController?
    }
}
