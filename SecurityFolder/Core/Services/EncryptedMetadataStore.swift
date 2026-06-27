import Foundation

enum EncryptedMetadataStoreError: LocalizedError {
    case invalidManifest

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            return String(localized: "元数据索引已损坏，无法读取。")
        }
    }
}

struct SpaceMetadataSnapshot {
    let albums: [VaultAlbum]
    let items: [VaultItem]
}

final class EncryptedMetadataStore {
    nonisolated static let shared = EncryptedMetadataStore()

    private let fileManager = FileManager.default
    private let cryptoService = VaultCryptoService.shared

    private init() {}

    func loadSnapshot(for space: VaultSpaceKind) throws -> SpaceMetadataSnapshot {
        let manifestURL = manifestURL(for: space)
        guard fileManager.fileExists(atPath: manifestURL.path()) else {
            return SpaceMetadataSnapshot(albums: defaultAlbums(for: space), items: [])
        }

        let manifestData = try cryptoService.decryptedData(forEncryptedFileAt: manifestURL, space: space)
        let manifest = try JSONDecoder.metadataDecoder.decode(EncryptedMetadataManifest.self, from: manifestData)
        return try buildSnapshot(from: manifest, for: space)
    }

    func saveSnapshot(space: VaultSpaceKind, albums: [VaultAlbum], items: [VaultItem]) throws {
        let manifest = EncryptedMetadataManifest(
            version: 1,
            albums: albums.map { album in
                EncryptedAlbumRecord(
                    id: album.id,
                    name: album.name,
                    kindRawValue: album.kindRawValue,
                    coverItemID: album.coverItemID,
                    coverImageRelativePath: album.coverImageRelativePath,
                    coverSymbolName: album.coverSymbolName,
                    sortOptionRawValue: album.sortOptionRawValue,
                    customOrderedItemIDs: album.customOrderedUUIDs,
                    showsCover: album.showsCover,
                    libraryOrderIndex: album.libraryOrderIndex
                )
            },
            items: items.map { item in
                EncryptedItemRecord(
                    id: item.id,
                    name: item.name,
                    createdAt: item.createdAt,
                    importedAt: item.importedAt,
                    lastExportedAt: item.lastExportedAt,
                    originalCapturedAt: item.originalCapturedAt,
                    updatedAt: item.updatedAt,
                    mediaKindRawValue: item.mediaKindRawValue,
                    isInTrash: item.isInTrash,
                    isArchived: item.isArchived,
                    isStrongProtected: item.isStrongProtected,
                    relativePath: item.relativePath,
                    originalFilename: item.originalFilename,
                    contentTypeIdentifier: item.contentTypeIdentifier,
                    locationLatitude: item.locationLatitude,
                    locationLongitude: item.locationLongitude,
                    albumIDs: item.albums.map(\.id),
                    livePhotoCompanionRelativePath: item.livePhotoCompanionRelativePath
                )
            }
        )

        let manifestData = try JSONEncoder.metadataEncoder.encode(manifest)
        try ensureDirectoryExists(manifestURL(for: space).deletingLastPathComponent())
        try cryptoService.encryptPlaintextData(manifestData, to: manifestURL(for: space), space: space)
    }

    func deleteSnapshot(for space: VaultSpaceKind) {
        let url = manifestURL(for: space)
        if fileManager.fileExists(atPath: url.path()) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func buildSnapshot(from manifest: EncryptedMetadataManifest, for space: VaultSpaceKind) throws -> SpaceMetadataSnapshot {
        guard manifest.version == 1 else {
            throw EncryptedMetadataStoreError.invalidManifest
        }

        let albums = manifest.albums.map {
            VaultAlbum(
                id: $0.id,
                name: $0.name,
                kind: MediaAlbumKind(rawValue: $0.kindRawValue) ?? .custom,
                space: space,
                coverItemID: $0.coverItemID,
                coverImageRelativePath: $0.coverImageRelativePath,
                coverSymbolName: $0.coverSymbolName,
                sortOption: AlbumSortOption(rawValue: $0.sortOptionRawValue) ?? .newestFirst,
                customOrderedItemIDs: $0.customOrderedItemIDs,
                showsCover: $0.showsCover,
                libraryOrderIndex: $0.libraryOrderIndex
            )
        }
        let albumsByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })

