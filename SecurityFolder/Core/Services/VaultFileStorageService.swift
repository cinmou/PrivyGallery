import AVFoundation
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct StoredMediaFile {
    let relativePath: String
    let mediaKind: MediaKind
    let displayName: String
    let originalFilename: String
    let contentTypeIdentifier: String
    let byteCount: Int64
    let originalCapturedAt: Date?
    let locationLatitude: Double?
    let locationLongitude: Double?
}

enum VaultFileStorageError: LocalizedError {
    case unsupportedType
    case unreadableData
    case advancedDataProtectionEnabled

    var errorDescription: String? {
        switch self {
        case .unsupportedType:
            return String(localized: "不支持的文件类型。")
        case .unreadableData:
            return String(localized: "无法读取导入的文件数据。")
        case .advancedDataProtectionEnabled:
            return String(localized: "高级数据保护已开启，应用不会生成任何临时解密文件。")
        }
    }
}

final class VaultFileStorageService {
    nonisolated static let shared = VaultFileStorageService()

    nonisolated(unsafe) private let fileManager = FileManager.default
    private let cryptoService = VaultCryptoService.shared

    private init() {}

    nonisolated func fileURL(for storedPath: String) -> URL {
        let normalizedPath = normalizedRelativePath(for: storedPath)
        if normalizedPath != storedPath {
            return fileURL(for: normalizedPath)
        }

        if storedPath.hasPrefix("/") {
            return URL(fileURLWithPath: storedPath)
        }

        return storedPath
            .split(separator: "/")
            .map(String.init)
            .reduce(documentsDirectory) { partialURL, pathComponent in
                partialURL.appendingPathComponent(pathComponent, isDirectory: false)
            }
    }

