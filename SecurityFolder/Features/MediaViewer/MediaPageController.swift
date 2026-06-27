import AVFoundation
import Photos
import PhotosUI
import UIKit

struct VideoPlaybackState {
    var isPlaying = false
    var didFinish = false
    var currentTime: Double = 0
    var duration: Double = 0
    var bufferedTime: Double = 0
    var playbackRate: Double = 1
}

final class MediaPageController: UIViewController {
    let item: VaultItem
    var onTap: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onPlaybackStateChanged: (() -> Void)?
    var onFastForwardChanged: ((Bool, Double) -> Void)?

    private let provider: MediaAssetProvider
    private let protectsContentFromCapture: Bool
    private var imageController: ImagePageController?
    private var videoController: VideoPageController?
    private var livePhotoController: LivePhotoPageController?
    private var secureContentHost: SecureMediaContentHostView?
    private var loadTask: Task<Void, Never>?
    private var isActive = false

    var videoState: VideoPlaybackState {
        videoController?.state ?? VideoPlaybackState()
    }

    /// True when the hosted still image is zoomed in (so left/right drag should pan it).
    var isImageZoomed: Bool {
        imageController?.isZoomed ?? false
    }

    init(item: VaultItem, provider: MediaAssetProvider, protectsContentFromCapture: Bool = false) {
        self.item = item
        self.provider = provider
        self.protectsContentFromCapture = protectsContentFromCapture
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        load()
    }

    func setActive(_ active: Bool) {
        isActive = active
        videoController?.setActive(active)
    }

    func handleViewerTap() {
        if item.mediaKind == .video {
            onTap?()
        } else {
            imageController?.handleViewerTap()
            livePhotoController?.handleViewerTap()
        }
    }

    func togglePlayback() {
        videoController?.togglePlayback()
    }

    func cyclePlaybackRate() {
        videoController?.cyclePlaybackRate()
    }

    func previewScrubTime(_ time: Double) {
        videoController?.previewScrubTime(time)
    }

    func seek(to time: Double) {
        guard provider.supportsSecureSeeking else { return }
        videoController?.seek(to: time)
    }

    func skip(by delta: Double) {
        guard provider.supportsSecureSeeking else { return }
        videoController?.skip(by: delta)
    }

    func cleanup() {
        loadTask?.cancel()
        videoController?.cleanup()
        provider.cleanup(item: item)
        if let companionPath = item.livePhotoCompanionRelativePath {
            VaultFileStorageService.shared.clearDecryptedTemporaryFile(for: companionPath)
        }
    }

    private func load() {
        switch item.mediaKind {
        case .photo:
            let child = ImagePageController()
            child.onTap = onTap
            child.onDismiss = onDismiss
            embed(child)
            imageController = child
            loadTask = Task { [weak self, weak child] in
                guard let self else { return }
                do {
                    let image = try await provider.image(for: item)
                    await MainActor.run { child?.setImage(image) }
                } catch {
                    await MainActor.run { child?.showFailure() }
                }
            }
        case .video:
            let child = VideoPageController()
            child.allowsSeeking = provider.supportsSecureSeeking
            child.onTap = onTap
            child.onPlaybackStateChanged = onPlaybackStateChanged
            child.onFastForwardChanged = onFastForwardChanged
            embed(child)
            videoController = child
            loadTask = Task { [weak self, weak child] in
                guard let self else { return }
                do {
                    let mediaPlayer = try await provider.videoPlayer(for: item)
                    await MainActor.run {
                        child?.configure(player: mediaPlayer.player, retainedSource: mediaPlayer.retainedSource)
                        child?.setActive(self.isActive)
                    }
                } catch {
                    await MainActor.run { child?.showFailure() }
                }
            }
        case .livePhoto:
            let child = LivePhotoPageController()
            child.onTap = onTap
            child.onDismiss = onDismiss
            embed(child)
            livePhotoController = child
            loadTask = Task { [weak self, weak child] in
                guard let self else { return }
                do {
                    let livePhoto = try await self.loadLivePhoto(for: self.item)
                    await MainActor.run { child?.setLivePhoto(livePhoto) }
                } catch {
                    // Fall back to displaying the still image if Live Photo loading fails.
                    do {
                        let image = try await self.provider.image(for: self.item)
                        await MainActor.run { child?.setFallbackImage(image) }
                    } catch {
                        await MainActor.run { child?.showFailure() }
                    }
                }
            }
        }
    }

