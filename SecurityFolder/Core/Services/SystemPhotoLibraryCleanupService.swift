import Foundation
import Photos

enum SystemPhotoLibraryCleanupError: LocalizedError {
    case accessDenied
    case nothingToDelete

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return String(localized: "没有系统相册的删除权限。请到系统设置里允许“照片”访问后再试。")
        case .nothingToDelete:
            return String(localized: "这次导入的项目没有对应到系统相册资源，无法自动删除。")
        }
    }
}

struct SystemPhotoLibraryCleanupService {
    static let shared = SystemPhotoLibraryCleanupService()

    func ensureReadWriteAuthorization() async -> PHAuthorizationStatus {
        await requestAuthorizationIfNeeded()
    }

    func deleteAssets(withLocalIdentifiers identifiers: [String]) async throws -> Int {
        let uniqueIdentifiers = Array(Set(identifiers.filter { !$0.isEmpty }))
        guard !uniqueIdentifiers.isEmpty else {
            throw SystemPhotoLibraryCleanupError.nothingToDelete
        }

        let authorizationStatus = await requestAuthorizationIfNeeded()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            throw SystemPhotoLibraryCleanupError.accessDenied
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: uniqueIdentifiers, options: nil)
        guard assets.count > 0 else {
            throw SystemPhotoLibraryCleanupError.nothingToDelete
        }

        try await performDeletion(for: assets)
        return assets.count
    }

    private func requestAuthorizationIfNeeded() async -> PHAuthorizationStatus {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch currentStatus {
        case .authorized, .limited:
            return currentStatus
        case .notDetermined:
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        default:
            return currentStatus
        }
    }

    private func performDeletion(for assets: PHFetchResult<PHAsset>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SystemPhotoLibraryCleanupError.accessDenied)
                }
            }
        }
    }
}
