import Foundation
import Photos
import UIKit

nonisolated struct ExportedMediaItem: Sendable {
    let stillURL: URL
    let companionVideoURL: URL?
    let mediaKind: MediaKind

    var isLivePhoto: Bool {
        companionVideoURL != nil
    }

    var allURLs: [URL] {
        if let companionVideoURL {
            return [stillURL, companionVideoURL]
        }
        return [stillURL]
    }
}

enum MediaExportSupport {
    nonisolated static func companionExportFilename(for originalFilename: String, companionRelativePath: String) -> String {
        let baseName = URL(fileURLWithPath: originalFilename).deletingPathExtension().lastPathComponent
        let companionExt = URL(fileURLWithPath: companionRelativePath).pathExtension
        let ext = companionExt.isEmpty ? "mov" : companionExt
        let stem = baseName.isEmpty ? "LivePhoto" : baseName
        return "\(stem).\(ext)"
    }

    static func applicationActivities(for items: [ExportedMediaItem]) -> [UIActivity]? {
        guard items.contains(where: \.isLivePhoto) else { return nil }
        return [SaveToPhotosLibraryActivity(items: items)]
    }

    static func excludedActivityTypes(for items: [ExportedMediaItem]) -> [UIActivity.ActivityType]? {
        guard items.contains(where: \.isLivePhoto) else { return nil }
        // System "Save Image / Save N Items" splits paired HEIC + MOV URLs into a still photo
        // plus a separate video. Replace it with SaveToPhotosLibraryActivity (PHAssetCreationRequest).
        return [.saveToCameraRoll]
    }
}

enum SystemPhotoLibraryExportService {
    static func save(_ items: [ExportedMediaItem]) async -> Bool {
        guard !items.isEmpty else { return false }
        let authorized = await ensurePhotoLibraryAuthorization()
        guard authorized else { return false }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                for item in items {
                    let request = PHAssetCreationRequest.forAsset()
                    if let companionVideoURL = item.companionVideoURL {
                        let photoOptions = PHAssetResourceCreationOptions()
                        photoOptions.originalFilename = item.stillURL.lastPathComponent
                        request.addResource(with: .photo, fileURL: item.stillURL, options: photoOptions)

                        let videoOptions = PHAssetResourceCreationOptions()
                        videoOptions.originalFilename = companionVideoURL.lastPathComponent
                        request.addResource(with: .pairedVideo, fileURL: companionVideoURL, options: videoOptions)
                    } else if item.mediaKind == .video {
                        let videoOptions = PHAssetResourceCreationOptions()
                        videoOptions.originalFilename = item.stillURL.lastPathComponent
                        request.addResource(with: .video, fileURL: item.stillURL, options: videoOptions)
                    } else {
                        let photoOptions = PHAssetResourceCreationOptions()
                        photoOptions.originalFilename = item.stillURL.lastPathComponent
                        request.addResource(with: .photo, fileURL: item.stillURL, options: photoOptions)
                    }
                }
            }) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    private static func ensurePhotoLibraryAuthorization() async -> Bool {
        let addStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if addStatus == .authorized {
            return true
        }
        let readWriteStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch readWriteStatus {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return newStatus == .authorized || newStatus == .limited
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

final class SaveToPhotosLibraryActivity: UIActivity {
    private let items: [ExportedMediaItem]

    init(items: [ExportedMediaItem]) {
        self.items = items
        super.init()
    }

    override class var activityCategory: UIActivity.Category {
        .action
    }

    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType("com.cinmouice.MediaVault.saveToPhotosLibrary")
    }

    override var activityTitle: String? {
        String(localized: "存储到相册")
    }

    override var activityImage: UIImage? {
        UIImage(systemName: "square.and.arrow.down")
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        !items.isEmpty
    }

    override func perform() {
        let itemsToSave = items
        Task {
            let success = await SystemPhotoLibraryExportService.save(itemsToSave)
            await MainActor.run {
                self.activityDidFinish(success)
            }
        }
    }
}
