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
    private let collapsedTrack = UIView()
    private let collapsedProgress = UIView()
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

    func update(currentTime: Double, duration: Double, bufferedTime: Double, collapsed: Bool, animated: Bool) {
        isProgrammaticUpdate = true
        defer { isProgrammaticUpdate = false }
        if !isScrubbing {
            self.currentTime = currentTime
        }
        self.duration = max(duration, 0)
        self.bufferedTime = max(bufferedTime, 0)
        currentLabel.text = Self.timeString(self.currentTime)
        durationLabel.text = self.duration > 0 ? Self.timeString(self.duration) : "--:--"
        setCollapsed(collapsed, animated: animated)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fullHeight: CGFloat = 44
        glassContainer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: fullHeight)
        glassView.frame = glassContainer.bounds
        glassView.update(cornerRadius: fullHeight / 2, isDark: true, tintStyle: .panel, isInteractive: allowsSeeking)

        let labelWidth: CGFloat = 54
        currentLabel.frame = CGRect(x: 14, y: 0, width: labelWidth, height: fullHeight)
        durationLabel.frame = CGRect(x: bounds.width - labelWidth - 14, y: 0, width: labelWidth, height: fullHeight)

        let trackX = currentLabel.frame.maxX + 8
        let trackWidth = max(1, durationLabel.frame.minX - trackX - 8)
        trackView.frame = CGRect(x: trackX, y: (fullHeight - 6) / 2, width: trackWidth, height: 6)
        trackView.layer.cornerRadius = 3
        bufferView.frame = progressFrame(maxTime: bufferedTime, in: trackView.bounds)
        progressView.frame = progressFrame(maxTime: currentTime, in: trackView.bounds)

        collapsedTrack.frame = CGRect(x: 16, y: bounds.height - 4, width: bounds.width - 32, height: 2)
        collapsedProgress.frame = progressFrame(maxTime: currentTime, in: collapsedTrack.bounds)
    }

    private func setup() {
        addSubview(glassContainer)
        glassContainer.contentView.addSubview(glassView)
        addSubview(collapsedTrack)
        collapsedTrack.addSubview(collapsedProgress)
        glassView.contentView.addSubview(currentLabel)
        glassView.contentView.addSubview(durationLabel)
        glassView.contentView.addSubview(trackView)
        trackView.addSubview(bufferView)
        trackView.addSubview(progressView)
        addGestureRecognizer(panGesture)

        [currentLabel, durationLabel].forEach {
            $0.textColor = .white
            $0.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        durationLabel.textAlignment = .right
        trackView.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        bufferView.backgroundColor = UIColor.white.withAlphaComponent(0.36)
        progressView.backgroundColor = .white
        collapsedTrack.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        collapsedProgress.backgroundColor = .white
        [trackView, bufferView, progressView, collapsedTrack, collapsedProgress].forEach {
            $0.layer.masksToBounds = true
            $0.layer.cornerRadius = max(1, $0.bounds.height / 2)
        }
        collapsedTrack.alpha = 0
        collapsedProgress.alpha = 0
    }

    private func setCollapsed(_ collapsed: Bool, animated: Bool) {
        let changes = {
            self.glassContainer.alpha = collapsed ? 0 : 1
            self.glassContainer.transform = collapsed ? CGAffineTransform(translationX: 0, y: 12).scaledBy(x: 0.98, y: 0.98) : .identity
            self.collapsedTrack.alpha = 0
            self.collapsedProgress.alpha = 0
        }
        if animated {
            UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseInOut, .allowUserInteraction], animations: changes)
        } else {
            changes()
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