    private func loadLivePhoto(for item: VaultItem) async throws -> PHLivePhoto {
        let stillURL = try VaultFileStorageService.shared.decryptedTemporaryURL(
            for: item.relativePath,
            originalFilename: item.originalFilename,
            space: item.space
        )
        guard let companionPath = item.livePhotoCompanionRelativePath else {
            throw MediaAssetError.unreadableImage
        }
        let companionFilename = URL(fileURLWithPath: companionPath).lastPathComponent
        let videoURL = try VaultFileStorageService.shared.decryptedTemporaryURL(
            for: companionPath,
            originalFilename: companionFilename,
            space: item.space
        )
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            PHLivePhoto.request(
                withResourceFileURLs: [stillURL, videoURL],
                placeholderImage: nil,
                targetSize: .zero,
                contentMode: .aspectFit
            ) { livePhoto, info in
                guard !hasResumed else { return }
                // Skip degraded placeholder; wait for the full-quality result.
                if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
                hasResumed = true
                if let livePhoto {
                    continuation.resume(returning: livePhoto)
                } else {
                    continuation.resume(throwing: MediaAssetError.unreadableImage)
                }
            }
        }
    }

    private func embed(_ child: UIViewController) {
        addChild(child)
        if protectsContentFromCapture {
            let secureHost = SecureMediaContentHostView()
            secureHost.frame = view.bounds
            secureHost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(secureHost)
            secureHost.embed(child.view)
            secureContentHost = secureHost
        } else {
            view.addSubview(child.view)
            child.view.frame = view.bounds
            child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        child.didMove(toParent: self)
    }
}

// MARK: - Live Photo page

final class LivePhotoPageController: UIViewController {
    var onTap: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let livePhotoView = PHLivePhotoView()
    private let fallbackImageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black

        fallbackImageView.contentMode = .scaleAspectFit
        fallbackImageView.backgroundColor = .black
        fallbackImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        fallbackImageView.frame = view.bounds
        view.addSubview(fallbackImageView)

        livePhotoView.backgroundColor = .black
        livePhotoView.contentMode = .scaleAspectFit
        livePhotoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(livePhotoView)
        NSLayoutConstraint.activate([
            livePhotoView.topAnchor.constraint(equalTo: view.topAnchor),
            livePhotoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            livePhotoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            livePhotoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        spinner.color = .white
        spinner.startAnimating()
        view.addSubview(spinner)

        // Long press → start/stop Live Photo playback.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.35
        view.addGestureRecognizer(longPress)

        // Single tap → toggle viewer controls. Must wait for the long press to fail
        // so that releasing after a long press doesn't also fire a tap, matching
        // the same pattern used by VideoPageController.
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: longPress)
        view.addGestureRecognizer(singleTap)

        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(dismissGesture))
        swipeDown.direction = .down
        view.addGestureRecognizer(swipeDown)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        spinner.center = view.center
        fallbackImageView.frame = view.bounds
    }

    func setLivePhoto(_ livePhoto: PHLivePhoto) {
        spinner.stopAnimating()
        livePhotoView.livePhoto = livePhoto
        livePhotoView.isHidden = false
        fallbackImageView.isHidden = true
    }

    /// Called when the Live Photo cannot be loaded; shows the still image instead.
    func setFallbackImage(_ image: UIImage) {
        spinner.stopAnimating()
        fallbackImageView.image = image
        fallbackImageView.isHidden = false
        livePhotoView.isHidden = true
    }

    func showFailure() {
        spinner.stopAnimating()
    }

    func handleViewerTap() {
        onTap?()
    }

    @objc private func singleTapped() {
        onTap?()
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        // Only drive playback when a Live Photo has been loaded successfully.
        guard livePhotoView.livePhoto != nil else { return }
        switch gesture.state {
        case .began:
            livePhotoView.startPlayback(with: .full)
        case .ended, .cancelled, .failed:
            livePhotoView.stopPlayback()
        default:
            break
        }
    }

    @objc private func dismissGesture() {
        onDismiss?()
    }
}

