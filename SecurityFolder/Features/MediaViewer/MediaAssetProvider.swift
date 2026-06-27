import AVFoundation
import Foundation
import UIKit
import UniformTypeIdentifiers

protocol MediaAssetProvider: AnyObject {
    var supportsSecureSeeking: Bool { get }
    func image(for item: VaultItem) async throws -> UIImage
    func videoPlayer(for item: VaultItem) async throws -> MediaVideoPlayer
    func cleanup(item: VaultItem)
}

struct MediaVideoPlayer {
    let player: AVPlayer
    let retainedSource: AnyObject?
}

final class PlainMediaAssetProvider: MediaAssetProvider {
    let supportsSecureSeeking = true

    func image(for item: VaultItem) async throws -> UIImage {
        let url = try VaultFileStorageService.shared.decryptedTemporaryURL(
            for: item.relativePath,
            originalFilename: item.originalFilename,
            space: item.space
        )
        if let image = UIImage(contentsOfFile: url.path()) {
            return image
        }
        guard let image = MediaThumbnailService.shared.previewImage(for: item) else {
            throw MediaAssetError.unreadableImage
        }
        return image
    }

    func videoPlayer(for item: VaultItem) async throws -> MediaVideoPlayer {
        let url = try VaultFileStorageService.shared.decryptedTemporaryURL(
            for: item.relativePath,
            originalFilename: item.originalFilename,
            space: item.space
        )
        return MediaVideoPlayer(player: AVPlayer(url: url), retainedSource: nil)
    }

    func cleanup(item: VaultItem) {
        VaultFileStorageService.shared.clearDecryptedTemporaryFile(for: item.relativePath)
    }
}

final class SecureMediaAssetProvider: MediaAssetProvider {
    let supportsSecureSeeking = false

    func image(for item: VaultItem) async throws -> UIImage {
        let data = try VaultFileStorageService.shared.decryptedData(for: item.relativePath, space: item.space)
        guard let image = UIImage(data: data) else {
            throw MediaAssetError.unreadableImage
        }
        return image
    }

    func videoPlayer(for item: VaultItem) async throws -> MediaVideoPlayer {
        guard let contentType = UTType(item.contentTypeIdentifier) else {
            throw MediaAssetError.unsupportedVideo
        }
        let data = try VaultFileStorageService.shared.decryptedData(for: item.relativePath, space: item.space)
        let source = InMemoryVideoSource(data: data, contentType: contentType)
        return MediaVideoPlayer(player: source.player, retainedSource: source)
    }

    func cleanup(item: VaultItem) {}
}

enum MediaAssetError: Error {
    case unreadableImage
    case unsupportedVideo
}

final class InMemoryVideoSource: NSObject, AVAssetResourceLoaderDelegate {
    let player: AVPlayer

    private let data: Data
    private let contentType: UTType
    private let asset: AVURLAsset
    private let queue = DispatchQueue(label: "SecurityFolder.MediaViewer.InMemoryVideoSource")

    init(data: Data, contentType: UTType) {
        self.data = data
        self.contentType = contentType
        let ext = contentType.preferredFilenameExtension ?? "mov"
        let url = URL(string: "secure-memory-video://\(UUID().uuidString).\(ext)")!
        self.asset = AVURLAsset(url: url)
        self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType.identifier
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }

        guard let request = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let offset = Int(request.currentOffset > 0 ? request.currentOffset : request.requestedOffset)
        guard offset >= 0, offset < data.count else {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
            return false
        }

        let length = min(request.requestedLength, data.count - offset)
        request.respond(with: data.subdata(in: offset..<(offset + length)))
        loadingRequest.finishLoading()
        return true
    }
}
