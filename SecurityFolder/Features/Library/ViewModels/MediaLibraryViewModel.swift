import Foundation
import Combine
import SwiftUI

struct MediaExportPreparationResult {
    let urls: [URL]
    let failedCount: Int
}

private struct ExportItemSnapshot: Sendable {
    let id: UUID
    let relativePath: String
    let originalFilename: String
    let space: VaultSpaceKind
}

@MainActor
final class MediaLibraryViewModel: ObservableObject {
    static let maximumBatchImportCount = 50

    let space: VaultSpaceKind

    @Published var albums: [VaultAlbum] = []
    @Published var items: [VaultItem] = []
    @Published var librarySortOption: LibraryAlbumSortOption = .manual
    @Published var lastErrorMessage: String?
    @Published var debugMessages: [String] = []
    @Published var isImportingMedia = false
    @Published var importProgressTitle = ""
    @Published var importProgressDetail = ""
    @Published var importProgressValue: Double = 0
    @Published var importResultSummary: MediaImportResultSummary?
    @Published var isMembershipUpsellPresented = false

    let coverSymbols = [
        "heart",
        "heart.fill",
        "star",
        "star.fill",
        "lock",
        "lock.shield",
        "key",
        "person",
        "person.crop.square",
        "person.2",
        "briefcase",
        "house",
        "building.2",
        "car",
        "airplane",
        "tram",
        "bicycle",
        "doc",
        "doc.text",
        "folder",
        "tray.full",
        "film",
        "video",
        "camera",
        "photo",
        "music.note",
        "headphones",
        "book",
        "bookmark",
        "tag",
        "gift",
        "cart",
        "creditcard",
        "banknote",
        "calendar",
        "clock",
        "location",
        "map",
        "globe",
        "cloud",
        "sun.max",
        "moon",
        "leaf",
        "flame",
        "bolt",
        "pawprint",
        "gamecontroller",
        "paintpalette",
        "archivebox"
    ]

    private let metadataStore: EncryptedMetadataStore
    private let fileStorage: VaultFileStorageService
    private var activeImportTask: Task<Void, Never>?

    init(
        space: VaultSpaceKind,
        metadataStore: EncryptedMetadataStore? = nil,
        fileStorage: VaultFileStorageService? = nil
    ) {
        self.space = space
        self.metadataStore = metadataStore ?? .shared
        self.fileStorage = fileStorage ?? .shared

        if let storedSortOption = LibraryAlbumSortOption(rawValue: UserDefaults.standard.string(forKey: librarySortOptionKey) ?? "") {
            self.librarySortOption = storedSortOption
        }

        bootstrapIfNeeded()
        refresh()
        importSharedPendingItemsIfNeeded()
    }

    var canShowRealData: Bool {
        true
    }

