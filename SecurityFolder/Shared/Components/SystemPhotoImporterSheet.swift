import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct SystemPhotoImporterSheet: UIViewControllerRepresentable {
    static let systemPhotoImporterDirectoryName = "SystemPhotoImporter"
    static let livePhotoImportDirectoryPrefix = "LivePhotoImport-"

    let selectionLimit: Int
    let onComplete: ([ImportedPickerAsset]) -> Void

    static func cleanupTemporaryFiles(for assets: [ImportedPickerAsset]) {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.standardizedFileURL.path(percentEncoded: false)
        for asset in assets {
            removeTemporaryItem(at: asset.fileURL, fileManager: fileManager, tempRoot: tempRoot)
            if let companionURL = asset.companionVideoURL {
                removeTemporaryItem(at: companionURL, fileManager: fileManager, tempRoot: tempRoot)
            }
        }
    }

    static func cleanupAllTemporaryDirectories() {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let importerDir = tempDir.appendingPathComponent(systemPhotoImporterDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: importerDir.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: importerDir)
        }
        if let entries = try? fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix(livePhotoImportDirectoryPrefix) {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private static func removeTemporaryItem(at url: URL, fileManager: FileManager, tempRoot: String) {
        let standardized = url.standardizedFileURL
        let rootPrefix = tempRoot.hasSuffix("/") ? tempRoot : tempRoot + "/"
        guard standardized.path(percentEncoded: false).hasPrefix(rootPrefix) else { return }
        try? fileManager.removeItem(at: standardized)
        let parent = standardized.deletingLastPathComponent()
        let normalizedTempRoot = tempRoot.hasSuffix("/") ? String(tempRoot.dropLast()) : tempRoot
        let parentContainer = parent.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
        let normalizedParentContainer = parentContainer.hasSuffix("/") ? String(parentContainer.dropLast()) : parentContainer
        if parent.lastPathComponent.hasPrefix(livePhotoImportDirectoryPrefix),
           normalizedParentContainer == normalizedTempRoot {
            let contents = (try? fileManager.contentsOfDirectory(atPath: parent.path(percentEncoded: false))) ?? []
            if contents.isEmpty {
                try? fileManager.removeItem(at: parent)
            }
        }
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = selectionLimit
        configuration.filter = .any(of: [.images, .videos])
        configuration.preferredAssetRepresentationMode = .current

        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: SystemPhotoImporterSheet
        private var loadTask: Task<Void, Never>?
        private var lockObserver: NSObjectProtocol?

        init(parent: SystemPhotoImporterSheet) {
            self.parent = parent
        }

        deinit {
            loadTask?.cancel()
            if let lockObserver {
                NotificationCenter.default.removeObserver(lockObserver)
            }
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            loadTask?.cancel()
            if let lockObserver {
                NotificationCenter.default.removeObserver(lockObserver)
                self.lockObserver = nil
            }
            lockObserver = NotificationCenter.default.addObserver(
                forName: .vaultDidLock,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.loadTask?.cancel()
                SystemPhotoImporterSheet.cleanupAllTemporaryDirectories()
            }

            loadTask = Task { [weak self] in
                guard let self else { return }
                let assets = await self.loadImportedAssets(from: results)
                await MainActor.run {
                    if let observer = self.lockObserver {
                        NotificationCenter.default.removeObserver(observer)
                        self.lockObserver = nil
                    }
                    self.loadTask = nil
                    if Task.isCancelled {
                        SystemPhotoImporterSheet.cleanupTemporaryFiles(for: assets)
                        return
                    }
                    self.parent.onComplete(assets)
                }
            }
        }

        // MARK: - Asset loading

        private func loadImportedAssets(from results: [PHPickerResult]) async -> [ImportedPickerAsset] {
            var importedAssets: [ImportedPickerAsset] = []

            for (index, result) in results.enumerated() {
                if Task.isCancelled {
                    SystemPhotoImporterSheet.cleanupTemporaryFiles(for: importedAssets)
                    return []
                }
                let fallbackName = "Imported Media \(index + 1)"

                // ── Live Photo: authoritative PHAsset-level detection ──────────────────────
                // A HEIC still on its own is not a Live Photo. Check PHAsset first when
                // Photos authorization is available, then fall back to loading PHLivePhoto
                // directly from the picker's NSItemProvider (which works without Photos permission).
                if let assetID = result.assetIdentifier,
                   let asset = fetchPHAsset(withIdentifier: assetID),
                   asset.mediaSubtypes.contains(.photoLive) {
                    if let pickerAsset = await extractLivePhotoAsset(
                        asset: asset,
                        result: result,
                        fallbackName: fallbackName
                    ) {
                        importedAssets.append(pickerAsset)
                        continue
                    }
                }

                if result.itemProvider.canLoadObject(ofClass: PHLivePhoto.self) {
                    if let pickerAsset = await extractLivePhotoFromItemProvider(
                        result.itemProvider,
                        assetIdentifier: result.assetIdentifier,
                        fallbackName: fallbackName
                    ) {
                        importedAssets.append(pickerAsset)
                        continue
                    }
                }

                // ── Regular photo or video ───────────────────────────────────────────────
                let identifiers = result.itemProvider.registeredTypeIdentifiers
                guard let contentType = preferredMediaContentType(from: identifiers) else {
                    continue
                }
                guard let fileURL = await loadFileURL(
                    from: result.itemProvider,
                    contentType: contentType,
                    fallbackName: fallbackName
                ) else {
                    continue
                }

                importedAssets.append(ImportedPickerAsset(
                    fileURL: fileURL,
                    contentType: contentType,
                    fallbackName: fallbackName,
                    assetIdentifier: result.assetIdentifier,
                    companionVideoURL: nil
                ))
            }

            return importedAssets
        }

        // MARK: - Live Photo extraction

        /// Fetch the PHAsset behind a picker result's asset identifier.
        /// Returns nil when Photos authorization is unavailable or the identifier
        /// is no longer in the library (asset deleted after picker was presented).
        private func fetchPHAsset(withIdentifier identifier: String) -> PHAsset? {
            PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        }

        /// Export the still image and paired video from a Live Photo asset using
        /// PHAssetResourceManager. Returns nil if either resource cannot be written.
        private func extractLivePhotoAsset(
            asset: PHAsset,
            result: PHPickerResult,
            fallbackName: String
        ) async -> ImportedPickerAsset? {
            let resources = PHAssetResource.assetResources(for: asset)
            return await extractLivePhoto(
                from: resources,
                assetIdentifier: result.assetIdentifier,
                fallbackName: fallbackName
            )
        }

        /// Extract still image + paired video from a picker NSItemProvider without
        /// requiring Photos library authorization.
        private func extractLivePhotoFromItemProvider(
            _ provider: NSItemProvider,
            assetIdentifier: String?,
            fallbackName: String
        ) async -> ImportedPickerAsset? {
            await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: PHLivePhoto.self) { object, _ in
                    guard let livePhoto = object as? PHLivePhoto else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let resources = PHAssetResource.assetResources(for: livePhoto)
                    Self.writeLivePhotoResources(
                        resources,
                        assetIdentifier: assetIdentifier,
                        fallbackName: fallbackName
                    ) { asset in
                        continuation.resume(returning: asset)
                    }
                }
            }
        }

        private func extractLivePhoto(
            from resources: [PHAssetResource],
            assetIdentifier: String?,
            fallbackName: String
        ) async -> ImportedPickerAsset? {
            await withCheckedContinuation { continuation in
                Self.writeLivePhotoResources(
                    resources,
                    assetIdentifier: assetIdentifier,
                    fallbackName: fallbackName
                ) { asset in
                    continuation.resume(returning: asset)
                }
            }
        }

        nonisolated private static func matchedLivePhotoResources(
            from resources: [PHAssetResource]
        ) -> (still: PHAssetResource, video: PHAssetResource)? {
            // Keep edited pairs together so content identifiers and trim ranges match.
            if let editedStill = resources.first(where: { $0.type == .fullSizePhoto }),
               let editedVideo = resources.first(where: { $0.type == .fullSizePairedVideo }) {
                return (editedStill, editedVideo)
            }
            if let originalStill = resources.first(where: { $0.type == .photo }),
               let originalVideo = resources.first(where: { $0.type == .pairedVideo }) {
                return (originalStill, originalVideo)
            }
            if let still = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }),
               let video = resources.first(where: { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }) {
                return (still, video)
            }
            return nil
        }

        nonisolated private static func writeLivePhotoResources(
            _ resources: [PHAssetResource],
            assetIdentifier: String?,
            fallbackName: String,
            completion: @escaping @Sendable (ImportedPickerAsset?) -> Void
        ) {
            guard let pair = matchedLivePhotoResources(from: resources) else {
                completion(nil)
                return
            }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("LivePhotoImport-\(UUID().uuidString)", isDirectory: true)
            guard (try? FileManager.default.createDirectory(
                at: tempDir, withIntermediateDirectories: true
            )) != nil else {
                completion(nil)
                return
            }

            let stillExt = URL(fileURLWithPath: pair.still.originalFilename).pathExtension.lowercased()
            let videoExt = URL(fileURLWithPath: pair.video.originalFilename).pathExtension.lowercased()

            let stillURL = tempDir.appendingPathComponent(
                "\(UUID().uuidString).\(stillExt.isEmpty ? "heic" : stillExt)"
            )
            let videoURL = tempDir.appendingPathComponent(
                "\(UUID().uuidString).\(videoExt.isEmpty ? "mov" : videoExt)"
            )
            let preferredName = pair.still.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedFallbackName = preferredName.isEmpty ? fallbackName : preferredName

            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: pair.still, toFile: stillURL, options: options) { stillError in
                if stillError != nil {
                    try? FileManager.default.removeItem(at: tempDir)
                    completion(nil)
                    return
                }
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: stillURL.path(percentEncoded: false)
                )
                PHAssetResourceManager.default().writeData(for: pair.video, toFile: videoURL, options: options) { videoError in
                    if videoError != nil {
                        try? FileManager.default.removeItem(at: tempDir)
                        completion(nil)
                        return
                    }
                    try? FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.complete],
                        ofItemAtPath: videoURL.path(percentEncoded: false)
                    )
                    let contentType = UTType(filenameExtension: stillURL.pathExtension) ?? .jpeg
                    completion(ImportedPickerAsset(
                        fileURL: stillURL,
                        contentType: contentType,
                        fallbackName: resolvedFallbackName,
                        assetIdentifier: assetIdentifier,
                        companionVideoURL: videoURL
                    ))
                }
            }
        }

        // MARK: - Item-provider helpers (used for regular photos and videos)

        /// Returns the preferred UTType for the item: image types take priority
        /// over movie types so that a Live Photo is represented by its still
        /// image in the fallback path rather than its companion clip.
        private func preferredMediaContentType(from identifiers: [String]) -> UTType? {
            for identifier in identifiers {
                guard let type = UTType(identifier), type.conforms(to: .image) else { continue }
                return type
            }
            for identifier in identifiers {
                guard let type = UTType(identifier), type.conforms(to: .movie) else { continue }
                return type
            }
            return nil
        }

        private func loadFileURL(
            from itemProvider: NSItemProvider,
            contentType: UTType,
            fallbackName: String
        ) async -> URL? {
            await withCheckedContinuation { continuation in
                itemProvider.loadFileRepresentation(forTypeIdentifier: contentType.identifier) { sourceURL, _ in
                    guard let sourceURL else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let tempDirectory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("SystemPhotoImporter", isDirectory: true)
                    do {
                        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                        let targetURL = tempDirectory
                            .appendingPathComponent(UUID().uuidString + "-" + fallbackName)
                            .appendingPathExtension(contentType.preferredFilenameExtension ?? sourceURL.pathExtension)

                        if FileManager.default.fileExists(atPath: targetURL.path()) {
                            try FileManager.default.removeItem(at: targetURL)
                        }
                        try FileManager.default.copyItem(at: sourceURL, to: targetURL)
                        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: targetURL.path(percentEncoded: false))
                        continuation.resume(returning: targetURL)
                    } catch {
                        print("[SystemPhotoImporterSheet] Failed to copy picked file: \(error)")
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}
