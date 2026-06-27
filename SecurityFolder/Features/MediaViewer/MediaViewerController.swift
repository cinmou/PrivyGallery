import AVFoundation
import UIKit

final class MediaViewerController: UIViewController {
    let items: [VaultItem]
    let provider: MediaAssetProvider
    let initialItemID: UUID
    var protectsMediaContentFromCapture = false
    var onDismiss: (() -> Void)?
    var onShowDetails: ((VaultItem) -> Void)?
    var detailInfo: ((VaultItem) -> MediaItemDetailInfo?)?
    var exportURL: ((VaultItem) -> URL?)?

    private let pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    private let topOverlay = MediaTopOverlayView()
    private let bottomScrubber = MediaScrubberUIKitView()
    private let playbackControls = UIStackView()
    private let rewindButton = MediaGlassIconButton(frame: .zero)
    private let centerButton = MediaGlassIconButton(frame: .zero)
    private let forwardButton = MediaGlassIconButton(frame: .zero)
    private let rateButton = MediaGlassIconButton(frame: .zero)
    private let fastForwardLabel = MediaGlassLabel()
    private let detailBackdrop = UIControl()
    private let detailPanel = MediaDetailPanelView()
    private let privacyOverlay = UIView()
    /// Non-interactive badge shown below the close button for Live Photo items.
    private let livePhotoBadge = MediaGlassIconButton(frame: .zero)

    private var pageCache: [UUID: MediaPageController] = [:]
    private var currentPage: MediaPageController?
    private var currentIndex: Int
    private var controlsVisible = true
    private var hideControlsWorkItem: DispatchWorkItem?
    private var isScrubbing = false
    private var isMenuVisible = false
    private var isDetailVisible = false
    private var isFastForwarding = false
    private var isRenderingControls = false
    private var isKeyboardPaging = false
    private var pointerPanInitialTime: Double?
    private var secureOverlayTapRecognizer: UITapGestureRecognizer?
    private weak var pointerPanRecognizer: UIPanGestureRecognizer?
    private var captureObserver: NSObjectProtocol?

