import Foundation

final class VaultAlbum: Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var kindRawValue: String
    var spaceRawValue: String
    var coverItemIDRawValue: String?
    var coverImageRelativePath: String?
    var coverSymbolName: String?
    var sortOptionRawValue: String
    var customOrderedItemIDs: [String]
    var showsCover: Bool
    var libraryOrderIndex: Int
    var items: [VaultItem]

    init(
        id: UUID = UUID(),
        name: String,
        kind: MediaAlbumKind,
        space: VaultSpaceKind,
        coverItemID: UUID? = nil,
        coverImageRelativePath: String? = nil,
        coverSymbolName: String? = nil,
        sortOption: AlbumSortOption = .newestFirst,
        customOrderedItemIDs: [UUID] = [],
        showsCover: Bool = false,
        libraryOrderIndex: Int = 0,
        items: [VaultItem] = []
    ) {
        self.id = id
        self.name = name
        self.kindRawValue = kind.rawValue
        self.spaceRawValue = space.rawValue
        self.coverItemIDRawValue = coverItemID?.uuidString
        self.coverImageRelativePath = coverImageRelativePath
        self.coverSymbolName = coverSymbolName
        self.sortOptionRawValue = sortOption.rawValue
        self.customOrderedItemIDs = customOrderedItemIDs.map(\.uuidString)
        self.showsCover = showsCover
        self.libraryOrderIndex = libraryOrderIndex
        self.items = items
    }

    var kind: MediaAlbumKind {
        get { MediaAlbumKind(rawValue: kindRawValue) ?? .custom }
        set { kindRawValue = newValue.rawValue }
    }

    var space: VaultSpaceKind {
        get { VaultSpaceKind(rawValue: spaceRawValue) ?? .spaceA }
        set { spaceRawValue = newValue.rawValue }
    }

    var coverItemID: UUID? {
        get { coverItemIDRawValue.flatMap(UUID.init(uuidString:)) }
        set { coverItemIDRawValue = newValue?.uuidString }
    }

    var sortOption: AlbumSortOption {
        get { AlbumSortOption(rawValue: sortOptionRawValue) ?? .newestFirst }
        set { sortOptionRawValue = newValue.rawValue }
    }

    var customOrderedUUIDs: [UUID] {
        get { customOrderedItemIDs.compactMap(UUID.init(uuidString:)) }
        set { customOrderedItemIDs = newValue.map(\.uuidString) }
    }

    var isSystemAlbum: Bool {
        kind != .custom && kind != .secureCustom
    }

    var isSecureAlbum: Bool {
        kind.isSecure
    }

    var displayName: String {
        kind.systemDisplayName ?? name
    }

    static func == (lhs: VaultAlbum, rhs: VaultAlbum) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
