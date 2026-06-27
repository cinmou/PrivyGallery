import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct SystemPhotoImporterSheet: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onComplete: ([ImportedPickerAsset]) -> Void

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

        init(parent: SystemPhotoImporterSheet) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            Task {
                let assets = await loadImportedAssets(from: results)
                await MainActor.run {
                    parent.onComplete(assets)
                }
            }
        }

        // MARK: - Asset loading

        private func loadImportedAssets(from results: [PHPickerResult]) async -> [ImportedPickerAsset] {
            var importedAssets: [ImportedPickerAsset] = []

            for (index, result) in results.enumerated() {
                let fallbackName = "导入媒体 \(index + 1)"

                // ── Live Photo: authoritative PHAsset-level detection ──────────────────────
                // A HEIC still on its own is not a Live Photo. The only reliable signal is
                // PHAsset.mediaSubtypes.contains(.photoLive). Check that first before
                // falling through to the item-provider path.
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
                    // PHAssetResourceManager write failed (e.g. iCloud not available,
                    // authorization revoked mid-session). Fall through and import as a
                    // plain still image so the user doesn't silently lose the item.
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

            // Prefer the primary resource over the full-size variant for edited assets.
            let stillResource = resources.first { $0.type == .photo }
                             ?? resources.first { $0.type == .fullSizePhoto }
            let videoResource = resources.first { $0.type == .pairedVideo }
                             ?? resources.first { $0.type == .fullSizePairedVideo }

            guard let stillResource, let videoResource else { return nil }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("LivePhotoImport-\(UUID().uuidString)", isDirectory: true)
            guard (try? FileManager.default.createDirectory(
                at: tempDir, withIntermediateDirectories: true
            )) != nil else { return nil }

            let stillExt = URL(fileURLWithPath: stillResource.originalFilename)
                .pathExtension.lowercased()
            let videoExt = URL(fileURLWithPath: videoResource.originalFilename)
                .pathExtension.lowercased()

            let stillURL = tempDir.appendingPathComponent(
                "\(UUID().uuidString).\(stillExt.isEmpty ? "heic" : stillExt)"
            )
            let videoURL = tempDir.appendingPathComponent(
                "\(UUID().uuidString).\(videoExt.isEmpty ? "mov" : videoExt)"
            )

            guard await writePHAssetResource(stillResource, to: stillURL) else {
                try? FileManager.default.removeItem(at: tempDir)
                return nil
            }
            guard await writePHAssetResource(videoResource, to: videoURL) else {
                try? FileManager.default.removeItem(at: tempDir)
                return nil
            }

            let contentType = UTType(filenameExtension: stillURL.pathExtension) ?? .jpeg
            return ImportedPickerAsset(
                fileURL: stillURL,
                contentType: contentType,
                fallbackName: fallbackName,
                assetIdentifier: result.assetIdentifier,
                companionVideoURL: videoURL
            )
        }

        /// Write a single PHAssetResource to a local file URL.
        /// `isNetworkAccessAllowed` is enabled so that iCloud-only assets are
        /// fetched from the network rather than failing silently.
        private func writePHAssetResource(
            _ resource: PHAssetResource,
            to url: URL
        ) async -> Bool {
            await withCheckedContinuation { continuation in
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                PHAssetResourceManager.default().writeData(
                    for: resource,
                    toFile: url,
                    options: options
                ) { error in
                    continuation.resume(returning: error == nil)
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
