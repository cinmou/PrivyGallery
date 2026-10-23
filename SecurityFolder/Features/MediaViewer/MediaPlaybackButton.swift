import UIKit

/// Playback-specific content on the viewer's existing glass button.
final class MediaPlaybackButton: MediaGlassIconButton {
    enum Kind {
        case backward, playPause, forward
    }

    private let kind: Kind
    private let icon = UIImageView()
    private let intervalLabel = UILabel()
    private var symbolName: String
    private var iconPointSize: CGFloat = 34

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case .backward: symbolName = "gobackward"
        case .playPause: symbolName = "play.fill"
        case .forward: symbolName = "goforward"
        }
        super.init(frame: .zero)
        icon.tintColor = .white
        icon.contentMode = .center
        icon.isUserInteractionEnabled = false
        addSubview(icon)
        intervalLabel.text = "15"
        intervalLabel.textColor = .white
        intervalLabel.textAlignment = .center
        intervalLabel.isUserInteractionEnabled = false
        intervalLabel.isHidden = kind == .playPause
        addSubview(intervalLabel)
        isAccessibilityElement = true
        icon.isAccessibilityElement = false
        intervalLabel.isAccessibilityElement = false
        setIconPointSize(iconPointSize)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setIconPointSize(_ size: CGFloat) {
        guard size != iconPointSize || icon.image == nil else { return }
        iconPointSize = size
        icon.preferredSymbolConfiguration = .init(pointSize: size, weight: .semibold)
        icon.image = UIImage(systemName: symbolName)
        intervalLabel.font = .systemFont(ofSize: size * 0.42, weight: .semibold)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let offset: CGFloat = symbolName == "play.fill" ? bounds.width * 0.035 : 0
        icon.bounds.size = CGSize(width: iconPointSize * 1.3, height: iconPointSize * 1.3)
        icon.center = CGPoint(x: bounds.midX + offset, y: bounds.midY)
        intervalLabel.bounds.size = CGSize(width: iconPointSize, height: iconPointSize * 0.65)
        intervalLabel.center = CGPoint(x: bounds.midX, y: bounds.midY + 1)
        bringSubviewToFront(icon)
        bringSubviewToFront(intervalLabel)
    }

    func updatePlayback(isPlaying: Bool, didFinish: Bool, animated: Bool) {
        let nextSymbol = didFinish ? "arrow.clockwise" : (isPlaying ? "pause.fill" : "play.fill")
        accessibilityLabel = isPlaying ? String(localized: "暂停") : String(localized: "播放")
        guard symbolName != nextSymbol else { return }
        symbolName = nextSymbol
        let image = UIImage(systemName: nextSymbol)
        if animated && !UIAccessibility.isReduceMotionEnabled, let image {
            icon.setSymbolImage(image, contentTransition: .replace)
        } else {
            icon.image = image
        }
        setNeedsLayout()
    }

    func animateSeek() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let direction: CGFloat = kind == .forward ? 1 : -1
        // Only the arrow turns; the interval stays readable during repeated taps.
        icon.layer.removeAllAnimations()
        icon.transform = .identity
        UIView.animateKeyframes(withDuration: 0.36, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.45) {
                self.icon.transform = CGAffineTransform(rotationAngle: direction * .pi / 3)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.45, relativeDuration: 0.55) {
                self.icon.transform = .identity
            }
        }
    }
}
