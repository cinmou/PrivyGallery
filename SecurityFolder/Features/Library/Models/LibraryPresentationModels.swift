import Foundation
import UniformTypeIdentifiers

struct AlbumCellModel: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String
    let coverTitle: String?
    let coverItem: VaultItem?
    let coverImageRelativePath: String?
    let systemImage: String
    let allowsDeletion: Bool
    let usesRowStyle: Bool
    let isSecureAlbum: Bool
}

struct AlbumSelectionOption: Identifiable {
    let id: UUID
    let title: String
    let isSelected: Bool
}

struct MediaItemsPage {
    let items: [VaultItem]
    let totalCount: Int
}

struct ImportedSystemAssetsDeletionPrompt: Identifiable {
    let id = UUID()
    let assetIdentifiers: [String]
    let importedCount: Int
}

struct ImportedPickerAsset {
    let contentType: UTType
    let fallbackName: String
    let assetIdentifier: String?
    let fileURL: URL
    /// Companion MOV temp-file URL for Live Photos; `nil` for regular photos/videos.
    let companionVideoURL: URL?

    init(
        fileURL: URL,
        contentType: UTType,
        fallbackName: String,
        assetIdentifier: String?,
        companionVideoURL: URL? = nil
    ) {
        self.contentType = contentType
        self.fallbackName = fallbackName
        self.assetIdentifier = assetIdentifier
        self.fileURL = fileURL
        self.companionVideoURL = companionVideoURL
    }
}

struct MediaFileDebugInfo: Identifiable {
    let id: UUID
    let name: String
    let mediaKind: String
    let contentType: String
    let relativePath: String
    let absolutePath: String
    let exists: Bool
    let byteCount: Int64
}

struct MediaImportResultSummary: Identifiable {
    let id = UUID()
    let photoCount: Int
    let videoCount: Int
}

struct MediaItemDetailInfo: Identifiable {
    let id: UUID
    let title: String
    let mediaKindTitle: String
    let originalFilename: String
    let contentTypeIdentifier: String
    let byteCount: Int64
    let importedAt: Date
    let lastExportedAt: Date?
    let originalCapturedAt: Date?
    let locationLatitude: Double?
    let locationLongitude: Double?
}

enum LibraryAlbumSortOption: String, CaseIterable, Identifiable {
    case manual
    case nameAscending
    case nameDescending
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "默认顺序"
        case .nameAscending: "名称 A-Z"
        case .nameDescending: "名称 Z-A"
        case .custom: "自由排序"
        }
    }
}