    init(items: [VaultItem], initialItemID: UUID, provider: MediaAssetProvider) {
        self.items = items
        self.initialItemID = initialItemID
        self.provider = provider
        self.currentIndex = items.firstIndex { $0.id == initialItemID } ?? 0
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersStatusBarHidden: Bool { true }
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: String(localized: "快退 15 秒"), action: #selector(keySkipBackward), input: UIKeyCommand.inputLeftArrow, modifierFlags: []),
            UIKeyCommand(title: String(localized: "快进 15 秒"), action: #selector(keySkipForward), input: UIKeyCommand.inputRightArrow, modifierFlags: []),
            UIKeyCommand(title: String(localized: "播放/暂停"), action: #selector(keyTogglePlayPause), input: " ", modifierFlags: []),
            UIKeyCommand(title: String(localized: "关闭"), action: #selector(keyClose), input: UIKeyCommand.inputEscape, modifierFlags: [])
        ]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        configurePages()
        configureOverlay()
        configureGestures()
        configureCaptureProtectionIfNeeded()
        showInitialPage()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first,
              press.key?.modifierFlags.isEmpty != false else {
            super.pressesBegan(presses, with: event)
            return
        }

        switch press.type {
        case .leftArrow:
            keySkipBackward()
        case .rightArrow:
            keySkipForward()
        default:
            super.pressesBegan(presses, with: event)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cleanupAllPages()
        removeCaptureObserver()
    }

    private func configurePages() {
        addChild(pageController)
        view.addSubview(pageController.view)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pageController.didMove(toParent: self)
        pageController.dataSource = self
        pageController.delegate = self
        #if targetEnvironment(macCatalyst)
        for case let scrollView as UIScrollView in pageController.view.subviews {
            scrollView.panGestureRecognizer.allowedScrollTypesMask = .all
        }
        #endif
    }

    private func configureOverlay() {
        topOverlay.closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        topOverlay.moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
        view.addSubview(topOverlay)
        view.addSubview(bottomScrubber)
        view.addSubview(playbackControls)
        view.addSubview(rateButton)
        view.addSubview(fastForwardLabel)
        view.addSubview(detailBackdrop)
        view.addSubview(detailPanel)
        view.addSubview(privacyOverlay)

        playbackControls.axis = .horizontal
        playbackControls.alignment = .center
        playbackControls.distribution = .equalSpacing
        playbackControls.spacing = 30
        playbackControls.addArrangedSubview(rewindButton)
        playbackControls.addArrangedSubview(centerButton)
        playbackControls.addArrangedSubview(forwardButton)

        configurePlaybackButton(rewindButton, systemImage: "gobackward.15", size: 70, pointSize: 31)
        configurePlaybackButton(centerButton, systemImage: "play.fill", size: 96, pointSize: 44)
        configurePlaybackButton(forwardButton, systemImage: "goforward.15", size: 70, pointSize: 31)
        rewindButton.addTarget(self, action: #selector(rewindTapped), for: .touchUpInside)
        forwardButton.addTarget(self, action: #selector(forwardTapped), for: .touchUpInside)
        centerButton.addTarget(self, action: #selector(centerButtonTapped), for: .touchUpInside)
        rewindButton.accessibilityLabel = String(localized: "快退 15 秒")
        forwardButton.accessibilityLabel = String(localized: "快进 15 秒")

        centerButton.tintColor = .white
        rateButton.tintColor = .white
        rateButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        rateButton.setTitle("1x", for: .normal)
        rateButton.accessibilityLabel = String(localized: "倍速")
        rateButton.addTarget(self, action: #selector(rateTapped), for: .touchUpInside)

        fastForwardLabel.text = "2x"
        fastForwardLabel.textColor = .white
        fastForwardLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        fastForwardLabel.textAlignment = .center
        fastForwardLabel.alpha = 0
        fastForwardLabel.layer.shadowColor = UIColor.black.cgColor
        fastForwardLabel.layer.shadowOpacity = 0.55
        fastForwardLabel.layer.shadowRadius = 3
        fastForwardLabel.layer.shadowOffset = CGSize(width: 0, height: 1)

        detailBackdrop.backgroundColor = UIColor.black.withAlphaComponent(0.34)
        detailBackdrop.alpha = 0
        detailBackdrop.isHidden = true
        detailBackdrop.addTarget(self, action: #selector(hideDetailPanelTapped), for: .touchUpInside)
        detailPanel.alpha = 0
        detailPanel.isHidden = true

        privacyOverlay.backgroundColor = .black
        privacyOverlay.alpha = 0
        privacyOverlay.isHidden = true
        privacyOverlay.isUserInteractionEnabled = false

        livePhotoBadge.setImage(UIImage(systemName: "livephoto"), for: .normal)
        livePhotoBadge.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold), forImageIn: .normal
        )
        livePhotoBadge.isUserInteractionEnabled = false
        livePhotoBadge.alpha = 0
        view.addSubview(livePhotoBadge)

        bottomScrubber.allowsSeeking = provider.supportsSecureSeeking
        bottomScrubber.onScrubBegan = { [weak self] in
            self?.isScrubbing = true
            self?.showControls(lock: true)
        }
        bottomScrubber.onScrubChanged = { [weak self] time in
            self?.currentPage?.previewScrubTime(time)
        }
        bottomScrubber.onScrubEnded = { [weak self] time in
            guard let self else { return }
            self.isScrubbing = false
            self.currentPage?.seek(to: time)
            self.scheduleHideControlsIfNeeded(reset: true)
        }
    }

    private func configureGestures() {
        if protectsMediaContentFromCapture {
            let secureTap = UITapGestureRecognizer(target: self, action: #selector(secureOverlayTapped))
            secureTap.cancelsTouchesInView = false
            secureTap.delegate = self
            view.addGestureRecognizer(secureTap)
            secureOverlayTapRecognizer = secureTap
        }

        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(showDetailPanelGesture))
        swipeUp.direction = .up
        swipeUp.cancelsTouchesInView = false
        view.addGestureRecognizer(swipeUp)

        #if !targetEnvironment(macCatalyst)
        let pointerPan = UIPanGestureRecognizer(target: self, action: #selector(pointerPanGesture(_:)))
        pointerPan.maximumNumberOfTouches = 1
        pointerPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pointerPan.allowedScrollTypesMask = []
        pointerPan.cancelsTouchesInView = false
        pointerPan.delegate = self
        view.addGestureRecognizer(pointerPan)
        pointerPanRecognizer = pointerPan
        #endif

        if !provider.supportsSecureSeeking, items.count == 1 {
            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(secureHorizontalDismissGesture))
                swipe.direction = direction
                swipe.cancelsTouchesInView = false
                view.addGestureRecognizer(swipe)
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        topOverlay.frame = CGRect(x: 12, y: safe.top + 8, width: view.bounds.width - 24, height: 48)
        // Position the Live Photo badge directly below the close button (top-left),
        // aligned with the left edge of the top overlay.
        livePhotoBadge.frame = CGRect(x: 12, y: topOverlay.frame.maxY + 8, width: 36, height: 36)
        rateButton.frame = CGRect(x: 14 + safe.left, y: view.bounds.height - safe.bottom - 60, width: 64, height: 42)
        bottomScrubber.frame = CGRect(x: rateButton.frame.maxX + 10, y: view.bounds.height - safe.bottom - 61, width: view.bounds.width - rateButton.frame.maxX - safe.right - 24, height: 50)
        // Keep the center play/pause button square so the glass background remains a true circle in both layouts.
        let controlsWidth: CGFloat = provider.supportsSecureSeeking ? 304 : 96
        playbackControls.frame = CGRect(x: (view.bounds.width - controlsWidth) / 2, y: (view.bounds.height - 96) / 2, width: controlsWidth, height: 96)
        fastForwardLabel.frame = CGRect(x: view.bounds.width - safe.right - 82, y: safe.top + 64, width: 66, height: 40)
        detailBackdrop.frame = view.bounds
        privacyOverlay.frame = view.bounds
        let panelWidth = min(view.bounds.width - 32, 430)
        let panelHeight = min(view.bounds.height - safe.top - safe.bottom - 80, 460)
        detailPanel.frame = CGRect(
            x: (view.bounds.width - panelWidth) / 2,
            y: view.bounds.height - safe.bottom - panelHeight - 20,
            width: panelWidth,
            height: panelHeight
        )
    }

    private func configurePlaybackButton(_ button: UIButton, systemImage: String, size: CGFloat, pointSize: CGFloat) {
        button.tintColor = .white
        button.backgroundColor = .clear
        button.setImage(UIImage(systemName: systemImage), for: .normal)
        button.setPreferredSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold), forImageIn: .normal)
        button.imageView?.contentMode = .center
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        button.widthAnchor.constraint(equalToConstant: size).isActive = true
        button.heightAnchor.constraint(equalToConstant: size).isActive = true
        button.widthAnchor.constraint(equalTo: button.heightAnchor).isActive = true
    }

    private func showInitialPage() {
        guard let page = page(for: currentIndex) else { return }
        pageController.setViewControllers([page], direction: .forward, animated: false)
        activate(page, revealControls: true)
    }

    private func page(for index: Int) -> MediaPageController? {
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        if let cached = pageCache[item.id] {
            return cached
        }
        let page = MediaPageController(item: item, provider: provider, protectsContentFromCapture: protectsMediaContentFromCapture)
        page.onTap = { [weak self] in self?.toggleControls() }
        page.onDismiss = { [weak self] in self?.closeTapped() }
        page.onPlaybackStateChanged = { [weak self, weak page] in
            guard let self, page === self.currentPage else { return }
            self.renderCurrentPlaybackState(scheduleAutoHide: true)
        }
        page.onFastForwardChanged = { [weak self] active, rate in
            self?.setFastForwardIndicator(active: active, rate: rate)
        }
        pageCache[item.id] = page
        return page
    }

    private func activate(_ page: MediaPageController, revealControls: Bool) {
        currentPage?.setActive(false)
        currentPage = page
        currentIndex = items.firstIndex(of: page.item) ?? currentIndex
        page.setActive(true)
        topOverlay.update(title: page.item.name, subtitle: items.count > 1 ? "\(currentIndex + 1) / \(items.count)" : nil)
        renderCurrentPlaybackState(scheduleAutoHide: false)
        // Instantly reflect whether the new item is a Live Photo (no animation so
        // the badge appears in sync with the page change, not after a fade delay).
        livePhotoBadge.alpha = (controlsVisible && isLivePhotoItem(page.item)) ? 1 : 0
        if revealControls {
            showControls(lock: false)
        } else if controlsVisible {
            scheduleHideControlsIfNeeded(reset: true)
        }
    }

    private func configureCaptureProtectionIfNeeded() {
        guard protectsMediaContentFromCapture else { return }
        updateCapturePrivacyOverlay(animated: false)
        captureObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCapturePrivacyOverlay(animated: true)
        }
    }

    private func removeCaptureObserver() {
        if let captureObserver {
            NotificationCenter.default.removeObserver(captureObserver)
        }
        captureObserver = nil
    }

    private func updateCapturePrivacyOverlay(animated: Bool) {
        guard protectsMediaContentFromCapture else { return }
        let shouldHideContent = UIScreen.main.isCaptured
        privacyOverlay.isHidden = false
        privacyOverlay.isUserInteractionEnabled = shouldHideContent
        let changes = {
            self.privacyOverlay.alpha = shouldHideContent ? 1 : 0
        }
        let completion: (Bool) -> Void = { _ in
            self.privacyOverlay.isHidden = !shouldHideContent
            self.privacyOverlay.isUserInteractionEnabled = shouldHideContent
        }
        if animated {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseInOut, .allowUserInteraction], animations: changes, completion: completion)
        } else {
            changes()
            completion(true)
        }
    }

    private func renderCurrentPlaybackState(scheduleAutoHide: Bool) {
        guard !isRenderingControls else { return }
        isRenderingControls = true
        defer { isRenderingControls = false }
        guard let page = currentPage else { return }
        let state = page.videoState
        let isVideo = page.item.mediaKind == .video
        playbackControls.isHidden = !isVideo
        rateButton.isHidden = !isVideo
        rewindButton.isHidden = !provider.supportsSecureSeeking
        forwardButton.isHidden = !provider.supportsSecureSeeking
        let centerImage = state.didFinish ? "arrow.clockwise" : (state.isPlaying ? "pause.fill" : "play.fill")
        centerButton.setImage(UIImage(systemName: centerImage), for: .normal)
        centerButton.accessibilityLabel = state.isPlaying ? String(localized: "暂停") : String(localized: "播放")
        rateButton.setTitle(rateTitle(state.playbackRate), for: .normal)
        bottomScrubber.isHidden = !isVideo
        if !bottomScrubber.isTrackingUserScrub {
            bottomScrubber.update(
                currentTime: state.currentTime,
                duration: state.duration,
                bufferedTime: state.bufferedTime,
                collapsed: !controlsVisible,
                animated: true
            )
        }
        let shouldShowPlaybackControls = isVideo && controlsVisible
        playbackControls.alpha = shouldShowPlaybackControls ? 1 : 0
        rateButton.alpha = shouldShowPlaybackControls ? 1 : 0
        playbackControls.transform = shouldShowPlaybackControls ? .identity : CGAffineTransform(scaleX: 0.86, y: 0.86)
        rateButton.transform = shouldShowPlaybackControls ? .identity : CGAffineTransform(translationX: 0, y: 6)

        guard scheduleAutoHide else { return }
        scheduleHideControlsIfNeeded(reset: false)
    }

    private func toggleControls() {
        controlsVisible ? hideControls() : showControls(lock: false)
    }

    private func showControls(lock: Bool) {
        hideControlsWorkItem?.cancel()
        hideControlsWorkItem = nil
        controlsVisible = true
        renderControlsVisibility(animated: true)
        if !lock {
            scheduleHideControlsIfNeeded(reset: true)
        }
    }

    private func hideControls() {
        hideControlsWorkItem?.cancel()
        hideControlsWorkItem = nil
        if currentPage?.item.mediaKind == .video {
            guard !isScrubbing, !isMenuVisible, !isDetailVisible, !isFastForwarding else { return }
        } else {
            guard !isMenuVisible, !isDetailVisible else { return }
        }
        controlsVisible = false
        renderControlsVisibility(animated: true)
    }

    private func renderControlsVisibility(animated: Bool) {
        let visible = controlsVisible
        let showBadge = visible && isLivePhotoItem(currentPage?.item)
        let changes = {
            self.topOverlay.alpha = visible ? 1 : 0
            self.bottomScrubber.alpha = visible ? 1 : 0
            self.playbackControls.alpha = visible ? 1 : 0
            self.rateButton.alpha = visible ? 1 : 0
            self.livePhotoBadge.alpha = showBadge ? 1 : 0
            self.bottomScrubber.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 8)
            self.playbackControls.transform = visible ? .identity : CGAffineTransform(scaleX: 0.86, y: 0.86)
            self.rateButton.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 6)
        }
        if animated {
            UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseInOut, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
        renderCurrentPlaybackState(scheduleAutoHide: false)
    }

    private func scheduleHideControlsIfNeeded(reset: Bool = false) {
        guard controlsVisible else { return }
        if reset {
            hideControlsWorkItem?.cancel()
            hideControlsWorkItem = nil
        } else if hideControlsWorkItem != nil {
            return
        }
        guard currentPage != nil, !isScrubbing, !isMenuVisible, !isDetailVisible, !isFastForwarding else { return }
        let item = DispatchWorkItem { [weak self] in self?.hideControls() }
        hideControlsWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    private func setFastForwardIndicator(active: Bool, rate: Double) {
        isFastForwarding = active
        fastForwardLabel.text = rateTitle(rate)
        showControls(lock: active)
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            self.fastForwardLabel.alpha = active ? 1 : 0
            self.fastForwardLabel.transform = active ? .identity : CGAffineTransform(scaleX: 0.86, y: 0.86)
        }
    }

    private func rateTitle(_ rate: Double) -> String {
        let rounded = (rate * 10).rounded() / 10
        if abs(rounded.rounded() - rounded) < 0.05 {
            return "\(Int(rounded.rounded()))x"
        }
        return "\(rounded)x"
    }

    /// Returns `true` only when the item is a Live Photo with a companion video on disk.
    /// Used to decide whether to show the Live Photo indicator badge.
    private func isLivePhotoItem(_ item: VaultItem?) -> Bool {
        item?.mediaKind == .livePhoto && item?.livePhotoCompanionRelativePath != nil
    }

    private func cleanupAllPages() {
        hideControlsWorkItem?.cancel()
        hideControlsWorkItem = nil
        pageCache.values.forEach { $0.cleanup() }
        removeCaptureObserver()
    }

    @objc private func closeTapped() {
        cleanupAllPages()
        onDismiss?()
    }

    @objc private func moreTapped() {
        guard let item = currentPage?.item else { return }
        isMenuVisible = true
        showControls(lock: true)
        let sheet = UIAlertController(title: item.name, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: String(localized: "显示详情"), style: .default) { [weak self] _ in
            self?.isMenuVisible = false
            self?.scheduleHideControlsIfNeeded(reset: true)
            self?.showDetailPanel(for: item)
        })
        if exportURL?(item) != nil {
            sheet.addAction(UIAlertAction(title: String(localized: "导出"), style: .default) { [weak self] _ in
                guard let self, let url = self.exportURL?(item) else { return }
                self.isMenuVisible = false
                self.scheduleHideControlsIfNeeded(reset: true)
                let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                self.present(activity, animated: true)
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel) { [weak self] _ in
            self?.isMenuVisible = false
            self?.scheduleHideControlsIfNeeded(reset: true)
        })
        sheet.view.tintColor = .systemBlue
        // NOTE: do not set `sheet.presentationController?.delegate` — UIKit forbids
        // modifying a UIAlertController's presentation-controller delegate and
        // aborts ("...must not have its delegate modified"). The cancel action
        // already resets `isMenuVisible` when the sheet is dismissed.
        // On iPad / Mac Catalyst an action sheet is presented as a popover and
        // requires an anchor; without one UIKit throws and the app crashes.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = topOverlay.moreButton
            popover.sourceRect = topOverlay.moreButton.bounds
            popover.permittedArrowDirections = .up
        }
        present(sheet, animated: true)
    }