        let items = manifest.items.map { record in
            VaultItem(
                id: record.id,
                name: record.name,
                createdAt: record.createdAt,
                importedAt: record.importedAt,
                lastExportedAt: record.lastExportedAt,
                originalCapturedAt: record.originalCapturedAt,
                updatedAt: record.updatedAt,
                mediaKind: MediaKind(rawValue: record.mediaKindRawValue) ?? .photo,
                space: space,
                isInTrash: record.isInTrash,
                isArchived: record.isArchived,
                isStrongProtected: record.isStrongProtected,
                relativePath: record.relativePath,
                originalFilename: record.originalFilename,
                contentTypeIdentifier: record.contentTypeIdentifier,
                locationLatitude: record.locationLatitude,
                locationLongitude: record.locationLongitude,
                albums: record.albumIDs.compactMap { albumsByID[$0] },
                livePhotoCompanionRelativePath: record.livePhotoCompanionRelativePath
            )
        }

        let itemsByAlbumID = Dictionary(grouping: items.flatMap { item in
            item.albums.map { ($0.id, item) }
        }, by: \.0)
        for album in albums {
            album.items = itemsByAlbumID[album.id]?.map(\.1) ?? []
        }

        return SpaceMetadataSnapshot(albums: normalizedAlbums(albums, for: space), items: items)
    }

    private func normalizedAlbums(_ albums: [VaultAlbum], for space: VaultSpaceKind) -> [VaultAlbum] {
        let existingKinds = Set(albums.map(\.kind))
        let defaults = defaultAlbums(for: space).filter { !existingKinds.contains($0.kind) }
        return albums + defaults
    }

    private func defaultAlbums(for space: VaultSpaceKind) -> [VaultAlbum] {
        [
            VaultAlbum(name: MediaAlbumKind.allPhotos.systemDisplayName ?? "All Photos", kind: .allPhotos, space: space, libraryOrderIndex: 0),
            VaultAlbum(name: MediaAlbumKind.allVideos.systemDisplayName ?? "All Videos", kind: .allVideos, space: space, libraryOrderIndex: 1),
            VaultAlbum(name: MediaAlbumKind.archive.systemDisplayName ?? "Archive", kind: .archive, space: space, libraryOrderIndex: 10_001),
            VaultAlbum(name: MediaAlbumKind.trash.systemDisplayName ?? "Trash", kind: .trash, space: space, libraryOrderIndex: 10_000),
        ]
    }

    private func manifestURL(for space: VaultSpaceKind) -> URL {
        let directoryName = space == .spaceA ? "Space_A" : "Space_B"
        return documentsDirectory
            .appendingPathComponent("VaultStorage")
            .appendingPathComponent(directoryName)
            .appendingPathComponent("metadata.manifest")
    }

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path()) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

private struct EncryptedMetadataManifest: Codable {
    let version: Int
    let albums: [EncryptedAlbumRecord]
    let items: [EncryptedItemRecord]
}

private struct EncryptedAlbumRecord: Codable {
    let id: UUID
    let name: String
    let kindRawValue: String
    let coverItemID: UUID?
    let coverImageRelativePath: String?
    let coverSymbolName: String?
    let sortOptionRawValue: String
    let customOrderedItemIDs: [UUID]
    let showsCover: Bool
    let libraryOrderIndex: Int
}

private struct EncryptedItemRecord: Codable {
    let id: UUID
    let name: String
    let createdAt: Date
    let importedAt: Date
    let lastExportedAt: Date?
    let originalCapturedAt: Date?
    let updatedAt: Date
    let mediaKindRawValue: String
    let isInTrash: Bool
    let isArchived: Bool
    let isStrongProtected: Bool
    let relativePath: String
    let originalFilename: String
    let contentTypeIdentifier: String
    let locationLatitude: Double?
    let locationLongitude: Double?
    let albumIDs: [UUID]
    /// Vault-relative path of the companion MOV for a Live Photo.
    /// Optional so that manifests written by older app versions decode cleanly.
    let livePhotoCompanionRelativePath: String?
}

private extension JSONEncoder {
    static var metadataEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var metadataDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