    var secureFeatureEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: AppSettingsKey.advancedDataProtectionEnabled) == nil {
            return AppSettingsKey.defaultAdvancedDataProtectionEnabled
        }
        return defaults.bool(forKey: AppSettingsKey.advancedDataProtectionEnabled)
    }

    var mediaAlbums: [AlbumCellModel] {
        guard canShowRealData else { return [] }

        return sortedLibraryAlbums(visibleLibraryAlbums)
        .map { album in
            let itemCount = filteredItemCount(for: album)
            let cover = resolvedCover(for: album)

            return AlbumCellModel(
                id: album.id,
                title: album.displayName,
                subtitle: itemCountText(itemCount),
                coverTitle: cover.title,
                coverItem: cover.item,
                coverImageRelativePath: album.coverImageRelativePath,
                systemImage: cover.systemImage ?? defaultSystemImage(for: album),
                allowsDeletion: !album.isSystemAlbum,
                usesRowStyle: false,
                isSecureAlbum: album.isSecureAlbum
            )
        }
    }

    var trashAlbum: AlbumCellModel? {
        guard canShowRealData, let album = albums.first(where: { $0.kind == .trash }) else {
            return nil
        }

        let trashItems = items.filter(\.isInTrash)
        return AlbumCellModel(
            id: album.id,
            title: album.displayName,
            subtitle: itemCountText(trashItems.count),
            coverTitle: nil,
            coverItem: nil,
            coverImageRelativePath: nil,
            systemImage: "trash",
            allowsDeletion: false,
            usesRowStyle: true,
            isSecureAlbum: false
        )
    }

    var archiveAlbum: AlbumCellModel? {
        guard canShowRealData, let album = albums.first(where: { $0.kind == .archive }) else {
            return nil
        }

        let archiveItems = items.filter { $0.isArchived && !$0.isInTrash }
        return AlbumCellModel(
            id: album.id,
            title: album.displayName,
            subtitle: itemCountText(archiveItems.count),
            coverTitle: nil,
            coverItem: nil,
            coverImageRelativePath: nil,
            systemImage: "archivebox",
            allowsDeletion: false,
            usesRowStyle: true,
            isSecureAlbum: false
        )
    }

    func refresh() {
        do {
            let snapshot = try metadataStore.loadSnapshot(for: space)
            albums = snapshot.albums
            let insertedRequiredAlbums = ensureRequiredAlbumsPresent()
            let fetchedItems = snapshot.items
            items = fetchedItems
            let didNormalizePaths = normalizeStoredPaths(in: fetchedItems)
            let didMigratePlaintextFiles = migratePlaintextFilesIfNeeded(in: fetchedItems)
            if didMigratePlaintextFiles {
                recordDebug("已将旧的明文媒体迁移为分块密文。")
            }
            let purgedItemIDs = purgeExpiredTrashItems(in: fetchedItems)
            items = fetchedItems.filter { !purgedItemIDs.contains($0.id) }
            if insertedRequiredAlbums || didNormalizePaths || !purgedItemIDs.isEmpty {
                try persistCurrentState()
                if insertedRequiredAlbums {
                    recordDebug("已补齐新的系统媒体库。")
                }
                if didNormalizePaths {
                    recordDebug("已修正旧媒体记录中的绝对路径。")
                }
                if !purgedItemIDs.isEmpty {
                    recordDebug("已清理超过回收站保留时长的媒体。")
                }
            }
            syncSharedImportAppState()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func album(for id: UUID) -> VaultAlbum? {
        albums.first(where: { $0.id == id })
    }

    func mediaItems(for albumID: UUID) -> [VaultItem] {
        guard let album = album(for: albumID) else { return [] }
        return items(for: album)
    }

    func mediaItems(for albumID: UUID, limit: Int) -> [VaultItem] {
        guard let album = album(for: albumID) else { return [] }
        return items(for: album, limit: limit)
    }

    func mediaItemsPage(for albumID: UUID, limit: Int) -> MediaItemsPage {
        guard let album = album(for: albumID) else {
            return MediaItemsPage(items: [], totalCount: 0)
        }
        #if DEBUG
        return MediaPerformanceLog.measure(
            "viewModel.mediaItemsPage",
            "album=\(MediaPerformanceLog.idHash(albumID)) limit=\(limit) totalItems=\(items.count)"
        ) {
            itemsPage(for: album, limit: limit)
        }
        #else
        return itemsPage(for: album, limit: limit)
        #endif
    }

    func mediaItemCount(for albumID: UUID) -> Int {
        guard let album = album(for: albumID) else { return 0 }
        return filteredItemCount(for: album)
    }

    func sortOption(for albumID: UUID) -> AlbumSortOption {
        album(for: albumID)?.sortOption ?? .newestFirst
    }

    func createAlbum(named name: String) {
        createAlbum(named: name, kind: .custom)
    }

    func createSecureAlbum(named name: String) {
        createAlbum(named: name, kind: .secureCustom)
    }

    private func createAlbum(named name: String, kind: MediaAlbumKind) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canShowRealData else { return }

        let fallbackName = kind.defaultAlbumName ?? String(localized: "新建相册")
        let resolvedName = availableAlbumName(for: trimmed.isEmpty ? fallbackName : trimmed)

        let nextOrderIndex = (albums.map(\.libraryOrderIndex).max() ?? 0) + 1
        albums.append(
            VaultAlbum(
                name: resolvedName,
                kind: kind,
                space: space,
                libraryOrderIndex: nextOrderIndex
            )
        )
        saveAndRefresh()
    }

    func deleteAlbum(id: UUID) {
        guard let targetAlbum = albums.first(where: { $0.id == id }),
              isUserManagedAlbum(targetAlbum) else {
            recordDebug("删除相册被拒绝：未找到相册或不是用户相册 [\(id.uuidString)]")
            return
        }

        let relatedItemCount = items.filter { $0.albums.contains(where: { $0.id == targetAlbum.id }) }.count
        recordDebug("准备删除相册：\(targetAlbum.name) [\(targetAlbum.id.uuidString)]，关联媒体数量：\(relatedItemCount)")

        for item in items where item.albums.contains(where: { $0.id == targetAlbum.id }) {
            item.albums.removeAll { $0.id == targetAlbum.id }
            item.updatedAt = .now
        }

        targetAlbum.items.removeAll()
        targetAlbum.coverItemID = nil
        targetAlbum.coverImageRelativePath = nil
        targetAlbum.coverSymbolName = nil
        targetAlbum.showsCover = false

        albums.removeAll { $0.id == targetAlbum.id }
        recordDebug("已从内存移除相册：\(targetAlbum.name) [\(targetAlbum.id.uuidString)]")
        saveAndRefresh()
    }

    func renameAlbum(id: UUID, to newName: String) {
        guard let album = album(for: id) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (album.kind == .custom || album.kind == .secureCustom), !trimmed.isEmpty, trimmed != album.name else { return }
        guard !albums.contains(where: { $0.id != id && $0.name == trimmed }) else { return }

        album.name = trimmed
        saveAndRefresh()
    }

    func duplicateAlbum(id: UUID) {
        guard let sourceAlbum = album(for: id),
              sourceAlbum.kind == .custom || sourceAlbum.kind == .secureCustom else { return }

        let duplicatedAlbum = VaultAlbum(
            name: availableAlbumCopyName(for: sourceAlbum.name),
            kind: sourceAlbum.kind,
            space: space,
            coverItemID: sourceAlbum.coverItemID,
            coverImageRelativePath: sourceAlbum.coverImageRelativePath,
            coverSymbolName: sourceAlbum.coverSymbolName,
            sortOption: sourceAlbum.sortOption,
            customOrderedItemIDs: sourceAlbum.customOrderedUUIDs,
            showsCover: sourceAlbum.showsCover,
            libraryOrderIndex: (albums.map(\.libraryOrderIndex).max() ?? 0) + 1
        )

        duplicatedAlbum.items = sourceAlbum.items
        albums.append(duplicatedAlbum)
        saveAndRefresh()
    }

    func assignCover(albumID: UUID) {
        guard let targetAlbum = album(for: albumID) else { return }
        guard !targetAlbum.isSecureAlbum else { return }
        let albumItems = filteredItems(for: targetAlbum)
        targetAlbum.coverItemID = albumItems.first?.id
        targetAlbum.coverImageRelativePath = nil
        targetAlbum.coverSymbolName = nil
        targetAlbum.showsCover = true
        saveAndRefresh()
    }

    func setImportedCoverImage(_ image: UIImage, for albumID: UUID) {
        guard let targetAlbum = album(for: albumID) else { return }
        guard !targetAlbum.isSecureAlbum else { return }

        do {
            targetAlbum.coverImageRelativePath = try fileStorage.storeAlbumCoverImage(image, albumID: albumID, space: space)
            targetAlbum.coverItemID = nil
            targetAlbum.coverSymbolName = nil
            targetAlbum.showsCover = true
            saveAndRefresh()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func clearCover(albumID: UUID) {
        guard let targetAlbum = album(for: albumID) else { return }
        targetAlbum.coverItemID = nil
        targetAlbum.coverImageRelativePath = nil
        targetAlbum.coverSymbolName = nil
        targetAlbum.showsCover = false
        saveAndRefresh()
    }

    func setCoverSymbol(_ symbolName: String, for albumID: UUID) {
        guard let targetAlbum = album(for: albumID) else { return }
        guard !targetAlbum.isSecureAlbum else { return }
        targetAlbum.coverSymbolName = symbolName
        targetAlbum.coverItemID = nil
        targetAlbum.coverImageRelativePath = nil
        targetAlbum.showsCover = true
        saveAndRefresh()
    }

    func setLibrarySortOption(_ option: LibraryAlbumSortOption) {
        librarySortOption = option
        UserDefaults.standard.set(option.rawValue, forKey: librarySortOptionKey)
    }

    func orderedLibraryAlbums() -> [VaultAlbum] {
        sortedLibraryAlbums(visibleLibraryAlbums)
    }

    func moveLibraryAlbums(from source: IndexSet, to destination: Int) {
        var ordered = orderedLibraryAlbums()
        moveElements(in: &ordered, from: source, to: destination)

        for (index, album) in ordered.enumerated() {
            album.libraryOrderIndex = index
        }

        librarySortOption = .custom
        saveAndRefresh()
    }

    func importFiles(_ urls: [URL], directlyInto albumID: UUID) {
        guard canShowRealData else { return }
        guard validateBatchImportCount(urls.count) else { return }
        guard checkImportQuota(requestedCount: urls.count) else {
            return
        }

        startImport(totalCount: urls.count, albumID: albumID, sourceDescription: String(localized: "文件"))
        activeImportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.importFileURLs(urls, directlyInto: albumID)
                self.finishImport(with: summary)
            } catch is CancellationError {
                self.cancelImportState(message: String(localized: "导入已停止。"))
            } catch {
                self.failImport(with: error.localizedDescription)
            }
        }
    }

    func importPickerAssets(_ pickerAssets: [ImportedPickerAsset], directlyInto albumID: UUID) {
        guard canShowRealData else { return }
        guard !pickerAssets.isEmpty else {
            recordDebug(String(localized: "系统相册没有返回可读取的数据。"))
            lastErrorMessage = String(localized: "没有读取到可导入的照片或视频数据。")
            return
        }
        guard validateBatchImportCount(pickerAssets.count) else { return }

        guard checkImportQuota(requestedCount: pickerAssets.count) else {
            return
        }

        startImport(totalCount: pickerAssets.count, albumID: albumID, sourceDescription: String(localized: "系统相册"))
        activeImportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.importPickerAssetPayloads(pickerAssets, directlyInto: albumID)
                self.finishImport(with: summary)
            } catch is CancellationError {
                self.cancelImportState(message: String(localized: "导入已停止。"))
            } catch {
                self.failImport(with: error.localizedDescription)
            }
        }
    }

    func canImportAdditionalItems(_ requestedCount: Int) -> Bool {
        validateBatchImportCount(requestedCount) && checkImportQuota(requestedCount: requestedCount)
    }

    func cancelImport() {
        activeImportTask?.cancel()
    }

    func exportURL(for itemID: UUID) -> URL? {
        guard let item = items.first(where: { $0.id == itemID }) else { return nil }
        let exportURL = try? fileStorage.decryptedTemporaryURL(
            for: item.relativePath,
            originalFilename: item.originalFilename,
            space: item.space
        )
        if exportURL != nil {
            item.lastExportedAt = .now
            try? persistCurrentState()
        }
        return exportURL
    }

    func exportURLs(for itemIDs: Set<UUID>) -> [URL] {
        let selectedItems = items.filter { itemIDs.contains($0.id) }
        var failedCount = 0
        let exportedURLs = selectedItems.compactMap { item -> URL? in
            do {
                return try fileStorage.decryptedTemporaryURL(
                    for: item.relativePath,
                    originalFilename: item.originalFilename,
                    space: item.space
                )
            } catch {
                failedCount += 1
                return nil
            }
        }

        if !exportedURLs.isEmpty {
            let exportedAt = Date.now
            for item in selectedItems {
                item.lastExportedAt = exportedAt
            }
            try? persistCurrentState()
        }

        if failedCount > 0 {
            lastErrorMessage = String.localizedStringWithFormat(
                String(localized: "%lld 个项目导出失败，其余项目已准备好分享。"),
                failedCount
            )
        }

        return exportedURLs
    }

    func prepareExportURLs(
        for itemIDs: Set<UUID>,
        progress: (@MainActor (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> MediaExportPreparationResult {
        let selectedItems = items.filter { itemIDs.contains($0.id) }
        let total = selectedItems.count
        guard total > 0 else {
            return MediaExportPreparationResult(urls: [], failedCount: 0)
        }

        let snapshots = selectedItems.map { item in
            ExportItemSnapshot(
                id: item.id,
                relativePath: item.relativePath,
                originalFilename: item.originalFilename,
                space: item.space
            )
        }
        let storage = fileStorage
        var exportedURLs: [URL] = []
        var failedCount = 0

        progress?(0, total)
        for (index, snapshot) in snapshots.enumerated() {
            let exportURL = await Task.detached(priority: .utility) {
                try? storage.decryptedTemporaryURL(
                    for: snapshot.relativePath,
                    originalFilename: snapshot.originalFilename,
                    space: snapshot.space
                )
            }.value

            if let exportURL {
                exportedURLs.append(exportURL)
            } else {
                failedCount += 1
            }
            progress?(index + 1, total)
        }

        if !exportedURLs.isEmpty {
            let exportedAt = Date.now
            for item in selectedItems {
                item.lastExportedAt = exportedAt
            }
            try? persistCurrentState()
        }

        return MediaExportPreparationResult(urls: exportedURLs, failedCount: failedCount)
    }

    func clearExportedTemporaryURLs(_ urls: [URL]) {
        for url in urls {
            fileStorage.clearDecryptedTemporaryURLIfManaged(url)
        }
    }

    func dismissError() {
        lastErrorMessage = nil
    }

    func dismissMembershipUpsell() {
        isMembershipUpsellPresented = false
    }

    func dismissImportResult() {
        importResultSummary = nil
    }

    func renameItem(id: UUID, to newName: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }

        item.name = availableItemName(for: trimmed, excluding: item.id)
        item.updatedAt = .now
        saveAndRefresh()
    }

    func details(for itemID: UUID) -> MediaItemDetailInfo? {
        guard let item = items.first(where: { $0.id == itemID }) else { return nil }

        return MediaItemDetailInfo(
            id: item.id,
            title: item.name,
            mediaKindTitle: item.mediaKind.title,
            originalFilename: item.originalFilename,
            contentTypeIdentifier: item.contentTypeIdentifier,
            byteCount: fileStorage.byteCount(for: item.relativePath),
            importedAt: item.importedAt,
            lastExportedAt: item.lastExportedAt,
            originalCapturedAt: item.originalCapturedAt,
            locationLatitude: item.locationLatitude,
            locationLongitude: item.locationLongitude
        )
    }

    func debugInfo(for albumID: UUID) -> [MediaFileDebugInfo] {
        mediaItems(for: albumID).map { item in
            let url = fileStorage.fileURL(for: item.relativePath)
            return MediaFileDebugInfo(
                id: item.id,
                name: item.name,
                mediaKind: item.mediaKind.title,
                contentType: item.contentTypeIdentifier,
                relativePath: item.relativePath,
                absolutePath: url.path(),
                exists: fileStorage.fileExists(at: item.relativePath),
                byteCount: fileStorage.byteCount(for: item.relativePath)
            )
        }
    }

    func trashRemainingDays(for item: VaultItem) -> Int {
        let retentionDays = trashRetentionDays
        let elapsedDays = Calendar.current.dateComponents([.day], from: item.updatedAt, to: .now).day ?? 0
        return max(retentionDays - elapsedDays, 0)
    }

    func handleDeletion(of itemID: UUID, from albumID: UUID) {
        guard let sourceAlbum = album(for: albumID),
              let item = items.first(where: { $0.id == itemID }) else {
            return
        }

        switch sourceAlbum.kind {
        case .allPhotos, .allVideos:
            moveItemToTrash(item)
        case .custom:
            item.albums.removeAll { $0.id == sourceAlbum.id }
            item.updatedAt = .now
        case .secureLibrary:
            removeFromStrongProtection(itemIDs: Set([itemID]))
            return
        case .secureCustom:
            item.albums.removeAll { $0.id == sourceAlbum.id }
            item.updatedAt = .now
        case .trash:
            permanentlyDelete(item)
        case .archive:
            moveItemToTrash(item)
        }

        saveAndRefresh()
    }

    func handleDeletion(of itemIDs: Set<UUID>, from albumID: UUID) {
        guard !itemIDs.isEmpty,
              let sourceAlbum = album(for: albumID) else {
            return
        }

        batchDeleteLog("batchDelete.start", "count=\(itemIDs.count) albumKind=\(sourceAlbum.kind.rawValue)")
        let targetItems = items.filter { itemIDs.contains($0.id) }
        guard !targetItems.isEmpty else {
            batchDeleteLog("batchDelete.metadataMutation.done", "count=0")
            return
        }

        switch sourceAlbum.kind {
        case .allPhotos, .allVideos, .archive:
            batchDeleteLog("batchDelete.fileCleanup.start", "count=\(targetItems.count)")
            for item in targetItems {
                moveItemToTrash(item)
            }
            batchDeleteLog("batchDelete.fileCleanup.finish", "count=\(targetItems.count)")
        case .custom:
            for item in targetItems {
                item.albums.removeAll { $0.id == sourceAlbum.id }
                item.updatedAt = .now
            }
        case .secureLibrary:
            removeFromStrongProtection(itemIDs: Set(targetItems.map(\.id)))
            return
        case .secureCustom:
            for item in targetItems {
                item.albums.removeAll { $0.id == sourceAlbum.id }
                item.updatedAt = .now
            }
        case .trash:
            batchDeleteLog("batchDelete.fileCleanup.start", "count=\(targetItems.count)")
            for item in targetItems {
                permanentlyDelete(item)
            }
            batchDeleteLog("batchDelete.fileCleanup.finish", "count=\(targetItems.count)")
        }

        batchDeleteLog("batchDelete.metadataMutation.done", "count=\(targetItems.count)")
        saveAndRefreshWithBatchDeleteLogs()
    }

    func restoreFromTrash(itemID: UUID) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }

        do {
            item.relativePath = try fileStorage.restoreFromTrash(relativePath: item.relativePath, space: item.space)
            if let companionPath = item.livePhotoCompanionRelativePath {
                item.livePhotoCompanionRelativePath = try? fileStorage.restoreFromTrash(relativePath: companionPath, space: item.space)
            }
            item.isInTrash = false
            item.updatedAt = .now
            saveAndRefresh()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func archive(itemIDs: Set<UUID>) {
        for item in items where itemIDs.contains(item.id) {
            item.isArchived = true
            item.isInTrash = false
            item.updatedAt = .now
        }
        saveAndRefresh()
    }

    func unarchive(itemID: UUID) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        item.isArchived = false
        item.updatedAt = .now
        saveAndRefresh()
    }

    func duplicate(itemIDs: Set<UUID>) {
        do {
            let sourceItems = items.filter { itemIDs.contains($0.id) }
            guard checkImportQuota(requestedCount: sourceItems.count) else { return }

            for sourceItem in sourceItems {
                let storedFile = try fileStorage.duplicateFile(at: sourceItem.relativePath, space: sourceItem.space)
                let duplicate = VaultItem(
                    name: availableItemName(for: copyName(for: sourceItem.name)),
                    createdAt: .now,
                    importedAt: .now,
                    lastExportedAt: nil,
                    originalCapturedAt: sourceItem.originalCapturedAt,
                    updatedAt: .now,
                    mediaKind: storedFile.mediaKind,
                    space: sourceItem.space,
                    isInTrash: false,
                    isArchived: false,
                    isStrongProtected: sourceItem.isStrongProtected,
                    relativePath: storedFile.relativePath,
                    originalFilename: storedFile.originalFilename,
                    contentTypeIdentifier: sourceItem.contentTypeIdentifier,
                    locationLatitude: sourceItem.locationLatitude,
                    locationLongitude: sourceItem.locationLongitude,
                    albums: sourceItem.albums
                )
                items.append(duplicate)
            }
            saveAndRefresh()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func albumSelectionOptions(for itemIDs: Set<UUID>, currentAlbumID: UUID) -> [AlbumSelectionOption] {
        guard let currentAlbum = album(for: currentAlbumID) else { return [] }
        let selectedItems = items.filter { itemIDs.contains($0.id) }
        let selectedAlbumNames = Set(selectedItems.flatMap { $0.albums.map(\.name) })
        let canTargetSecureAlbums = currentAlbum.kind == .secureLibrary || currentAlbum.kind == .secureCustom

        return albums
            .filter { candidate in
                guard candidate.id != currentAlbum.id else { return false }
                guard candidate.kind == .custom || candidate.kind == .secureCustom else { return false }
                guard secureFeatureEnabled || candidate.kind == .custom else { return false }
                if canTargetSecureAlbums {
                    return candidate.kind == .secureCustom
                }
                return candidate.kind == .custom
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { album in
                AlbumSelectionOption(
                    id: album.id,
                    title: album.displayName,
                    isSelected: selectedAlbumNames.contains(album.name)
                )
            }
    }

    func toggleMembership(of itemIDs: Set<UUID>, in destinationAlbumID: UUID) {
        guard let targetAlbum = album(for: destinationAlbumID),
              targetAlbum.kind == .custom || targetAlbum.kind == .secureCustom else { return }

        for item in items where itemIDs.contains(item.id) {
            if targetAlbum.kind == .secureCustom {
                guard item.isStrongProtected else { continue }
                if item.albums.contains(where: { $0.id == targetAlbum.id }) {
                    item.albums.removeAll { $0.id == targetAlbum.id }
                } else {
                    item.albums.append(targetAlbum)
                }
            } else {
                guard !item.isStrongProtected else { continue }
                if item.albums.contains(where: { $0.id == targetAlbum.id }) {
                    item.albums.removeAll { $0.id == targetAlbum.id }
                } else {
                    item.albums.append(targetAlbum)
                }
            }
            item.updatedAt = .now
        }

        saveAndRefresh()
    }

    func setMembership(of itemIDs: Set<UUID>, selectedAlbumIDs: Set<UUID>, currentAlbumID: UUID) {
        guard let currentAlbum = album(for: currentAlbumID) else { return }

        let availableAlbumIDs = Set(
            albumSelectionOptions(for: itemIDs, currentAlbumID: currentAlbumID)
                .map(\.id)
        )

        for item in items where itemIDs.contains(item.id) {
            let mutableAlbumIDs = Set(item.albums.map(\.id))

            for album in albums where availableAlbumIDs.contains(album.id) {
                if selectedAlbumIDs.contains(album.id) {
                    guard mutableAlbumIDs.contains(album.id) == false else { continue }

                    if currentAlbum.kind == .secureLibrary || currentAlbum.kind == .secureCustom {
                        guard item.isStrongProtected, album.kind == .secureCustom else { continue }
                    } else {
                        guard !item.isStrongProtected, album.kind == .custom else { continue }
                    }

                    item.albums.append(album)
                } else {
                    item.albums.removeAll { $0.id == album.id }
                }
            }

            item.updatedAt = .now
        }

        saveAndRefresh()
    }

    func enableStrongProtection(itemIDs: Set<UUID>) {
        guard !itemIDs.isEmpty else { return }
        for item in items where itemIDs.contains(item.id) {
            enableStrongProtection(for: item)
            item.updatedAt = .now
        }
        VaultCryptoService.shared.clearTemporaryFilesPreservingKeys()
        MediaThumbnailService.shared.clearCache()
        saveAndRefresh()
    }

    func removeFromStrongProtection(itemIDs: Set<UUID>) {
        guard !itemIDs.isEmpty else { return }
        let secureAlbumIDs = Set(albums.filter(\.isSecureAlbum).map(\.id))
        for item in items where itemIDs.contains(item.id) {
            item.isStrongProtected = false
            item.albums.removeAll { secureAlbumIDs.contains($0.id) }
            item.updatedAt = .now
        }
        VaultCryptoService.shared.clearTemporaryFilesPreservingKeys()
        MediaThumbnailService.shared.clearCache()
        saveAndRefresh()
    }

    func permanentlyDeleteStrongProtected(itemIDs: Set<UUID>) {
        guard !itemIDs.isEmpty else { return }
        let targetItems = items.filter { itemIDs.contains($0.id) && $0.isStrongProtected }
        batchDeleteLog("batchDelete.start", "count=\(targetItems.count) albumKind=strongProtected")
        batchDeleteLog("batchDelete.fileCleanup.start", "count=\(targetItems.count)")
        for item in targetItems {
            permanentlyDelete(item)
            fileStorage.clearDecryptedTemporaryFile(for: item.relativePath)
            MediaThumbnailService.shared.removeCachedThumbnail(for: item.id)
        }
        batchDeleteLog("batchDelete.fileCleanup.finish", "count=\(targetItems.count)")
        batchDeleteLog("batchDelete.metadataMutation.done", "count=\(targetItems.count)")
        saveAndRefreshWithBatchDeleteLogs()
    }

    func setSortOption(_ option: AlbumSortOption, for albumID: UUID) {
        guard let targetAlbum = album(for: albumID) else { return }
        targetAlbum.sortOption = option
        if option == .custom {
            refreshCustomOrder(for: albumID)
        }
        saveAndRefresh()
    }

    func moveItems(in albumID: UUID, from source: IndexSet, to destination: Int) {
        guard let targetAlbum = album(for: albumID) else { return }

        var orderedIDs = customOrderedIDs(for: albumID)
        let sourceIndexes = source.sorted()
        let movingItems = sourceIndexes.map { orderedIDs[$0] }

        for index in sourceIndexes.reversed() {
            orderedIDs.remove(at: index)
        }

        let adjustedDestination = min(destination, orderedIDs.count)
        orderedIDs.insert(contentsOf: movingItems, at: adjustedDestination)
        targetAlbum.customOrderedUUIDs = orderedIDs
        targetAlbum.sortOption = .custom
        saveAndRefresh()
    }
    
    /// 检查导入配额，免费用户超过上限时整批阻断并展示会员引导。
    /// 限额基于两个空间的合计可见媒体数，而非单个空间。
    private func checkImportQuota(requestedCount: Int) -> Bool {
        if SubscriptionManager.shared.currentTier == .fullMember {
            return true
        }

        let limit = SharedImportConstants.freeMediaLimit
        // Use the cross-space combined count so that 12 items in space A and
        // 8 items in space B together exhaust the 20-item free allowance.
        let sharedState = SharedImportStore.shared.appState
        let currentCount = sharedState.spaceACount + sharedState.spaceBCount

        guard currentCount < limit, currentCount + requestedCount <= limit else {
            isMembershipUpsellPresented = true
            lastErrorMessage = nil
            return false
        }

        return true
    }

    private func validateBatchImportCount(_ requestedCount: Int) -> Bool {
        guard requestedCount <= Self.maximumBatchImportCount else {
            lastErrorMessage = String.localizedStringWithFormat(
                String(localized: "为了避免批量导入时占用过多内存，单次最多只能导入 %lld 个项目。"),
                Self.maximumBatchImportCount
            )
            isMembershipUpsellPresented = false
            return false
        }

        return true
    }

    private func moveElements<T>(in array: inout [T], from source: IndexSet, to destination: Int) {
        let sourceIndexes = source.sorted()
        let movingElements = sourceIndexes.map { array[$0] }

        for index in sourceIndexes.reversed() {
            array.remove(at: index)
        }

        let adjustedDestination = min(destination, array.count)
        array.insert(contentsOf: movingElements, at: adjustedDestination)
    }

    private func ensureRequiredAlbumsPresent() -> Bool {
        var inserted = false

        if albums.contains(where: { $0.kind == .secureLibrary }) == false {
            albums.append(
                VaultAlbum(
                    name: MediaAlbumKind.secureLibrary.systemDisplayName ?? "Strong Protection Library",
                    kind: .secureLibrary,
                    space: space,
                    libraryOrderIndex: 2
                )
            )
            inserted = true
        }

        return inserted
    }

    private func bootstrapIfNeeded() {
        do {
            let snapshot = try metadataStore.loadSnapshot(for: space)
            if !snapshot.albums.isEmpty || !snapshot.items.isEmpty {
                return
            }

            let bootstrapAlbums = [
                VaultAlbum(name: MediaAlbumKind.allPhotos.systemDisplayName ?? "All Photos", kind: .allPhotos, space: space, libraryOrderIndex: 0),
                VaultAlbum(name: MediaAlbumKind.allVideos.systemDisplayName ?? "All Videos", kind: .allVideos, space: space, libraryOrderIndex: 1),
                VaultAlbum(name: MediaAlbumKind.secureLibrary.systemDisplayName ?? "Strong Protection Library", kind: .secureLibrary, space: space, libraryOrderIndex: 2),
                VaultAlbum(name: MediaAlbumKind.trash.systemDisplayName ?? "Trash", kind: .trash, space: space, libraryOrderIndex: 10_000),
                VaultAlbum(name: MediaAlbumKind.archive.systemDisplayName ?? "Archive", kind: .archive, space: space, libraryOrderIndex: 10_001)
            ]

            try metadataStore.saveSnapshot(space: space, albums: bootstrapAlbums, items: [])
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func moveItemToTrash(_ item: VaultItem) {
        do {
            if !item.isInTrash {
                item.relativePath = try fileStorage.moveToTrash(relativePath: item.relativePath, space: item.space)
                if let companionPath = item.livePhotoCompanionRelativePath {
                    item.livePhotoCompanionRelativePath = try? fileStorage.moveToTrash(relativePath: companionPath, space: item.space)
                }
            }
            item.isInTrash = true
            item.isArchived = false
            item.updatedAt = .now
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func permanentlyDelete(_ item: VaultItem) {
        do {
            try fileStorage.removeFile(relativePath: item.relativePath)
            if let companionPath = item.livePhotoCompanionRelativePath {
                try? fileStorage.removeFile(relativePath: companionPath)
            }
            items.removeAll { $0.id == item.id }
            for album in albums {
                album.items.removeAll { $0.id == item.id }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func purgeExpiredTrashItems(in fetchedItems: [VaultItem]) -> Set<UUID> {
        var purgedItemIDs = Set<UUID>()

        for item in fetchedItems where item.isInTrash && trashRemainingDays(for: item) <= 0 {
            permanentlyDelete(item)
            purgedItemIDs.insert(item.id)
        }

        return purgedItemIDs
    }

    private func userAlbum(for id: UUID) -> VaultAlbum? {
        guard let album = album(for: id),
              album.kind == .custom || album.kind == .secureCustom else { return nil }
        return album
    }

    private func enableStrongProtection(for item: VaultItem) {
        item.isStrongProtected = true
        item.isArchived = false
        item.isInTrash = false
        item.albums.removeAll { $0.kind == .custom }
    }

    private func startImport(totalCount: Int, albumID: UUID, sourceDescription: String) {
        isImportingMedia = true
        importProgressTitle = String(localized: "准备导入")
        importProgressDetail = String.localizedStringWithFormat(
            String(localized: "正在从%1$@读取 %2$lld 个项目到 %3$@"),
            sourceDescription,
            totalCount,
            album(for: albumID)?.displayName ?? String(localized: "当前相册")
        )
        importProgressValue = 0
        importResultSummary = nil
        lastErrorMessage = nil
        recordDebug(
            String.localizedStringWithFormat(
                String(localized: "开始从%1$@导入 %2$lld 个资源，目标相册：%3$@"),
                sourceDescription,
                totalCount,
                album(for: albumID)?.displayName ?? String(localized: "未知")
            )
        )
    }

    private func importFileURLs(_ urls: [URL], directlyInto albumID: UUID) async throws -> MediaImportResultSummary {
        let targetAlbum = userAlbum(for: albumID)
        let importIntoStrongProtection = album(for: albumID)?.kind.isSecure == true
        var photoCount = 0
        var videoCount = 0

        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            updateImportProgress(
                title: String(localized: "正在加密导入"),
                detail: String.localizedStringWithFormat(String(localized: "正在处理 %@"), url.lastPathComponent),
                currentIndex: index,
                totalCount: urls.count
            )

            let storedFile = try await fileStorage.importFile(from: url, space: space)
            recordDebug("文件导入成功：\(storedFile.originalFilename)，类型：\(storedFile.contentTypeIdentifier)，大小：\(storedFile.byteCount)，路径：\(storedFile.relativePath)")
            let item = VaultItem(
                name: availableItemName(for: storedFile.displayName),
                createdAt: .now,
                importedAt: .now,
                lastExportedAt: nil,
                originalCapturedAt: storedFile.originalCapturedAt,
                mediaKind: storedFile.mediaKind,
                space: space,
                relativePath: storedFile.relativePath,
                originalFilename: storedFile.originalFilename,
                contentTypeIdentifier: storedFile.contentTypeIdentifier,
                locationLatitude: storedFile.locationLatitude,
                locationLongitude: storedFile.locationLongitude
            )

            if let targetAlbum {
                item.albums.append(targetAlbum)
            }
            if importIntoStrongProtection {
                enableStrongProtection(for: item)
            }

            switch storedFile.mediaKind {
            case .photo, .livePhoto: photoCount += 1
            case .video: videoCount += 1
            }

            items.append(item)
            updateImportProgress(
                title: String(localized: "写入媒体索引"),
                detail: String.localizedStringWithFormat(String(localized: "已完成 %1$lld / %2$lld"), index + 1, urls.count),
                currentIndex: index + 1,
                totalCount: urls.count
            )
        }

        saveAndRefresh()
        recordDebug("文件导入完成，当前媒体数量：\(items.count)")
        return MediaImportResultSummary(photoCount: photoCount, videoCount: videoCount)
    }

    private func importPickerAssetPayloads(_ pickerAssets: [ImportedPickerAsset], directlyInto albumID: UUID) async throws -> MediaImportResultSummary {
        let targetAlbum = userAlbum(for: albumID)
        let importIntoStrongProtection = album(for: albumID)?.kind.isSecure == true
        var photoCount = 0
        var videoCount = 0
        var nextImportedMediaNumber = nextImportedMediaOrdinal()

        for (index, pickerAsset) in pickerAssets.enumerated() {
            try Task.checkCancellation()
            let fallbackName = String.localizedStringWithFormat(
                String(localized: "导入媒体%lld"),
                nextImportedMediaNumber
            )
            nextImportedMediaNumber += 1
            updateImportProgress(
                title: String(localized: "正在加密导入"),
                detail: String.localizedStringWithFormat(String(localized: "正在处理 %@"), fallbackName),
                currentIndex: index,
                totalCount: pickerAssets.count
            )

            let fileURL = pickerAsset.fileURL
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let storedFile = try await fileStorage.importFile(from: fileURL, space: space)
            recordDebug("相册导入成功：\(storedFile.originalFilename)，类型：\(storedFile.contentTypeIdentifier)，大小：\(storedFile.byteCount)，路径：\(storedFile.relativePath)")

            // Import the companion video for Live Photos, then clean up the temp file.
            var companionRelativePath: String? = nil
            if let companionURL = pickerAsset.companionVideoURL {
                defer { try? FileManager.default.removeItem(at: companionURL) }
                companionRelativePath = try fileStorage.importCompanionFile(from: companionURL, space: space)
            }

            let effectiveMediaKind: MediaKind = (companionRelativePath != nil) ? .livePhoto : storedFile.mediaKind

            let item = VaultItem(
                name: fallbackName,
                createdAt: .now,
                importedAt: .now,
                lastExportedAt: nil,
                originalCapturedAt: storedFile.originalCapturedAt,
                mediaKind: effectiveMediaKind,
                space: space,
                relativePath: storedFile.relativePath,
                originalFilename: storedFile.originalFilename,
                contentTypeIdentifier: storedFile.contentTypeIdentifier,
                locationLatitude: storedFile.locationLatitude,
                locationLongitude: storedFile.locationLongitude,
                livePhotoCompanionRelativePath: companionRelativePath
            )

            if let targetAlbum {
                item.albums.append(targetAlbum)
            }
            if importIntoStrongProtection {
                enableStrongProtection(for: item)
            }

            switch effectiveMediaKind {
            case .photo, .livePhoto: photoCount += 1
            case .video: videoCount += 1
            }

            items.append(item)
            updateImportProgress(
                title: String(localized: "写入媒体索引"),
                detail: String.localizedStringWithFormat(String(localized: "已完成 %1$lld / %2$lld"), index + 1, pickerAssets.count),
                currentIndex: index + 1,
                totalCount: pickerAssets.count
            )
        }

        saveAndRefresh()
        recordDebug("系统相册导入完成，当前媒体数量：\(items.count)")
        return MediaImportResultSummary(photoCount: photoCount, videoCount: videoCount)
    }

    private func updateImportProgress(title: String, detail: String, currentIndex: Int, totalCount: Int) {
        importProgressTitle = title
        importProgressDetail = detail
        let safeTotal = max(totalCount, 1)
        importProgressValue = min(max(Double(currentIndex) / Double(safeTotal), 0), 1)
    }

    private func finishImport(with summary: MediaImportResultSummary) {
        activeImportTask = nil
        isImportingMedia = false
        importProgressValue = 1
        importResultSummary = summary
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func failImport(with message: String) {
        activeImportTask = nil
        isImportingMedia = false
        lastErrorMessage = message
        recordDebug("媒体导入失败：\(message)")
    }

    private func cancelImportState(message: String) {
        activeImportTask = nil
        isImportingMedia = false
        lastErrorMessage = message
        recordDebug(message)
    }

    func importSharedPendingItemsIfNeeded() {
        let store = SharedImportStore.shared
        let pendingEntries = store.pendingEntries.filter { $0.spaceRawValue == space.rawValue }
        guard !pendingEntries.isEmpty, !isImportingMedia else { return }
        guard validateBatchImportCount(pendingEntries.count) else { return }
        guard checkImportQuota(requestedCount: pendingEntries.count) else { return }
        guard let albumID = albums.first(where: { $0.kind == .allPhotos })?.id ?? albums.first?.id else { return }

        do {
            let urls = try pendingEntries.map { try store.fileURL(for: $0) }
            startImport(totalCount: urls.count, albumID: albumID, sourceDescription: String(localized: "分享扩展"))
            activeImportTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let summary = try await self.importFileURLs(urls, directlyInto: albumID)
                    store.removeEntries(pendingEntries)
                    self.finishImport(with: summary)
                } catch is CancellationError {
                    self.cancelImportState(message: String(localized: "分享导入已停止。"))
                } catch {
                    self.failImport(with: error.localizedDescription)
                }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func saveAndRefresh() {
        do {
            recordDebug("开始保存元数据：albums=\(albums.count) items=\(items.count)")
            try persistCurrentState()
            recordDebug("元数据保存成功，开始 refresh()")
            refresh()
            recordDebug("refresh() 完成：albums=\(albums.count) items=\(items.count)")
        } catch {
            lastErrorMessage = error.localizedDescription
            recordDebug("保存加密元数据失败：\(error.localizedDescription)")
        }
    }

    private func saveAndRefreshWithBatchDeleteLogs() {
        do {
            batchDeleteLog("batchDelete.save.begin", "albums=\(albums.count) items=\(items.count)")
            recordDebug("开始保存元数据：albums=\(albums.count) items=\(items.count)")
            try persistCurrentState()
            batchDeleteLog("batchDelete.save.finish", "albums=\(albums.count) items=\(items.count)")
            recordDebug("元数据保存成功，开始 refresh()")
            batchDeleteLog("batchDelete.refresh.begin", "")
            refresh()
            batchDeleteLog("batchDelete.refresh.finish", "albums=\(albums.count) items=\(items.count)")
            recordDebug("refresh() 完成：albums=\(albums.count) items=\(items.count)")
        } catch {
            lastErrorMessage = error.localizedDescription
            recordDebug("保存加密元数据失败：\(error.localizedDescription)")
        }
    }

    private func persistCurrentState() throws {
        try metadataStore.saveSnapshot(space: space, albums: albums, items: items)
        syncSharedImportAppState()
    }

    private func recordDebug(_ message: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)"
        debugMessages.insert(line, at: 0)
        debugMessages = Array(debugMessages.prefix(80))
        print("[MediaLibraryDebug] \(line)")
    }

    private func batchDeleteLog(_ name: String, _ details: String) {
        #if DEBUG
        let suffix = details.isEmpty ? "" : " \(details)"
        print("[MediaLibraryDebug] \(name)\(suffix)")
        #endif
    }

    private func normalizeStoredPaths(in fetchedItems: [VaultItem]) -> Bool {
        var didChange = false

        for item in fetchedItems {
            let normalizedPath = fileStorage.normalizedRelativePath(for: item.relativePath)
            if normalizedPath != item.relativePath {
                recordDebug("修正路径：\(item.relativePath) -> \(normalizedPath)")
                item.relativePath = normalizedPath
                item.updatedAt = .now
                didChange = true
            }
        }

        return didChange
    }

    private func migratePlaintextFilesIfNeeded(in fetchedItems: [VaultItem]) -> Bool {
        var didMigrate = false

        for item in fetchedItems {
            do {
                if try fileStorage.migrateFileToEncryptedStorageIfNeeded(relativePath: item.relativePath, space: item.space) {
                    didMigrate = true
                }
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }

        return didMigrate
    }

    private func items(for album: VaultAlbum, limit: Int? = nil) -> [VaultItem] {
        if let limit {
            return itemsPage(for: album, limit: limit).items
        }

        let filteredItems = filteredItems(for: album)
        let sortedItems: [VaultItem]

        switch album.sortOption {
        case .newestFirst:
            sortedItems = filteredItems.sorted { $0.createdAt > $1.createdAt }
        case .oldestFirst:
            sortedItems = filteredItems.sorted { $0.createdAt < $1.createdAt }
        case .nameAscending:
            sortedItems = filteredItems.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            sortedItems = filteredItems.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .custom:
            let rank = customRank(for: album)
            sortedItems = filteredItems.sorted {
                let left = rank[$0.id] ?? .max
                let right = rank[$1.id] ?? .max
                if left != right {
                    return left < right
                }
                return $0.createdAt > $1.createdAt
            }
        }

        guard let limit, sortedItems.count > limit else {
            return sortedItems
        }
        return Array(sortedItems.prefix(limit))
    }

    private func itemsPage(for album: VaultAlbum, limit: Int) -> MediaItemsPage {
        let safeLimit = max(limit, 0)
        guard safeLimit > 0 else {
            return MediaItemsPage(items: [], totalCount: filteredItemCount(for: album))
        }

        #if DEBUG
        let albumDetails = "album=\(MediaPerformanceLog.idHash(album.id)) limit=\(safeLimit) sort=\(album.sortOption)"
        return MediaPerformanceLog.measure("viewModel.itemsPage.filterSort", albumDetails) {
            itemsPageBody(for: album, limit: safeLimit)
        }
        #else
        return itemsPageBody(for: album, limit: safeLimit)
        #endif
    }

    private func itemsPageBody(for album: VaultAlbum, limit safeLimit: Int) -> MediaItemsPage {
        switch album.sortOption {
        case .newestFirst:
            return topItemsPage(for: album, limit: safeLimit) { $0.createdAt > $1.createdAt }
        case .oldestFirst:
            return topItemsPage(for: album, limit: safeLimit) { $0.createdAt < $1.createdAt }
        case .nameAscending:
            return topItemsPage(for: album, limit: safeLimit) {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .nameDescending:
            return topItemsPage(for: album, limit: safeLimit) {
                $0.name.localizedStandardCompare($1.name) == .orderedDescending
            }
        case .custom:
            let rank = customRank(for: album)
            return topItemsPage(for: album, limit: safeLimit) { left, right in
                let leftRank = rank[left.id] ?? Int.max
                let rightRank = rank[right.id] ?? Int.max
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return left.createdAt > right.createdAt
            }
        }
    }

    private func topItemsPage(
        for album: VaultAlbum,
        limit: Int,
        areInIncreasingOrder: (VaultItem, VaultItem) -> Bool
    ) -> MediaItemsPage {
        #if DEBUG
        let start = CFAbsoluteTimeGetCurrent()
        let albumHash = MediaPerformanceLog.idHash(album.id)
        MediaPerformanceLog.setStage("items-filter-sort")
        #endif
        var totalCount = 0
        var pageItems: [VaultItem] = []
        pageItems.reserveCapacity(limit)

        for item in items where itemMatches(item, album: album) {
            totalCount += 1
            pageItems.append(item)

            if pageItems.count > limit * 2 {
                pageItems.sort(by: areInIncreasingOrder)
                pageItems.removeSubrange(limit..<pageItems.count)
            }
        }

        pageItems.sort(by: areInIncreasingOrder)
        if pageItems.count > limit {
            pageItems.removeSubrange(limit..<pageItems.count)
        }
        #if DEBUG
        MediaPerformanceLog.mark(
            "viewModel.topItemsPage.complete",
            "album=\(albumHash) total=\(totalCount) page=\(pageItems.count) scanned=\(items.count) duration=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - start) * 1000))ms"
        )
        #endif
        return MediaItemsPage(items: pageItems, totalCount: totalCount)
    }

    private func filteredItems(for album: VaultAlbum) -> [VaultItem] {
        #if DEBUG
        return MediaPerformanceLog.measure(
            "viewModel.filteredItems",
            "album=\(MediaPerformanceLog.idHash(album.id)) totalItems=\(items.count)"
        ) {
            items.filter { itemMatches($0, album: album) }
        }
        #else
        items.filter { itemMatches($0, album: album) }
        #endif
    }

    private func filteredItemCount(for album: VaultAlbum) -> Int {
        #if DEBUG
        return MediaPerformanceLog.measure(
            "viewModel.filteredItemCount",
            "album=\(MediaPerformanceLog.idHash(album.id)) totalItems=\(items.count)"
        ) {
            items.reduce(into: 0) { count, item in
                if itemMatches(item, album: album) {
                    count += 1
                }
            }
        }
        #else
        items.reduce(into: 0) { count, item in
            if itemMatches(item, album: album) {
                count += 1
            }
        }
        #endif
    }

    private func customRank(for album: VaultAlbum) -> [UUID: Int] {
        album.customOrderedUUIDs.enumerated().reduce(into: [UUID: Int]()) { partialResult, pair in
            partialResult[pair.element] = partialResult[pair.element] ?? pair.offset
        }
    }

    private func firstFilteredItem(for album: VaultAlbum) -> VaultItem? {
        items.first { itemMatches($0, album: album) }
    }

    private func itemMatches(_ item: VaultItem, album: VaultAlbum) -> Bool {
        switch album.kind {
        case .allPhotos:
            return (item.mediaKind == .photo || item.mediaKind == .livePhoto) && !item.isInTrash && !item.isArchived && !item.isStrongProtected
        case .allVideos:
            return item.mediaKind == .video && !item.isInTrash && !item.isArchived && !item.isStrongProtected
        case .custom:
            return !item.isInTrash && !item.isArchived && !item.isStrongProtected && item.albums.contains(where: { $0.id == album.id })
        case .secureLibrary:
            return !item.isInTrash && !item.isArchived && item.isStrongProtected
        case .secureCustom:
            return !item.isInTrash && !item.isArchived && item.isStrongProtected && item.albums.contains(where: { $0.id == album.id })
        case .trash:
            return item.isInTrash
        case .archive:
            return item.isArchived && !item.isInTrash
        }
    }

    private func refreshCustomOrder(for albumID: UUID) {
        guard let targetAlbum = album(for: albumID) else { return }
        targetAlbum.customOrderedUUIDs = customOrderedIDs(for: albumID)
    }

    private func customOrderedIDs(for albumID: UUID) -> [UUID] {
        guard let targetAlbum = album(for: albumID) else { return [] }

        let filtered = filteredItems(for: targetAlbum)
        let currentIDs = Set(filtered.map(\.id))
        let existing = targetAlbum.customOrderedUUIDs.filter { currentIDs.contains($0) }
        let missing = filtered.map(\.id).filter { !existing.contains($0) }
        return existing + missing
    }

    private func resolvedCover(for album: VaultAlbum) -> (title: String?, item: VaultItem?, systemImage: String?) {
        guard album.showsCover else {
            return (nil, nil, nil)
        }

        if let coverSymbolName = album.coverSymbolName {
            return (nil, nil, coverSymbolName)
        }

        if let coverItemID = album.coverItemID,
           let coverItem = items.first(where: { $0.id == coverItemID && itemMatches($0, album: album) }) {
            return (coverItem.name, coverItem, nil)
        }

        if let firstItem = firstFilteredItem(for: album) {
            return (firstItem.name, firstItem, nil)
        }

        return (nil, nil, nil)
    }

    private func sortedLibraryAlbums(_ source: [VaultAlbum]) -> [VaultAlbum] {
        switch librarySortOption {
        case .manual:
            return source.sorted { left, right in
                left.libraryOrderIndex < right.libraryOrderIndex
            }
        case .nameAscending:
            return source.sorted { left, right in
                let comparison = left.displayName.localizedStandardCompare(right.displayName)
                if comparison == .orderedSame {
                    return left.libraryOrderIndex < right.libraryOrderIndex
                }
                return comparison == .orderedAscending
            }
        case .nameDescending:
            return source.sorted { left, right in
                let comparison = left.displayName.localizedStandardCompare(right.displayName)
                if comparison == .orderedSame {
                    return left.libraryOrderIndex < right.libraryOrderIndex
                }
                return comparison == .orderedDescending
            }
        case .custom:
            return source.sorted { left, right in
                return left.libraryOrderIndex < right.libraryOrderIndex
            }
        }
    }

    private func defaultSystemImage(for album: VaultAlbum) -> String {
        switch album.kind {
        case .allVideos:
            return "video"
        case .allPhotos:
            return "photo"
        case .secureLibrary:
            return "lock.shield"
        case .secureCustom:
            return "lock.rectangle.stack"
        case .custom:
            return "photo.on.rectangle"
        case .trash:
            return "trash"
        case .archive:
            return "archivebox"
        }
    }

    private func isUserManagedAlbum(_ album: VaultAlbum) -> Bool {
        album.kind == .custom || album.kind == .secureCustom
    }

    private var librarySortOptionKey: String {
        switch space {
        case .spaceA:
            AppSettingsKey.spaceALibrarySortOption
        case .spaceB:
            AppSettingsKey.spaceBLibrarySortOption
        }
    }

    private var visibleLibraryAlbums: [VaultAlbum] {
        albums.filter { album in
            album.kind != .trash &&
            album.kind != .archive &&
            (secureFeatureEnabled || !album.isSecureAlbum)
        }
    }

    private func availableAlbumName(for name: String, excluding excludedID: UUID? = nil) -> String {
        var candidate = name
        var index = 2

        while albums.contains(where: { $0.id != excludedID && $0.name == candidate }) {
            candidate = "\(name) \(index)"
            index += 1
        }

        return candidate
    }

    private func availableAlbumCopyName(for name: String) -> String {
        var candidate = copyName(for: name)
        var index = 2

        while albums.contains(where: { $0.name == candidate }) {
            candidate = String.localizedStringWithFormat(String(localized: "%1$@ 副本 %2$lld"), name, index)
            index += 1
        }

        return candidate
    }

    private func availableItemName(for name: String, excluding excludedID: UUID? = nil) -> String {
        var candidate = name
        var index = 2

        while items.contains(where: { $0.id != excludedID && $0.name == candidate }) {
            candidate = "\(name) \(index)"
            index += 1
        }

        return candidate
    }

    private func nextImportedMediaOrdinal() -> Int {
        let prefix = String(localized: "导入媒体")
        let ordinals = items.compactMap { item -> Int? in
            guard item.name.hasPrefix(prefix) else { return nil }
            let suffix = item.name.dropFirst(prefix.count)
            return Int(suffix)
        }
        return (ordinals.max() ?? 0) + 1
    }

    private func itemCountText(_ count: Int) -> String {
        String.localizedStringWithFormat(String(localized: "%lld 项"), count)
    }

    private func copyName(for name: String) -> String {
        String.localizedStringWithFormat(String(localized: "%@ 副本"), name)
    }

    private var trashRetentionDays: Int {
        let storedDays = UserDefaults.standard.integer(forKey: AppSettingsKey.trashRetentionDays)
        return storedDays > 0 ? storedDays : AppSettingsKey.defaultTrashRetentionDays
    }

    private func syncSharedImportAppState() {
        var state = SharedImportStore.shared.appState
        switch space {
        case .spaceA:
            state.spaceACount = items.count
        case .spaceB:
            state.spaceBCount = items.count
        }
        state.currentTierRawValue = SubscriptionManager.shared.currentTier.rawValue
        state.spaceADisplayName = SpaceDisplaySettings.displayName(for: .spaceA)
        state.spaceBDisplayName = SpaceDisplaySettings.displayName(for: .spaceB)
        state.isSpaceBConfigured = AppLockService().isPasscodeConfigured(for: .spaceB)
        SharedImportStore.shared.appState = state
    }
}