    @objc private func centerButtonTapped() {
        currentPage?.togglePlayback()
    }

    @objc private func rateTapped() {
        currentPage?.cyclePlaybackRate()
        showControls(lock: false)
    }

    @objc private func rewindTapped() {
        currentPage?.skip(by: -15)
        showControls(lock: false)
    }

    @objc private func forwardTapped() {
        currentPage?.skip(by: 15)
        showControls(lock: false)
    }

    @objc private func showDetailPanelGesture() {
        guard let item = currentPage?.item else { return }
        showDetailPanel(for: item)
    }

    @objc private func hideDetailPanelTapped() {
        hideDetailPanel()
    }

    @objc private func secureHorizontalDismissGesture() {
        guard !provider.supportsSecureSeeking else { return }
        closeTapped()
    }

    @objc private func secureOverlayTapped() {
        toggleControls()
    }

    @objc private func pointerPanGesture(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            guard controlsVisible,
                  currentPage?.item.mediaKind == .video,
                  provider.supportsSecureSeeking else {
                pointerPanInitialTime = nil
                return
            }
            pointerPanInitialTime = currentPage?.videoState.currentTime
            showControls(lock: true)
        case .changed:
            guard let page = currentPage,
                  page.item.mediaKind == .video,
                  provider.supportsSecureSeeking,
                  let pointerPanInitialTime else { return }
            let duration = max(page.videoState.duration, 0)
            let delta = Double(translation.x / max(view.bounds.width, 1)) * duration
            page.previewScrubTime(min(max(pointerPanInitialTime + delta, 0), duration))
        case .ended, .cancelled, .failed:
            defer {
                pointerPanInitialTime = nil
                if controlsVisible {
                    scheduleHideControlsIfNeeded(reset: true)
                }
            }
            guard abs(translation.x) > 50 || abs(translation.y) > 50 else { return }
            if abs(translation.x) > abs(translation.y) {
                if let page = currentPage, page.item.mediaKind == .video, provider.supportsSecureSeeking, let pointerPanInitialTime {
                    let duration = max(page.videoState.duration, 0)
                    let delta = Double(translation.x / max(view.bounds.width, 1)) * duration
                    page.seek(to: min(max(pointerPanInitialTime + delta, 0), duration))
                } else if !provider.supportsSecureSeeking, items.count == 1 {
                    closeTapped()
                }
            } else if translation.y < 0 {
                showDetailPanelGesture()
            } else {
                closeTapped()
            }
        default:
            break
        }
    }

    private func showDetailPanel(for item: VaultItem) {
        guard let info = detailInfo?(item) else {
            onShowDetails?(item)
            return
        }
        hideControlsWorkItem?.cancel()
        isDetailVisible = true
        controlsVisible = true
        renderControlsVisibility(animated: true)
        detailPanel.configure(with: info)
        detailBackdrop.isHidden = false
        detailPanel.isHidden = false
        detailPanel.transform = CGAffineTransform(translationX: 0, y: 22)
        UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            self.detailBackdrop.alpha = 1
            self.detailPanel.alpha = 1
            self.detailPanel.transform = .identity
        }
    }

    private func hideDetailPanel() {
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            self.detailBackdrop.alpha = 0
            self.detailPanel.alpha = 0
            self.detailPanel.transform = CGAffineTransform(translationX: 0, y: 18)
        } completion: { _ in
            self.detailBackdrop.isHidden = true
            self.detailPanel.isHidden = true
            self.detailPanel.transform = .identity
            self.isDetailVisible = false
            self.scheduleHideControlsIfNeeded(reset: true)
        }
    }

    @objc private func keyTogglePlayPause() {
        currentPage?.togglePlayback()
        showControls(lock: false)
    }

    @objc private func keySkipBackward() {
        if shouldArrowKeysSeekCurrentItem {
            currentPage?.skip(by: -15)
            showControls(lock: false)
        } else {
            showAdjacentPage(offset: -1)
        }
    }

    @objc private func keySkipForward() {
        if shouldArrowKeysSeekCurrentItem {
            currentPage?.skip(by: 15)
            showControls(lock: false)
        } else {
            showAdjacentPage(offset: 1)
        }
    }

    private var shouldArrowKeysSeekCurrentItem: Bool {
        currentPage?.item.mediaKind == .video && provider.supportsSecureSeeking
    }

    private func showAdjacentPage(offset: Int) {
        guard !isKeyboardPaging else { return }
        let nextIndex = currentIndex + offset
        guard items.indices.contains(nextIndex),
              let page = page(for: nextIndex) else { return }
        isKeyboardPaging = true
        let direction: UIPageViewController.NavigationDirection = offset < 0 ? .reverse : .forward
        pageController.setViewControllers([page], direction: direction, animated: true) { [weak self, weak page] finished in
            guard let self else { return }
            self.isKeyboardPaging = false
            guard finished, let page else { return }
            self.activate(page, revealControls: false)
        }
    }

    @objc private func keyClose() {
        closeTapped()
    }
}

