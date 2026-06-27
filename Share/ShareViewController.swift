import AVFoundation
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let store = SharedImportStore.shared
    private var selectedSpace: SharedImportSpace = .spaceA
    private var supportedAttachments: [ShareAttachment] = []
    private var isSaving = false

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let previewScrollView = UIScrollView()
    private let previewStackView = UIStackView()
    private let destinationButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        selectedSpace = .spaceA
        supportedAttachments = inputAttachments().compactMap(ShareAttachment.init(provider:))
        configureView()
        normalizeSelectedSpace()
        refreshContent()
        loadPreviews()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        let rootStack = UIStackView()
        rootStack.axis = .vertical
        rootStack.spacing = 18
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        let headerStack = UIStackView()
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 12

        cancelButton.setTitle(String(localized: "取消"), for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        saveButton.setTitle(String(localized: "保存"), for: .normal)
        saveButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        let titleStack = UIStackView()
        titleStack.axis = .vertical
        titleStack.spacing = 4

        titleLabel.text = String(localized: "保存到 Privé Media")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textAlignment = .center

        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center

        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(subtitleLabel)

        headerStack.addArrangedSubview(cancelButton)
        headerStack.addArrangedSubview(titleStack)
        headerStack.addArrangedSubview(saveButton)
        cancelButton.widthAnchor.constraint(equalToConstant: 56).isActive = true
        saveButton.widthAnchor.constraint(equalToConstant: 56).isActive = true

        previewScrollView.showsHorizontalScrollIndicator = false
        previewScrollView.alwaysBounceHorizontal = true
        previewScrollView.translatesAutoresizingMaskIntoConstraints = false
        previewScrollView.heightAnchor.constraint(equalToConstant: 112).isActive = true

        previewStackView.axis = .horizontal
        previewStackView.alignment = .center
        previewStackView.spacing = 10
        previewStackView.translatesAutoresizingMaskIntoConstraints = false
        previewScrollView.addSubview(previewStackView)

        NSLayoutConstraint.activate([
            previewStackView.topAnchor.constraint(equalTo: previewScrollView.contentLayoutGuide.topAnchor),
            previewStackView.leadingAnchor.constraint(equalTo: previewScrollView.contentLayoutGuide.leadingAnchor),
            previewStackView.trailingAnchor.constraint(equalTo: previewScrollView.contentLayoutGuide.trailingAnchor),
            previewStackView.bottomAnchor.constraint(equalTo: previewScrollView.contentLayoutGuide.bottomAnchor),
            previewStackView.heightAnchor.constraint(equalTo: previewScrollView.frameLayoutGuide.heightAnchor)
        ])

        let destinationContainer = UIView()
        destinationContainer.backgroundColor = .secondarySystemGroupedBackground
        destinationContainer.layer.cornerRadius = 12
        destinationContainer.translatesAutoresizingMaskIntoConstraints = false
        destinationContainer.heightAnchor.constraint(equalToConstant: 52).isActive = true

        let destinationLabel = UILabel()
        destinationLabel.text = String(localized: "保存到")
        destinationLabel.font = .systemFont(ofSize: 16, weight: .medium)
        destinationLabel.translatesAutoresizingMaskIntoConstraints = false

        destinationButton.contentHorizontalAlignment = .right
        destinationButton.titleLabel?.font = .systemFont(ofSize: 16)
        destinationButton.addTarget(self, action: #selector(destinationTapped), for: .touchUpInside)
        destinationButton.translatesAutoresizingMaskIntoConstraints = false

        destinationContainer.addSubview(destinationLabel)
        destinationContainer.addSubview(destinationButton)

        NSLayoutConstraint.activate([
            destinationLabel.leadingAnchor.constraint(equalTo: destinationContainer.leadingAnchor, constant: 16),
            destinationLabel.centerYAnchor.constraint(equalTo: destinationContainer.centerYAnchor),
            destinationButton.leadingAnchor.constraint(greaterThanOrEqualTo: destinationLabel.trailingAnchor, constant: 12),
            destinationButton.trailingAnchor.constraint(equalTo: destinationContainer.trailingAnchor, constant: -16),
            destinationButton.centerYAnchor.constraint(equalTo: destinationContainer.centerYAnchor)
        ])

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        activityIndicator.hidesWhenStopped = true

        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(previewScrollView)
        rootStack.addArrangedSubview(destinationContainer)
        rootStack.addArrangedSubview(statusLabel)
        rootStack.addArrangedSubview(activityIndicator)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18)
        ])
    }

    private func refreshContent() {
        normalizeSelectedSpace()
        subtitleLabel.text = String.localizedStringWithFormat(String(localized: "%lld 个照片或视频"), Int64(supportedAttachments.count))
        destinationButton.setTitle(destinationTitle(), for: .normal)
        destinationButton.isEnabled = store.appState.availableSpaces.count > 1 && !isSaving
        saveButton.isEnabled = !supportedAttachments.isEmpty && !isSaving
        cancelButton.isEnabled = !isSaving

        if supportedAttachments.isEmpty {
            statusLabel.text = String(localized: "没有读取到可导入的照片或视频。")
        } else if supportedAttachments.count > SharedImportConstants.shareExtensionBatchLimit {
            statusLabel.text = String.localizedStringWithFormat(
                String(localized: "一次最多只能导入 %lld 个项目。"),
                Int64(SharedImportConstants.shareExtensionBatchLimit)
            )
        } else {
            statusLabel.text = store.appState.availableSpaces.count > 1
                ? String(localized: "请选择要保存的空间。")
                : String.localizedStringWithFormat(
                    String(localized: "将保存到 %@。"),
                    store.appState.displayName(for: .spaceA)
                )
        }
    }

    private func destinationTitle() -> String {
        let name = store.appState.displayName(for: selectedSpace)
        return store.appState.availableSpaces.count > 1 ? "\(name) 〉" : name
    }

    private func normalizeSelectedSpace() {
        guard store.appState.canUse(selectedSpace) else {
            selectedSpace = .spaceA
            return
        }
    }

    private func loadPreviews() {
        previewStackView.arrangedSubviews.forEach { view in
            previewStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for attachment in supportedAttachments.prefix(SharedImportConstants.shareExtensionBatchLimit) {
            let thumbnailView = ShareThumbnailView(isVideo: attachment.contentType.conforms(to: .movie))
            previewStackView.addArrangedSubview(thumbnailView)
            Task {
                let image = try? await attachment.loadThumbnail()
                await MainActor.run {
                    thumbnailView.imageView.image = image
                }
            }
        }
    }

    @objc private func destinationTapped() {
        guard store.appState.availableSpaces.count > 1 else { return }

        let alert = UIAlertController(title: String(localized: "保存到"), message: nil, preferredStyle: .actionSheet)
        for space in store.appState.availableSpaces {
            alert.addAction(
                UIAlertAction(title: store.appState.displayName(for: space), style: .default) { [weak self] _ in
                    self?.selectedSpace = space
                    self?.refreshContent()
                }
            )
        }
        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = destinationButton
            popover.sourceRect = destinationButton.bounds
        }

        present(alert, animated: true)
    }

    @objc private func cancelTapped() {
        extensionContext?.cancelRequest(withError: NSError(domain: "Share", code: NSUserCancelledError))
    }

    @objc private func saveTapped() {
        do {
            try store.validateCanAccept(itemCount: supportedAttachments.count, into: selectedSpace)
        } catch {
            presentError(error.localizedDescription)
            return
        }

        isSaving = true
        activityIndicator.startAnimating()
        refreshContent()

        Task {
            do {
                for attachment in supportedAttachments {
                    let savedURL = try await attachment.loadTemporaryFile()
                    try store.enqueueFile(
                        at: savedURL,
                        originalFilename: attachment.originalFilename,
                        contentType: attachment.contentType,
                        space: selectedSpace
                    )
                    try? FileManager.default.removeItem(at: savedURL)
                }
                await MainActor.run {
                    extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    activityIndicator.stopAnimating()
                    refreshContent()
                    presentError(error.localizedDescription)
                }
            }
        }
    }

    private func inputAttachments() -> [NSItemProvider] {
        extensionContext?
            .inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: String(localized: "无法保存"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "好"), style: .default))
        present(alert, animated: true)
    }
}

