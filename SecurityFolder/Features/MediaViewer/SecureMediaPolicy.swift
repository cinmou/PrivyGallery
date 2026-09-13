import UIKit

final class SecureCanvasTextField: UITextField {
    override var canBecomeFirstResponder: Bool { false }

    override func becomeFirstResponder() -> Bool {
        false
    }
}