extension MediaViewerController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        isMenuVisible = false
        scheduleHideControlsIfNeeded(reset: true)
    }
}

extension MediaViewerController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === pointerPanRecognizer {
            return touch.type == .direct
        }

        guard gestureRecognizer === secureOverlayTapRecognizer else { return true }
        guard let touchedView = touch.view else { return true }
        let ignoredControls = [topOverlay, playbackControls, rateButton, bottomScrubber, detailPanel, detailBackdrop]
        return !ignoredControls.contains { touchedView.isDescendant(of: $0) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPanGestureRecognizer
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // While an image is zoomed in, let its scroll view own panning so a mouse
        // or touch left/right drag pans the image instead of being captured by the
        // viewer's pointer-pan (dismiss / scrub) recognizer.
        if gestureRecognizer === pointerPanRecognizer, currentPage?.isImageZoomed == true {
            return false
        }
        return true
    }
}

extension MediaViewerController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? MediaPageController,
              let index = items.firstIndex(of: page.item) else { return nil }
        return self.page(for: index - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? MediaPageController,
              let index = items.firstIndex(of: page.item) else { return nil }
        return self.page(for: index + 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let page = pageViewController.viewControllers?.first as? MediaPageController else { return }
        previousViewControllers.compactMap { $0 as? MediaPageController }.forEach { $0.setActive(false) }
        activate(page, revealControls: false)
    }
}

