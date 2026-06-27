import SwiftUI

enum PreviewSupport {
    @MainActor
    static func session() -> AppSessionViewModel {
        let session = AppSessionViewModel()
        session.activeSpace = .spaceA
        return session
    }

    @MainActor
    static func settingsViewModel(space: VaultSpaceKind = .spaceA) -> SettingsViewModel {
        SettingsViewModel(space: space)
    }

    @MainActor
    static func mediaLibraryViewModel(space: VaultSpaceKind = .spaceA) -> MediaLibraryViewModel {
        MediaLibraryViewModel(space: space)
    }

    static func sampleItem(
        id: UUID = UUID(),
        name: String = "示例照片",
        mediaKind: MediaKind = .photo,
        space: VaultSpaceKind = .spaceA,
        isInTrash: Bool = false,
        isArchived: Bool = false
    ) -> VaultItem {
        VaultItem(
            id: id,
            name: name,
            importedAt: .now,
            lastExportedAt: .now.addingTimeInterval(-3600),
            originalCapturedAt: .now.addingTimeInterval(-86400),
            mediaKind: mediaKind,
            space: space,
            isInTrash: isInTrash,
            isArchived: isArchived,
            relativePath: "Preview/\(id.uuidString).bin",
            originalFilename: mediaKind == .photo ? "IMG_0001.HEIC" : "IMG_0001.MOV",
            contentTypeIdentifier: mediaKind == .photo ? "public.heic" : "com.apple.quicktime-movie",
            locationLatitude: 51.507351,
            locationLongitude: -0.127758
        )
    }

    static func sampleAlbumCell(usesRowStyle: Bool = false) -> AlbumCellModel {
        let item = sampleItem()
        return AlbumCellModel(
            id: UUID(),
            title: usesRowStyle ? "归档" : "旅行相册",
            subtitle: usesRowStyle ? "12 项" : "24 项",
            coverTitle: nil,
            coverItem: usesRowStyle ? nil : item,
            coverImageRelativePath: nil,
            systemImage: usesRowStyle ? "archivebox" : "photo.on.rectangle",
            allowsDeletion: !usesRowStyle,
            usesRowStyle: usesRowStyle,
            isSecureAlbum: false
        )
    }

    static func sampleDetail() -> MediaItemDetailInfo {
        MediaItemDetailInfo(
            id: UUID(),
            title: "示例照片",
            mediaKindTitle: "照片",
            originalFilename: "IMG_0001.HEIC",
            contentTypeIdentifier: "public.heic",
            byteCount: 3_145_728,
            importedAt: .now.addingTimeInterval(-7200),
            lastExportedAt: .now.addingTimeInterval(-1800),
            originalCapturedAt: .now.addingTimeInterval(-86_400),
            locationLatitude: 51.507351,
            locationLongitude: -0.127758
        )
    }
}
