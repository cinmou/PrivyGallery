import UIKit

final class MediaGlassContainerView: UIView {
    private let nativeParamsView: UIView?
    private let nativeView: UIVisualEffectView?
    private let legacyContentView: UIView?

    var contentView: UIView {
        nativeView?.contentView ?? legacyContentView!
    }

    init(spacing: CGFloat = 7) {
        if #available(iOS 26.0, *) {
            let effect = UIGlassContainerEffect()
            effect.spacing = spacing
            let nativeView = UIVisualEffectView(effect: effect)
            let nativeParamsView = UIView()
            nativeParamsView.addSubview(nativeView)
            self.nativeView = nativeView
            self.nativeParamsView = nativeParamsView
            self.legacyContentView = nil
        } else {
            self.nativeView = nil
            self.nativeParamsView = nil
            self.legacyContentView = UIView()
        }
        super.init(frame: .zero)
        if let nativeParamsView {
            addSubview(nativeParamsView)
        } else if let legacyContentView {
            addSubview(legacyContentView)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        nativeParamsView?.frame = bounds
        nativeView?.frame = bounds
        legacyContentView?.frame = bounds
    }
}

final class MediaGlassView: UIView {
    enum TintStyle {
        case panel
        case clear
        case custom(UIColor)
    }

    private let nativeParamsView: UIView?
    private let nativeView: UIVisualEffectView?
    private let legacyFill = UIView()
    private let legacyBorder = CAShapeLayer()
    private let legacyHighlight = CAGradientLayer()
    private let legacyShadow = CAShapeLayer()
    private let legacyContentView = UIView()

    var contentView: UIView {
        nativeView?.contentView ?? legacyContentView
    }

    private var cornerRadius: CGFloat = 0
    private var isDark = true
    private var tintStyle: TintStyle = .panel
    private var isInteractiveGlass = false

    override init(frame: CGRect) {
        if #available(iOS 26.0, *) {
            let glassEffect = UIGlassEffect(style: .regular)
            glassEffect.isInteractive = false
            let nativeView = UIVisualEffectView(effect: glassEffect)
            let nativeParamsView = UIView()
            nativeParamsView.addSubview(nativeView)
            self.nativeView = nativeView
            self.nativeParamsView = nativeParamsView
        } else {
            self.nativeView = nil
            self.nativeParamsView = nil
        }
        super.init(frame: frame)
        if let nativeParamsView {
            addSubview(nativeParamsView)
        } else {
            layer.insertSublayer(legacyShadow, at: 0)
            addSubview(legacyFill)
            legacyFill.layer.addSublayer(legacyHighlight)
            legacyFill.layer.addSublayer(legacyBorder)
            addSubview(legacyContentView)
        }
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(cornerRadius: CGFloat, isDark: Bool = true, tintStyle: TintStyle = .panel, isInteractive: Bool = false) {
        self.cornerRadius = cornerRadius
        self.isDark = isDark
        self.tintStyle = tintStyle
        self.isInteractiveGlass = isInteractive
        updateEffect()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        nativeParamsView?.frame = bounds
        nativeView?.frame = bounds
        nativeView?.layer.cornerRadius = cornerRadius
        nativeView?.layer.masksToBounds = true

        legacyFill.frame = bounds
        legacyFill.layer.cornerRadius = cornerRadius
        legacyFill.layer.masksToBounds = true
        legacyContentView.frame = bounds
        legacyContentView.layer.cornerRadius = cornerRadius
        legacyContentView.layer.masksToBounds = true

        let path = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).cgPath
        legacyBorder.path = path
        legacyBorder.frame = bounds
        legacyBorder.fillColor = UIColor.clear.cgColor
        legacyBorder.strokeColor = UIColor.white.withAlphaComponent(isDark ? 0.22 : 0.34).cgColor
        legacyBorder.lineWidth = 1 / max(UIScreen.main.scale, 1)