final class MediaTopOverlayView: UIView {
    let closeButton = MediaGlassIconButton(frame: .zero)
    let moreButton = MediaGlassIconButton(frame: .zero)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let titleContainer = MediaGlassContainerView()
    private let titleGlassView = MediaGlassView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, subtitle: String?) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle == nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let buttonSize: CGFloat = min(44, bounds.height)
        closeButton.frame = CGRect(x: 0, y: (bounds.height - buttonSize) / 2, width: buttonSize, height: buttonSize)
        moreButton.frame = CGRect(x: bounds.width - buttonSize, y: (bounds.height - buttonSize) / 2, width: buttonSize, height: buttonSize)

        let spacing: CGFloat = 12
        let maxTitleWidth = max(120, bounds.width - buttonSize * 2 - spacing * 4)
        let titleWidth = min(maxTitleWidth, max(150, intrinsicTitleWidth + 28))
        titleContainer.frame = CGRect(x: (bounds.width - titleWidth) / 2, y: (bounds.height - 44) / 2, width: titleWidth, height: 44)
        titleGlassView.frame = titleContainer.bounds
        titleGlassView.update(cornerRadius: 22, isDark: true, tintStyle: .panel, isInteractive: false)

        let labelFrame = CGRect(x: 14, y: 4, width: titleContainer.bounds.width - 28, height: titleContainer.bounds.height - 8)
        titleLabel.frame = subtitleLabel.isHidden ? labelFrame : CGRect(x: labelFrame.minX, y: 5, width: labelFrame.width, height: 21)
        subtitleLabel.frame = CGRect(x: labelFrame.minX, y: 25, width: labelFrame.width, height: 16)
    }

    private func setup() {
        addSubview(closeButton)
        addSubview(titleContainer)
        addSubview(moreButton)
        titleContainer.contentView.addSubview(titleGlassView)
        titleGlassView.contentView.addSubview(titleLabel)
        titleGlassView.contentView.addSubview(subtitleLabel)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        closeButton.accessibilityLabel = String(localized: "关闭")
        moreButton.accessibilityLabel = String(localized: "更多")
        [closeButton, moreButton].forEach { $0.tintColor = .white }
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        subtitleLabel.textAlignment = .center
    }

    private var intrinsicTitleWidth: CGFloat {
        let titleWidth = (titleLabel.text ?? "").size(withAttributes: [.font: titleLabel.font as Any]).width
        let subtitleWidth = (subtitleLabel.text ?? "").size(withAttributes: [.font: subtitleLabel.font as Any]).width
        return max(titleWidth, subtitleLabel.isHidden ? 0 : subtitleWidth)
    }
}

