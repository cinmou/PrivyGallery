import AVFoundation
import Foundation
import ImageIO
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
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let url = try VaultFileStorageService.shared.decryptedTemporaryURL(
                for: item.relativePath,
                originalFilename: item.originalFilename,
                space: item.space
            )
            try Task.checkCancellation()
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let downsampled = MediaPreviewImageDecoder.decodePreviewImage(from: source) {
                return downsampled
            }
            if let image = UIImage(contentsOfFile: url.path()) {
                return image
            }
            guard let image = MediaThumbnailService.shared.previewImage(for: item) else {
                throw MediaAssetError.unreadableImage
            }
            return image
        }.value
    }

    func videoPlayer(for item: VaultItem) async throws -> MediaVideoPlayer {
        try Task.checkCancellation()
        let url = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try VaultFileStorageService.shared.decryptedTemporaryURL(
                for: item.relativePath,
                originalFilename: item.originalFilename,
                space: item.space
            )
        }.value
        try Task.checkCancellation()
        let player = AVPlayer(url: url)
        player.allowsExternalPlayback = false
        return MediaVideoPlayer(player: player, retainedSource: nil)
    }

    func cleanup(item: VaultItem) {
        VaultFileStorageService.shared.clearDecryptedTemporaryFile(for: item.relativePath)
    }
}

final class SecureMediaAssetProvider: MediaAssetProvider {
    let supportsSecureSeeking = false

    func image(for item: VaultItem) async throws -> UIImage {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data = try VaultFileStorageService.shared.decryptedData(for: item.relativePath, space: item.space)
            try Task.checkCancellation()
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let downsampled = MediaPreviewImageDecoder.decodePreviewImage(from: source) {
                return downsampled
            }
            guard let image = UIImage(data: data) else {
                throw MediaAssetError.unreadableImage
            }
            return image
        }.value
    }

    func videoPlayer(for item: VaultItem) async throws -> MediaVideoPlayer {
        try Task.checkCancellation()
        guard let contentType = UTType(item.contentTypeIdentifier) else {
            throw MediaAssetError.unsupportedVideo
        }
        let reader = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try VaultFileStorageService.shared.makeEncryptedStreamReader(for: item.relativePath, space: item.space)
        }.value
        try Task.checkCancellation()
        let source = StreamingEncryptedVideoSource(reader: reader, contentType: contentType)
        return MediaVideoPlayer(player: source.player, retainedSource: source)
    }

    func cleanup(item: VaultItem) {}
}

enum MediaAssetError: Error {
    case unreadableImage
    case unsupportedVideo
}

nonisolated private enum MediaPreviewImageDecoder {
    private static let maxPreviewPixelSize: CGFloat = 4096

    static func decodePreviewImage(from source: CGImageSource) -> UIImage? {
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
           max(width, height) <= maxPreviewPixelSize,
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let orientation = (properties[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:))
            return UIImage(cgImage: cgImage, scale: 1, orientation: orientation.map(uiImageOrientation(from:)) ?? .up)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPreviewPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func uiImageOrientation(from exif: CGImagePropertyOrientation) -> UIImage.Orientation {
        switch exif {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        }
    }
}

final class StreamingEncryptedVideoSource: NSObject, AVAssetResourceLoaderDelegate {
    let player: AVPlayer

    nonisolated private static let responseSliceBytes: Int64 = 1024 * 1024
    private let reader: VaultEncryptedStreamReader
    private let contentType: UTType
    private let asset: AVURLAsset
    private let queue = DispatchQueue(
        label: "SecurityFolder.MediaViewer.StreamingEncryptedVideoSource",
        autoreleaseFrequency: .workItem
    )

    init(reader: VaultEncryptedStreamReader, contentType: UTType) {
        self.reader = reader
        self.contentType = contentType
        let ext = contentType.preferredFilenameExtension ?? "mov"
        let url = URL(string: "secure-memory-video://\(UUID().uuidString).\(ext)")!
        self.asset = AVURLAsset(url: url)
        self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        self.player.allowsExternalPlayback = false
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    deinit {
        reader.close()
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !loadingRequest.isCancelled else { return true }
        let totalLength = reader.totalPlaintextBytes
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType.identifier
            info.contentLength = totalLength
            info.isByteRangeAccessSupported = true
        }

        guard let request = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let start = request.requestedOffset
        let offset = max(start, request.currentOffset)
        guard start >= 0, offset <= totalLength,
              request.requestsAllDataToEndOfResource || request.requestedLength >= 0 else {
            loadingRequest.finishLoading(with: URLError(.badURL))
            return true
        }

        let end = request.requestsAllDataToEndOfResource
            ? totalLength
            : start + min(Int64(request.requestedLength), totalLength - start)
        enqueueSlice(for: loadingRequest, offset: offset, end: end)
        return true
    }

    private nonisolated func enqueueSlice(for loadingRequest: AVAssetResourceLoadingRequest, offset: Int64, end: Int64) {
        // Yield the delegate queue between slices so other requests and cancellation can be delivered.
        queue.async { [weak self] in
            guard let self, !loadingRequest.isCancelled,
                  let request = loadingRequest.dataRequest else { return }
            guard offset < end else {
                loadingRequest.finishLoading()
                return
            }

            let length = min(Self.responseSliceBytes, end - offset)
            do {
                let chunk = try self.reader.readSlice(offset: offset, length: Int(length))
                guard !loadingRequest.isCancelled else { return }
                guard chunk.count == Int(length) else { throw URLError(.cannotDecodeRawData) }
                request.respond(with: chunk)
                guard !loadingRequest.isCancelled else { return }
                let nextOffset = offset + length
                if nextOffset < end {
                    self.enqueueSlice(for: loadingRequest, offset: nextOffset, end: end)
                } else {
                    loadingRequest.finishLoading()
                }
            } catch {
                if !loadingRequest.isCancelled {
                    loadingRequest.finishLoading(with: error)
                }
            }
        }
    }
}