        legacyHighlight.frame = bounds
        legacyHighlight.cornerRadius = cornerRadius
        legacyHighlight.colors = [
            UIColor.white.withAlphaComponent(isDark ? 0.30 : 0.46).cgColor,
            UIColor.white.withAlphaComponent(0.05).cgColor,
            UIColor.black.withAlphaComponent(isDark ? 0.14 : 0.05).cgColor
        ]
        legacyHighlight.locations = [0.0, 0.42, 1.0]
        legacyHighlight.startPoint = CGPoint(x: 0.25, y: 0.0)
        legacyHighlight.endPoint = CGPoint(x: 0.75, y: 1.0)

        legacyShadow.path = path
        legacyShadow.shadowPath = path
        legacyShadow.fillColor = UIColor.clear.cgColor
        legacyShadow.shadowColor = UIColor.black.cgColor
        legacyShadow.shadowOpacity = 0.18
        legacyShadow.shadowRadius = 10
        legacyShadow.shadowOffset = CGSize(width: 0, height: 4)
    }

    private func updateEffect() {
        if #available(iOS 26.0, *), let nativeView {
            let effect: UIGlassEffect
            switch tintStyle {
            case .panel:
                effect = UIGlassEffect(style: .regular)
                effect.tintColor = isDark ? UIColor(white: 1, alpha: 0.025) : UIColor(white: 1, alpha: 0.1)
            case .clear:
                effect = UIGlassEffect(style: .clear)
                effect.tintColor = isDark ? UIColor(white: 0, alpha: 0.28) : nil
            case let .custom(color):
                effect = UIGlassEffect(style: .regular)
                effect.tintColor = color
            }
            effect.isInteractive = isInteractiveGlass
            nativeView.effect = effect
            nativeView.overrideUserInterfaceStyle = isDark ? .dark : .light
        } else {
            switch tintStyle {
            case .panel:
                legacyFill.backgroundColor = isDark ? UIColor(white: 0.06, alpha: 0.46) : UIColor(white: 1, alpha: 0.54)
            case .clear:
                legacyFill.backgroundColor = UIColor(white: isDark ? 0 : 1, alpha: isDark ? 0.20 : 0.10)
            case let .custom(color):
                legacyFill.backgroundColor = color
            }
        }
    }
}

final class MediaGlassIconButton: UIButton {
    private let glassView = MediaGlassView()
    private var highlightedScale: CGFloat = 0.92

    override init(frame: CGRect) {
        super.init(frame: frame)
        insertSubview(glassView, at: 0)
        glassView.isUserInteractionEnabled = false
        backgroundColor = .clear
        tintColor = .white
        clipsToBounds = false
        imageView?.contentMode = .center
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassView.frame = bounds
        glassView.update(cornerRadius: min(bounds.width, bounds.height) * 0.5, isDark: true, tintStyle: .custom(UIColor(white: 0, alpha: 0.20)), isInteractive: true)
        imageView?.contentMode = .center
        if let imageView {
            bringSubviewToFront(imageView)
        }
        if let titleLabel {
            bringSubviewToFront(titleLabel)
        }
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: self.highlightedScale, y: self.highlightedScale) : .identity
                self.alpha = self.isHighlighted ? 0.82 : 1
            }
        }
    }
}

final class MediaGlassLabel: UIView {
    private let glassView = MediaGlassView()
    private let label = UILabel()

    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    var textColor: UIColor! {
        get { label.textColor }
        set { label.textColor = newValue }
    }

    var font: UIFont! {
        get { label.font }
        set { label.font = newValue }
    }

    var textAlignment: NSTextAlignment {
        get { label.textAlignment }
        set { label.textAlignment = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glassView)
        addSubview(label)
        glassView.isUserInteractionEnabled = false
        label.isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = false
        label.textColor = .white
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = false
        label.layer.zPosition = 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassView.frame = bounds
        glassView.update(cornerRadius: min(bounds.width, bounds.height) * 0.5, isDark: true, tintStyle: .custom(UIColor(white: 0, alpha: 0.34)), isInteractive: false)
        label.frame = bounds
        // The rate label must stay above the glass background; effect views can otherwise cover drawn text.
        bringSubviewToFront(label)
    }
}
