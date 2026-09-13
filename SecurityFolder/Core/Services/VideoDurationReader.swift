import AVFoundation
import Foundation

struct VideoDurationReader {
    nonisolated static func read(relativePath: String, originalFilename: String, space: VaultSpaceKind) async -> Double? {
        let task = Task.detached(priority: .utility) { () -> Double? in
            guard !Task.isCancelled else { return nil }
            let storage = VaultFileStorageService.shared
            guard let url = try? storage.decryptedTemporaryURL(
                for: relativePath, originalFilename: originalFilename, space: space, cacheResult: false
            ) else { return nil }
            defer { storage.clearDecryptedTemporaryURLIfManaged(url) }
            guard !Task.isCancelled else { return nil }
            let asset = AVURLAsset(url: url)
            let seconds = try? await asset.load(.duration).seconds
            guard !Task.isCancelled, let seconds, seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
