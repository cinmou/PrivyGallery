import CommonCrypto
import CryptoKit
import Foundation

nonisolated struct VaultBackupHeader: Codable {
    let exportedAt: Date
    let appName: String
    let formatVersion: Int
    let partIndex: Int
    let totalParts: Int
    let archiveEncoding: String
    let kdf: VaultBackupKDFInfo
    let cipher: String
    let chunkSize: Int
    let archiveByteCount: Int64
}

nonisolated struct VaultBackupKDFInfo: Codable {
    let algorithm: String
    let rounds: Int
    let saltBase64: String
}

nonisolated struct VaultBackupPartManifest: Codable {
    let exportedAt: Date
    let spaceRawValue: String
    let partIndex: Int
    let totalParts: Int
    let albums: [VaultBackupAlbumRecord]
    let items: [VaultBackupItemRecord]
    let blobEntries: [VaultBackupBlobEntry]
}

nonisolated struct VaultBackupAlbumRecord: Codable {
    let id: String
    let name: String
    let kindRawValue: String
    let coverItemIDRawValue: String?
    let coverImageRelativePath: String?
    let coverSymbolName: String?
    let sortOptionRawValue: String
    let customOrderedItemIDs: [String]
    let showsCover: Bool
    let libraryOrderIndex: Int
    let colorRawValue: String?
}

nonisolated struct VaultBackupItemRecord: Codable {
    let id: String
    let name: String
    let createdAt: Date
    let importedAt: Date?
    let lastExportedAt: Date?
    let originalCapturedAt: Date?
    let updatedAt: Date
    let videoDuration: Double?
    let mediaKindRawValue: String
    let isInTrash: Bool
    let isArchived: Bool
    let isStrongProtected: Bool
    let relativePath: String
    let originalFilename: String
    let contentTypeIdentifier: String
    let locationLatitude: Double?
    let locationLongitude: Double?
    let albumIDs: [String]
    let trashedAt: Date?
    let livePhotoCompanionRelativePath: String?
}

nonisolated struct VaultBackupBlobEntry: Codable {
    let relativePath: String
    let sourceDomain: VaultBackupSourceDomain
    let byteCount: Int64
}

nonisolated enum VaultBackupSourceDomain: UInt8, Codable {
    case media = 1
    case livePhotoCompanion = 2
    case albumCover = 3
}

nonisolated enum VaultArchiveChunkCodec: UInt8 {
    case raw = 0
    case lzfse = 1
}

nonisolated enum VaultBackupCryptoHelper {
    static func derivePBKDF2Key(
        password: String,
        salt: Data,
        rounds: Int,
        encodingError: @autoclosure () -> Error,
        derivationError: @autoclosure () -> Error
    ) throws -> SymmetricKey {
        guard let passwordData = password.data(using: .utf8) else {
            throw encodingError()
        }

        var derivedKey = Data(count: 32)
        let derivedKeyCount = derivedKey.count
        let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(rounds),
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        derivedKeyCount
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw derivationError()
        }
        return SymmetricKey(data: derivedKey)
    }

    static func authenticatedData(for header: VaultBackupHeader, chunkIndex: Int) -> Data {
        Data("SVEX-v2|\(header.partIndex)|\(header.totalParts)|\(chunkIndex)|\(header.archiveByteCount)".utf8)
    }

    static func availableDiskCapacity(at directoryURL: URL) -> Int64? {
        let values = try? directoryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        if let standard = values?.volumeAvailableCapacity {
            return Int64(standard)
        }
        return nil
    }
}
