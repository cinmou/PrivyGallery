import Foundation

final class VaultItem: Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var importedAt: Date
    var lastExportedAt: Date?
    var originalCapturedAt: Date?
    var updatedAt: Date
    var mediaKindRawValue: String
    var spaceRawValue: String
    var isInTrash: Bool
    var isArchived: Bool
    var isStrongProtected: Bool
    var relativePath: String
    var originalFilename: String
    var contentTypeIdentifier: String
    var locationLatitude: Double?
    var locationLongitude: Double?
    var albums: [VaultAlbum]
    /// Encrypted vault-relative path of the companion video for a Live Photo.
    /// `nil` for all non-Live-Photo items.
    var livePhotoCompanionRelativePath: String?

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        importedAt: Date = .now,
        lastExportedAt: Date? = nil,
        originalCapturedAt: Date? = nil,
        updatedAt: Date = .now,
        mediaKind: MediaKind,
        space: VaultSpaceKind,
        isInTrash: Bool = false,
        isArchived: Bool = false,
        isStrongProtected: Bool = false,
        relativePath: String,
        originalFilename: String,
        contentTypeIdentifier: String,
        locationLatitude: Double? = nil,
        locationLongitude: Double? = nil,
        albums: [VaultAlbum] = [],
        livePhotoCompanionRelativePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.importedAt = importedAt
        self.lastExportedAt = lastExportedAt
        self.originalCapturedAt = originalCapturedAt
        self.updatedAt = updatedAt
        self.mediaKindRawValue = mediaKind.rawValue
        self.spaceRawValue = space.rawValue
        self.isInTrash = isInTrash
        self.isArchived = isArchived
        self.isStrongProtected = isStrongProtected
        self.relativePath = relativePath
        self.originalFilename = originalFilename
        self.contentTypeIdentifier = contentTypeIdentifier
        self.locationLatitude = locationLatitude
        self.locationLongitude = locationLongitude
        self.albums = albums
        self.livePhotoCompanionRelativePath = livePhotoCompanionRelativePath
    }

    var mediaKind: MediaKind {
        get { MediaKind(rawValue: mediaKindRawValue) ?? .photo }
        set { mediaKindRawValue = newValue.rawValue }
    }

    var space: VaultSpaceKind {
        get { VaultSpaceKind(rawValue: spaceRawValue) ?? .spaceA }
        set { spaceRawValue = newValue.rawValue }
    }

    static func == (lhs: VaultItem, rhs: VaultItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