private final class ShareThumbnailView: UIView {
    let imageView = UIImageView()

    init(isVideo: Bool) {
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemGroupedBackground
        layer.cornerRadius = 12
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 104),
            heightAnchor.constraint(equalToConstant: 104),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        if isVideo {
            let badge = UIImageView(image: UIImage(systemName: "play.circle.fill"))
            badge.tintColor = .white
            badge.translatesAutoresizingMaskIntoConstraints = false
            addSubview(badge)
            NSLayoutConstraint.activate([
                badge.centerXAnchor.constraint(equalTo: centerXAnchor),
                badge.centerYAnchor.constraint(equalTo: centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: 30),
                badge.heightAnchor.constraint(equalToConstant: 30)
            ])
        }
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private struct ShareAttachment {
    let provider: NSItemProvider
    let typeIdentifier: String
    let contentType: UTType

    init?(provider: NSItemProvider) {
        guard let match = provider.registeredTypeIdentifiers
            .compactMap({ identifier -> (String, UTType)? in
                guard let type = UTType(identifier),
                      type.conforms(to: .image) || type.conforms(to: .movie) else {
                    return nil
                }
                return (identifier, type)
            })
            .first else {
            return nil
        }

        self.provider = provider
        self.typeIdentifier = match.0
        self.contentType = match.1
    }

    var originalFilename: String {
        let suggestedName = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let suggestedName, !suggestedName.isEmpty {
            let extensionName = URL(fileURLWithPath: suggestedName).pathExtension
            if !extensionName.isEmpty {
                return suggestedName
            }
            if let preferredExtension = contentType.preferredFilenameExtension {
                return "\(suggestedName).\(preferredExtension)"
            }
            return suggestedName
        }

        let fallbackExtension = contentType.preferredFilenameExtension ?? (contentType.conforms(to: .movie) ? "mov" : "jpg")
        return "Shared-\(UUID().uuidString).\(fallbackExtension)"
    }

    func loadTemporaryFile() async throws -> URL {
        let outputExtension = URL(fileURLWithPath: originalFilename).pathExtension
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let url else {
                    continuation.resume(throwing: SharedImportError.noReadableItems)
                    return
                }

                do {
                    var destinationURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                    if !outputExtension.isEmpty {
                        destinationURL.appendPathExtension(outputExtension)
                    }
                    if FileManager.default.fileExists(atPath: destinationURL.path()) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.copyItem(at: url, to: destinationURL)
                    continuation.resume(returning: destinationURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func loadThumbnail() async throws -> UIImage? {
        let url = try await loadTemporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        if contentType.conforms(to: .movie) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let cgImage: CGImage
            if #available(iOS 18.0, *) {
                cgImage = try await withCheckedThrowingContinuation { continuation in
                    generator.generateCGImageAsynchronously(for: .zero) { image, _, error in
                        if let image {
                            continuation.resume(returning: image)
                        } else {
                            continuation.resume(throwing: error ?? SharedImportError.noReadableItems)
                        }
                    }
                }
            } else {
                cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            }
            return UIImage(cgImage: cgImage)
        }

        return UIImage(contentsOfFile: url.path())
    }
}