final class MediaDetailPanelView: UIView {
    private let glassContainer = MediaGlassContainerView()
    private let glassView = MediaGlassView()
    private let titleLabel = UILabel()
    private let stackView = UIStackView()
    private let byteFormatter = ByteCountFormatter()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with detail: MediaItemDetailInfo) {
        titleLabel.text = detail.title
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        addRow(title: String(localized: "类型"), value: detail.mediaKindTitle)
        addRow(title: String(localized: "文件名"), value: detail.originalFilename)
        addRow(title: String(localized: "文件类型"), value: detail.contentTypeIdentifier)
        addRow(title: String(localized: "大小"), value: byteFormatter.string(fromByteCount: detail.byteCount))
        addRow(title: String(localized: "导入时间"), value: dateFormatter.string(from: detail.importedAt))
        if let originalCapturedAt = detail.originalCapturedAt {
            addRow(title: String(localized: "拍摄时间"), value: dateFormatter.string(from: originalCapturedAt))
        }
        if let lastExportedAt = detail.lastExportedAt {
            addRow(title: String(localized: "上次导出"), value: dateFormatter.string(from: lastExportedAt))
        }
        if let latitude = detail.locationLatitude, let longitude = detail.locationLongitude {
            addRow(title: String(localized: "位置"), value: "\(latitude), \(longitude)")
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassContainer.frame = bounds
        glassView.frame = glassContainer.bounds
        glassView.update(cornerRadius: 28, isDark: true, tintStyle: .panel, isInteractive: true)
        let inset: CGFloat = 22
        titleLabel.frame = CGRect(x: inset, y: 20, width: bounds.width - inset * 2, height: 34)
        stackView.frame = CGRect(x: inset, y: titleLabel.frame.maxY + 18, width: bounds.width - inset * 2, height: bounds.height - titleLabel.frame.maxY - 36)
    }

    private func setup() {
        overrideUserInterfaceStyle = .dark
        backgroundColor = UIColor(white: 0.07, alpha: 0.88)
        layer.cornerRadius = 28
        layer.cornerCurve = .continuous
        clipsToBounds = true
        byteFormatter.allowedUnits = [.useKB, .useMB, .useGB]
        byteFormatter.countStyle = .file
        addSubview(glassContainer)
        glassContainer.contentView.addSubview(glassView)
        glassView.contentView.addSubview(titleLabel)
        glassView.contentView.addSubview(stackView)
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 21, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        stackView.axis = .vertical
        stackView.spacing = 14
        stackView.alignment = .fill
        stackView.distribution = .fill
    }

    private func addRow(title: String, value: String) {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 14
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.68)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.widthAnchor.constraint(equalToConstant: 104).isActive = true
        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.textColor = .white
        valueLabel.font = .systemFont(ofSize: 15, weight: .regular)
        valueLabel.numberOfLines = 3
        valueLabel.lineBreakMode = .byTruncatingMiddle
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(valueLabel)
        stackView.addArrangedSubview(row)
    }
}