    nonisolated func fileExists(at storedPath: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: storedPath).path())
    }

    nonisolated func byteCount(for storedPath: String) -> Int64 {
        let url = fileURL(for: storedPath)
        return byteCount(at: url)
    }

    nonisolated func normalizedRelativePath(for storedPath: String) -> String {
        if let vaultStoragePath = suffixPath(after: "VaultStorage", in: storedPath) {
            return "VaultStorage/" + vaultStoragePath
        }

        if storedPath.hasPrefix("/") {
            if let documentsPath = suffixPath(after: "Documents", in: storedPath) {
                return existingRelativePath(matchingFilenameIn: documentsPath) ?? documentsPath
            }
            return storedPath
        }

        return existingRelativePath(matchingFilenameIn: storedPath) ?? storedPath
    }

    nonisolated private func byteCount(at url: URL) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path()),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    func importFile(
        from sourceURL: URL,
        space: VaultSpaceKind
    ) async throws -> StoredMediaFile {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let mediaKind = try mediaKind(for: sourceURL)
        let fileExtension = sourceURL.pathExtension
        let destinationDirectory = try activeDirectory(for: space)
        let storedFilename = "\(UUID().uuidString).\(fileExtension)"
        let destinationURL = destinationDirectory.appendingPathComponent(storedFilename)
        let relativePath = relativePath(for: destinationURL)
        let metadata = await ImportedMediaMetadataExtractor.metadata(forFileAt: sourceURL, mediaKind: mediaKind)

        try cryptoService.encryptImportedFile(from: sourceURL, to: destinationURL, space: space)
        let byteCount = self.byteCount(at: destinationURL)

        return StoredMediaFile(
            relativePath: relativePath,
            mediaKind: mediaKind,
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            originalFilename: sourceURL.lastPathComponent,
            contentTypeIdentifier: UTType(filenameExtension: fileExtension)?.identifier ?? "",
            byteCount: byteCount,
            originalCapturedAt: metadata.originalCapturedAt,
            locationLatitude: metadata.locationLatitude,
            locationLongitude: metadata.locationLongitude
        )
    }

    func duplicateFile(at relativePath: String, space: VaultSpaceKind) throws -> StoredMediaFile {
        let sourceURL = fileURL(for: relativePath)
        let mediaKind = try mediaKind(for: sourceURL)
        let fileExtension = sourceURL.pathExtension
        let destinationDirectory = try activeDirectory(for: space)
        let destinationURL = destinationDirectory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        let destinationRelativePath = self.relativePath(for: destinationURL)

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        let byteCount = self.byteCount(at: destinationURL)

        return StoredMediaFile(
            relativePath: destinationRelativePath,
            mediaKind: mediaKind,
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            originalFilename: sourceURL.lastPathComponent,
            contentTypeIdentifier: UTType(filenameExtension: fileExtension)?.identifier ?? "",
            byteCount: byteCount,
            originalCapturedAt: nil,
            locationLatitude: nil,
            locationLongitude: nil
        )
    }

    func storeAlbumCoverImage(_ image: UIImage, albumID: UUID, space: VaultSpaceKind) throws -> String {
        let coversDirectory = try ensureDirectoryExists(
            documentsDirectory
                .appendingPathComponent("VaultStorage")
                .appendingPathComponent(directoryName(for: space))
                .appendingPathComponent("AlbumCovers")
        )

        let destinationURL = coversDirectory.appendingPathComponent("\(albumID.uuidString).jpg")
        guard let data = image.jpegData(compressionQuality: 0.88) else {
            throw VaultFileStorageError.unreadableData
        }

        try data.write(to: destinationURL, options: .atomic)
        return relativePath(for: destinationURL)
    }

    func albumCoverImage(for relativePath: String) -> UIImage? {
        UIImage(contentsOfFile: fileURL(for: relativePath).path())
    }

    func moveToTrash(relativePath: String, space: VaultSpaceKind) throws -> String {
        try move(relativePath: relativePath, to: trashDirectory(for: space))
    }

    func restoreFromTrash(relativePath: String, space: VaultSpaceKind) throws -> String {
        try move(relativePath: relativePath, to: activeDirectory(for: space))
    }

    func removeFile(relativePath: String) throws {
        let url = fileURL(for: relativePath)
        guard fileManager.fileExists(atPath: url.path()) else { return }
        try fileManager.removeItem(at: url)
    }

    nonisolated func decryptedTemporaryURL(
        for relativePath: String,
        originalFilename: String,
        space: VaultSpaceKind,
        cacheResult: Bool = true
    ) throws -> URL {
        return try cryptoService.decryptedTemporaryURL(
            forEncryptedFileAt: fileURL(for: relativePath),
            relativePath: relativePath,
            originalFilename: originalFilename,
            space: space,
            cacheResult: cacheResult
        )
    }

    func clearDecryptedTemporaryFile(for relativePath: String) {
        cryptoService.clearTemporaryFile(relativePath: relativePath)
    }

    nonisolated func clearDecryptedTemporaryURLIfManaged(_ url: URL) {
        cryptoService.clearTemporaryURLIfManaged(url)
    }

    func decryptedData(for relativePath: String, space: VaultSpaceKind) throws -> Data {
        try cryptoService.decryptedData(
            forEncryptedFileAt: fileURL(for: relativePath),
            space: space
        )
    }

    @discardableResult
    func migrateFileToEncryptedStorageIfNeeded(relativePath: String, space: VaultSpaceKind) throws -> Bool {
        try cryptoService.migrateFileToEncryptedStorageIfNeeded(at: fileURL(for: relativePath), space: space)
    }

    private func move(relativePath: String, to directory: URL) throws -> String {
        let sourceURL = fileURL(for: relativePath)
        let destinationURL = directory.appending(path: sourceURL.lastPathComponent)

        if fileManager.fileExists(atPath: destinationURL.path()) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        return self.relativePath(for: destinationURL)
    }

    private func mediaKind(for sourceURL: URL) throws -> MediaKind {
        let fileType = UTType(filenameExtension: sourceURL.pathExtension)
        if fileType?.conforms(to: .movie) == true {
            return .video
        }
        if fileType?.conforms(to: .image) == true {
            return .photo
        }
        throw VaultFileStorageError.unsupportedType
    }

    /// Encrypt a Live Photo companion video file and store it alongside the still image.
    /// Returns the vault-relative path of the encrypted companion file.
    func importCompanionFile(from sourceURL: URL, space: VaultSpaceKind) throws -> String {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let destinationDirectory = try activeDirectory(for: space)
        let storedFilename = "\(UUID().uuidString).\(fileExtension)"
        let destinationURL = destinationDirectory.appendingPathComponent(storedFilename)
        try cryptoService.encryptImportedFile(from: sourceURL, to: destinationURL, space: space)
        return relativePath(for: destinationURL)
    }

    private func defaultFileExtension(for mediaKind: MediaKind) -> String {
        switch mediaKind {
        case .photo: return "jpg"
        case .video: return "mov"
        case .livePhoto: return "heic"
        }
    }

    nonisolated private func relativePath(for url: URL) -> String {
        if let vaultStoragePath = suffixPath(after: "VaultStorage", in: url.path(percentEncoded: false)) {
            return "VaultStorage/" + vaultStoragePath
        }

        if let documentsPath = suffixPath(after: "Documents", in: url.path(percentEncoded: false)) {
            return documentsPath
        }

        return url.lastPathComponent
    }

    nonisolated private func suffixPath(after marker: String, in path: String) -> String? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard let markerIndex = components.lastIndex(of: marker) else {
            return nil
        }

        let suffixComponents = components.dropFirst(markerIndex + 1)
        guard !suffixComponents.isEmpty else {
            return nil
        }

        return suffixComponents.joined(separator: "/")
    }

    nonisolated private func existingRelativePath(matchingFilenameIn storedPath: String) -> String? {
        let filename = URL(fileURLWithPath: storedPath).lastPathComponent
        guard !filename.isEmpty else {
            return nil
        }

        let vaultStorageURL = documentsDirectory.appendingPathComponent("VaultStorage")
        guard let enumerator = fileManager.enumerator(
            at: vaultStorageURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == filename {
            return relativePath(for: fileURL)
        }

        return nil
    }

    private func activeDirectory(for space: VaultSpaceKind) throws -> URL {
        try ensureDirectoryExists(
            documentsDirectory
                .appendingPathComponent("VaultStorage")
                .appendingPathComponent(directoryName(for: space))
                .appendingPathComponent("Active")
        )
    }

    private func trashDirectory(for space: VaultSpaceKind) throws -> URL {
        try ensureDirectoryExists(
            documentsDirectory
                .appendingPathComponent("VaultStorage")
                .appendingPathComponent(directoryName(for: space))
                .appendingPathComponent("Trash")
        )
    }

    private func ensureDirectoryExists(_ url: URL) throws -> URL {
        if !fileManager.fileExists(atPath: url.path()) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    nonisolated private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    nonisolated private func directoryName(for space: VaultSpaceKind) -> String {
        switch space {
        case .spaceA: return "Space_A"
        case .spaceB: return "Space_B"
        }
    }
}

private struct ImportedMediaMetadata {
    let originalCapturedAt: Date?
    let locationLatitude: Double?
    let locationLongitude: Double?

    static let empty = ImportedMediaMetadata(
        originalCapturedAt: nil,
        locationLatitude: nil,
        locationLongitude: nil
    )
}

private enum ImportedMediaMetadataExtractor {
    static func metadata(forFileAt url: URL, mediaKind: MediaKind) async -> ImportedMediaMetadata {
        switch mediaKind {
        case .photo, .livePhoto:
            return metadataFromImageSource(CGImageSourceCreateWithURL(url as CFURL, nil))
        case .video:
            return await metadataFromVideo(url: url)
        }
    }

    private static func metadataFromImageSource(_ imageSource: CGImageSource?) -> ImportedMediaMetadata {
        guard let imageSource,
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return .empty
        }

        let gpsDictionary = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let latitude = coordinate(
            value: gpsDictionary?[kCGImagePropertyGPSLatitude] as? NSNumber,
            reference: gpsDictionary?[kCGImagePropertyGPSLatitudeRef] as? String,
            positiveReference: "N"
        )
        let longitude = coordinate(
            value: gpsDictionary?[kCGImagePropertyGPSLongitude] as? NSNumber,
            reference: gpsDictionary?[kCGImagePropertyGPSLongitudeRef] as? String,
            positiveReference: "E"
        )

        let exifDictionary = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiffDictionary = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let originalCapturedAt = parseMetadataDate(
            exifDictionary?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? tiffDictionary?[kCGImagePropertyTIFFDateTime] as? String
        )

        return ImportedMediaMetadata(
            originalCapturedAt: originalCapturedAt,
            locationLatitude: latitude,
            locationLongitude: longitude
        )
    }

    private static func metadataFromVideo(url: URL) async -> ImportedMediaMetadata {
        let asset = AVURLAsset(url: url)
        var originalCapturedAt: Date?
        var latitude: Double?
        var longitude: Double?

        do {
            let commonMetadata = try await asset.load(.commonMetadata)
            if let creationDateItem = commonMetadata.first(where: { $0.commonKey == .commonKeyCreationDate }),
               let creationDate = try? await creationDateItem.load(.dateValue) {
                originalCapturedAt = creationDate
            }

            let metadataFormats = try await asset.load(.availableMetadataFormats)
            for format in metadataFormats {
                let metadataItems = try await asset.loadMetadata(for: format)
                for item in metadataItems {
                    if item.identifier == .quickTimeMetadataLocationISO6709,
                       let iso6709 = try? await item.load(.stringValue),
                       let coordinates = parseISO6709Location(iso6709) {
                        latitude = coordinates.latitude
                        longitude = coordinates.longitude
                    } else if originalCapturedAt == nil,
                              let dateValue = try? await item.load(.dateValue) {
                        originalCapturedAt = dateValue
                    }
                }
            }
        } catch {
            return .empty
        }

        return ImportedMediaMetadata(
            originalCapturedAt: originalCapturedAt,
            locationLatitude: latitude,
            locationLongitude: longitude
        )
    }

    private static func coordinate(value: NSNumber?, reference: String?, positiveReference: String) -> Double? {
        guard let value else { return nil }
        let sign = (reference?.uppercased() == positiveReference) ? 1.0 : -1.0
        return value.doubleValue * sign
    }

    private static func parseMetadataDate(_ rawValue: String?) -> Date? {
        guard let rawValue else { return nil }
        return metadataDateFormatter.date(from: rawValue)
    }

    private static func parseISO6709Location(_ rawValue: String) -> (latitude: Double, longitude: Double)? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 7 else { return nil }

        let stripped = normalized
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "+", with: " +")
            .replacingOccurrences(of: "-", with: " -")
            .trimmingCharacters(in: .whitespaces)

        let parts = stripped.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]) else {
            return nil
        }

        return (latitude, longitude)
    }

    private static let metadataDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}
