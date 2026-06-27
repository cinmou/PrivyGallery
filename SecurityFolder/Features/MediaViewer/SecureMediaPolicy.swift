import SwiftUI
import UIKit

final class SecureCanvasTextField: UITextField {
    override var canBecomeFirstResponder: Bool { false }

    override func becomeFirstResponder() -> Bool {
        false
    }
}

struct SecureCaptureContainer<Content: View>: UIViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let rootView = UIView()
        rootView.backgroundColor = .black

        let secureTextField = SecureCanvasTextField()
        secureTextField.translatesAutoresizingMaskIntoConstraints = false
        secureTextField.isSecureTextEntry = true
        secureTextField.backgroundColor = .black
        secureTextField.textColor = .clear
        secureTextField.tintColor = .clear
        rootView.addSubview(secureTextField)

        NSLayoutConstraint.activate([
            secureTextField.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            secureTextField.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            secureTextField.topAnchor.constraint(equalTo: rootView.topAnchor),
            secureTextField.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        let host = UIHostingController(rootView: AnyView(content))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .black

        let secureContainer = secureCanvasView(in: secureTextField) ?? secureTextField
        secureContainer.backgroundColor = .black
        secureContainer.addSubview(host.view)

        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: secureContainer.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: secureContainer.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: secureContainer.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: secureContainer.bottomAnchor)
        ])

        context.coordinator.host = host
        context.coordinator.secureTextField = secureTextField
        return rootView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.host?.rootView = AnyView(content)
        context.coordinator.host?.view.backgroundColor = .black
        context.coordinator.secureTextField?.backgroundColor = .black
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    private func secureCanvasView(in textField: UITextField) -> UIView? {
        textField.subviews.first {
            let className = NSStringFromClass(type(of: $0))
            return className.contains("Canvas") || className.contains("Layout")
        }
    }

    final class Coordinator: NSObject {
        var host: UIHostingController<AnyView>?
        weak var secureTextField: UITextField?
        private var didTearDown = false

        func teardown() {
            guard !didTearDown else { return }
            didTearDown = true
            host?.view.removeFromSuperview()
            host = nil
            secureTextField = nil
        }

        deinit {
            teardown()
        }
    }
}