// MARK: - Secure content host

private final class SecureMediaContentHostView: UIView {
    private let secureTextField = SecureCanvasTextField()
    private weak var secureCanvas: UIView?
    private weak var contentView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        secureTextField.isSecureTextEntry = true
        secureTextField.backgroundColor = .black
        secureTextField.textColor = .clear
        secureTextField.tintColor = .clear
        addSubview(secureTextField)
        secureCanvas = secureCanvasView(in: secureTextField) ?? secureTextField
        secureCanvas?.backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func embed(_ view: UIView) {
        contentView?.removeFromSuperview()
        contentView = view
        view.backgroundColor = .black
        secureCanvas?.addSubview(view)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        secureTextField.frame = bounds
        secureCanvas?.frame = bounds
        contentView?.frame = bounds
        contentView?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    private func secureCanvasView(in textField: UITextField) -> UIView? {
        textField.subviews.first {
            let className = NSStringFromClass(type(of: $0))
            return className.contains("Canvas") || className.contains("Layout")
        }
    }
}

final class ImagePageController: UIViewController, UIScrollViewDelegate {
    var onTap: (() -> Void)?
    var onDismiss: (() -> Void)?

    /// True when the image is zoomed past its fitted scale, i.e. panning is meaningful.
    var isZoomed: Bool { scrollView.zoomScale > 1.01 }

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        scrollView.delegate = self
        scrollView.backgroundColor = .black
        imageView.backgroundColor = .black
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        #if targetEnvironment(macCatalyst)
        updateCatalystScrollTypes(isZoomed: false)
        #endif
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)
        view.addSubview(scrollView)
        spinner.color = .white
        spinner.startAnimating()
        view.addSubview(spinner)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(dismissGesture))
        swipeDown.direction = .down
        view.addGestureRecognizer(swipeDown)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        imageView.frame = scrollView.bounds
        spinner.center = view.center
    }

    func setImage(_ image: UIImage) {
        spinner.stopAnimating()
        imageView.image = image
        imageView.frame = scrollView.bounds
        scrollView.zoomScale = 1
        #if targetEnvironment(macCatalyst)
        updateCatalystScrollTypes(isZoomed: false)
        #endif
    }

    func showFailure() {
        spinner.stopAnimating()
    }

    func handleViewerTap() {
        onTap?()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        // While zoomed in, hand horizontal drags to the image (pan) instead of
        // the page controller (swipe to the next item). This is what makes a
        // mouse / touch left-right drag pan the zoomed preview.
        setEnclosingPagingEnabled(scrollView.zoomScale <= 1.01)
        #if targetEnvironment(macCatalyst)
        updateCatalystScrollTypes(isZoomed: scrollView.zoomScale > 1.01)
        #endif
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        setEnclosingPagingEnabled(scale <= 1.01)
        #if targetEnvironment(macCatalyst)
        updateCatalystScrollTypes(isZoomed: scale > 1.01)
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private func updateCatalystScrollTypes(isZoomed: Bool) {
        scrollView.panGestureRecognizer.allowedScrollTypesMask = isZoomed ? .all : .continuous
    }
    #endif

    /// Keep the image centered in the scroll view when it is smaller than the
    /// viewport in a given axis, so panning a zoomed image feels natural.
    private func centerImage() {
        let boundsSize = scrollView.bounds.size
        var frame = imageView.frame
        frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
        imageView.frame = frame
    }

    /// Walk up the view-controller chain to the hosting UIPageViewController and
    /// enable/disable its paging scroll so it doesn't compete with image panning.
    private func setEnclosingPagingEnabled(_ enabled: Bool) {
        var ancestor: UIViewController? = parent
        while let current = ancestor {
            if let pageVC = current as? UIPageViewController {
                for case let pagingScroll as UIScrollView in pageVC.view.subviews {
                    pagingScroll.isScrollEnabled = enabled
                }
                return
            }
            ancestor = current.parent
        }
    }

    @objc private func singleTapped() {
        onTap?()
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.05 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
            let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
            scrollView.zoom(to: rect, animated: true)
        }
    }

    @objc private func dismissGesture() {
        onDismiss?()
    }
}

