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
}
