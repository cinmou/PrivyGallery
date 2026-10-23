import UIKit

final class MediaScrubberUIKitView: UIView {
    var onScrubBegan: (() -> Void)?
    var onScrubChanged: ((Double) -> Void)?
    var onScrubEnded: ((Double) -> Void)?

    var allowsSeeking = true {
        didSet { panGesture.isEnabled = allowsSeeking }
    }

    private let glassContainer = MediaGlassContainerView()
    private let glassView = MediaGlassView()
    private let currentLabel = UILabel()
    private let durationLabel = UILabel()
    private let trackView = UIView()
    private let bufferView = UIView()
    private let progressView = UIView()
    private lazy var panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))

    private var duration: Double = 0
    private var currentTime: Double = 0
    private var bufferedTime: Double = 0
    private var isScrubbing = false
    private var isProgrammaticUpdate = false

    var isTrackingUserScrub: Bool {
        isScrubbing
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(currentTime: Double, duration: Double, bufferedTime: Double) {
        isProgrammaticUpdate = true
        defer { isProgrammaticUpdate = false }
        if !isScrubbing {
            self.currentTime = currentTime
        }
        self.duration = max(duration, 0)
        self.bufferedTime = max(bufferedTime, 0)
        let previousHeight = preferredHeight(for: bounds.width)
        currentLabel.text = Self.timeString(self.currentTime)
        durationLabel.text = self.duration > 0 ? Self.timeString(self.duration) : "--:--"
        setNeedsLayout()
        if preferredHeight(for: bounds.width) != previousHeight { superview?.setNeedsLayout() }
    }

    private var timeLabelWidth: CGFloat {
        max(54, currentLabel.intrinsicContentSize.width, durationLabel.intrinsicContentSize.width)
    }

    private func stacksTimes(for width: CGFloat) -> Bool { width < timeLabelWidth * 2 + 28 + 16 + 60 }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        let line = max(currentLabel.font.lineHeight, durationLabel.font.lineHeight)
        return stacksTimes(for: width) ? max(64, line * 2 + 32) : max(44, line + 20)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fullHeight = bounds.height
        glassContainer.frame = bounds
        glassView.frame = glassContainer.bounds
        glassView.update(cornerRadius: min(22, fullHeight / 2), isDark: true, tintStyle: .panel, isInteractive: allowsSeeking)
        if stacksTimes(for: bounds.width) {
            let line = max(currentLabel.font.lineHeight, durationLabel.font.lineHeight)
            let labelWidth = max(0, bounds.width - 28)
            currentLabel.frame = CGRect(x: 14, y: 8, width: labelWidth, height: line)
            durationLabel.frame = CGRect(x: 14, y: 10 + line, width: labelWidth, height: line)
            durationLabel.textAlignment = .left
            trackView.frame = CGRect(x: 14, y: max(0, fullHeight - 16), width: labelWidth, height: 6)
        } else {
            let width = timeLabelWidth
            currentLabel.frame = CGRect(x: 14, y: 0, width: width, height: fullHeight)
            durationLabel.frame = CGRect(x: bounds.width - width - 14, y: 0, width: width, height: fullHeight)
            durationLabel.textAlignment = .right
            let trackX = currentLabel.frame.maxX + 8
            trackView.frame = CGRect(x: trackX, y: (fullHeight - 6) / 2,
                                     width: max(0, durationLabel.frame.minX - trackX - 8), height: 6)
        }
        trackView.layer.cornerRadius = 3
        bufferView.frame = progressFrame(maxTime: bufferedTime, in: trackView.bounds)
        progressView.frame = progressFrame(maxTime: currentTime, in: trackView.bounds)
    }

    private func setup() {
        addSubview(glassContainer)
        glassContainer.contentView.addSubview(glassView)
        glassView.contentView.addSubview(currentLabel)
        glassView.contentView.addSubview(durationLabel)
        glassView.contentView.addSubview(trackView)
        trackView.addSubview(bufferView)
        trackView.addSubview(progressView)
        addGestureRecognizer(panGesture)

        [currentLabel, durationLabel].forEach {
            $0.textColor = .white
            $0.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
            $0.adjustsFontForContentSizeCategory = true
        }
        durationLabel.textAlignment = .right
        trackView.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        bufferView.backgroundColor = UIColor.white.withAlphaComponent(0.36)
        progressView.backgroundColor = .white
        [trackView, bufferView, progressView].forEach {
            $0.layer.masksToBounds = true
            $0.layer.cornerRadius = max(1, $0.bounds.height / 2)
        }
    }

    private func progressFrame(maxTime: Double, in rect: CGRect) -> CGRect {
        let progress = duration > 0 ? min(max(maxTime / duration, 0), 1) : 0
        return CGRect(x: 0, y: 0, width: rect.width * progress, height: rect.height)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard allowsSeeking, duration > 0, !isProgrammaticUpdate else { return }
        let point = gesture.location(in: trackView)
        let progress = min(max(point.x / max(trackView.bounds.width, 1), 0), 1)
        let time = duration * progress

        switch gesture.state {
        case .began:
            isScrubbing = true
            onScrubBegan?()
            onScrubChanged?(time)
        case .changed:
            currentTime = time
            currentLabel.text = Self.timeString(time)
            setNeedsLayout()
            onScrubChanged?(time)
        case .ended, .cancelled, .failed:
            isScrubbing = false
            onScrubEnded?(time)
        default:
            break
        }
    }

    private static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        return "\(minutes):\(secs < 10 ? "0" : "")\(secs)"
    }
}