final class VideoPageController: UIViewController {
    var onTap: (() -> Void)?
    var onPlaybackStateChanged: (() -> Void)?
    var onFastForwardChanged: ((Bool, Double) -> Void)?
    var allowsSeeking = true

    private let playerLayer = AVPlayerLayer()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var player: AVPlayer?
    private var retainedSource: AnyObject?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var wasPlayingBeforeFastForward = false
    private var rateBeforeFastForward: Float = 1
    private var isFastForwarding = false
    private var isRewinding = false
    private var fastForwardStartPoint: CGPoint?
    private var longPressSide: PlaybackEdge?
    private var rewindTimer: Timer?
    private var basePlaybackRate: Float = 1
    private var isActive = false
    private var isScrubbing = false

    private(set) var state = VideoPlaybackState() {
        didSet { onPlaybackStateChanged?() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        view.layer.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
        spinner.color = .white
        spinner.startAnimating()
        view.addSubview(spinner)

        let tap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        view.addGestureRecognizer(tap)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.35
        tap.require(toFail: longPress)
        view.addGestureRecognizer(longPress)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer.frame = view.bounds
        spinner.center = view.center
    }

    func configure(player: AVPlayer, retainedSource: AnyObject?) {
        cleanup()
        self.player = player
        self.retainedSource = retainedSource
        playerLayer.player = player
        spinner.stopAnimating()
        addObservers()
        updateDuration()
        if isActive {
            play()
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            if state.isPlaying {
                player?.playImmediately(atRate: basePlaybackRate)
            } else if state.currentTime == 0 {
                play()
            }
        } else {
            pause()
        }
    }

    func togglePlayback() {
        if state.didFinish {
            seek(to: 0)
            state.didFinish = false
            play()
        } else if state.isPlaying {
            pause()
        } else {
            play()
        }
    }

    func previewScrubTime(_ time: Double) {
        isScrubbing = true
        state.currentTime = time
    }

    func seek(to time: Double) {
        guard let player else { return }
        isScrubbing = false
        let target = min(max(time, 0), max(state.duration, 0))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        state.currentTime = target
        if state.duration > 0, target >= state.duration - 0.05 {
            player.pause()
            state.isPlaying = false
            state.didFinish = true
        } else {
            state.didFinish = false
            if state.isPlaying {
                player.playImmediately(atRate: basePlaybackRate)
            }
        }
    }

    func skip(by delta: Double) {
        seek(to: state.currentTime + delta)
    }

    func cyclePlaybackRate() {
        let rates: [Float] = [0.5, 1, 1.5, 2]
        let nextRate = rates.first { $0 > basePlaybackRate + 0.01 } ?? 1
        basePlaybackRate = nextRate
        state.playbackRate = Double(nextRate)
        if state.isPlaying, !isFastForwarding {
            player?.rate = nextRate
        }
    }

    func cleanup() {
        endEdgeGesture()
        player?.pause()
        removeObservers()
        playerLayer.player = nil
        player = nil
        retainedSource = nil
        state = VideoPlaybackState()
    }

    func showFailure() {
        spinner.stopAnimating()
    }

    private func play() {
        guard isActive else { return }
        state.isPlaying = true
        state.playbackRate = Double(basePlaybackRate)
        player?.playImmediately(atRate: basePlaybackRate)
    }

    private func pause() {
        endEdgeGesture()
        player?.pause()
        state.isPlaying = false
    }

    private func addObservers() {
        guard let player else { return }
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self else { return }
            self.updateDuration()
            self.updateBufferedTime()
            guard !self.isScrubbing else { return }
            self.state.currentTime = time.seconds.isFinite ? time.seconds : 0
            self.state.isPlaying = player.timeControlStatus == .playing
            self.state.playbackRate = Double(self.isFastForwarding ? (player.rate == 0 ? self.basePlaybackRate : player.rate) : self.basePlaybackRate)
            if self.state.duration > 0, self.state.currentTime < self.state.duration - 0.2 {
                self.state.didFinish = false
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.endEdgeGesture()
            self.state.isPlaying = false
            self.state.didFinish = true
            self.updateDuration()
            self.state.currentTime = self.state.duration
        }
    }

    private func removeObservers() {
        if let timeObserverToken, let player {
            player.removeTimeObserver(timeObserverToken)
        }
        timeObserverToken = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    private func updateDuration() {
        let duration = player?.currentItem?.duration.seconds ?? 0
        state.duration = duration.isFinite ? duration : 0
    }

    private func updateBufferedTime() {
        guard let range = player?.currentItem?.loadedTimeRanges.first?.timeRangeValue else {
            state.bufferedTime = 0
            return
        }
        let buffered = range.start.seconds + range.duration.seconds
        state.bufferedTime = buffered.isFinite ? buffered : 0
    }

    private func beginFastForward() {
        guard state.isPlaying, !state.didFinish, !isFastForwarding, !isRewinding else { return }
        wasPlayingBeforeFastForward = state.isPlaying
        rateBeforeFastForward = basePlaybackRate
        isFastForwarding = true
        player?.rate = 3
        state.playbackRate = 3
        onFastForwardChanged?(true, 3)
    }

    private func endFastForward() {
        guard isFastForwarding else { return }
        isFastForwarding = false
        fastForwardStartPoint = nil
        if wasPlayingBeforeFastForward {
            player?.rate = rateBeforeFastForward
        }
        state.playbackRate = Double(basePlaybackRate)
        onFastForwardChanged?(false, Double(rateBeforeFastForward))
    }

    private func beginRewind() {
        guard allowsSeeking, state.isPlaying, !state.didFinish, !isFastForwarding, !isRewinding else { return }
        wasPlayingBeforeFastForward = state.isPlaying
        rateBeforeFastForward = basePlaybackRate
        isRewinding = true
        player?.rate = 0
        onFastForwardChanged?(true, -2)
        rewindTimer?.invalidate()
        rewindTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            self?.skip(by: -1.2)
        }
    }

    private func endRewind() {
        guard isRewinding else { return }
        isRewinding = false
        rewindTimer?.invalidate()
        rewindTimer = nil
        fastForwardStartPoint = nil
        if wasPlayingBeforeFastForward {
            player?.playImmediately(atRate: rateBeforeFastForward)
        }
        state.playbackRate = Double(basePlaybackRate)
        onFastForwardChanged?(false, Double(rateBeforeFastForward))
    }

    private func endEdgeGesture() {
        endFastForward()
        endRewind()
    }

    @objc private func singleTapped() {
        onTap?()
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            fastForwardStartPoint = gesture.location(in: view)
            longPressSide = (fastForwardStartPoint?.x ?? 0) < view.bounds.midX ? .left : .right
            switch longPressSide {
            case .left:
                beginRewind()
            case .right:
                beginFastForward()
            case .none:
                break
            }
        case .changed:
            break
        case .ended, .cancelled, .failed:
            longPressSide = nil
            endEdgeGesture()
        default:
            break
        }
    }
}

private enum PlaybackEdge {
    case left
    case right
}
