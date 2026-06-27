import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import UIKit

private struct PreviewSelection: Identifiable {
    let id: UUID
}

private struct PendingMediaOperation: Identifiable {
    enum Kind: Equatable {
        case moveToTrash
        case removeFromAlbum
        case removeFromStrongProtection
        case permanentlyDelete
    }

    let id = UUID()
    let itemIDs: Set<UUID>
    let kind: Kind
    let title: String
    let message: String
    let confirmTitle: String
}

struct AlbumDetailView: View {
    @ObservedObject var viewModel: MediaLibraryViewModel
    let albumID: UUID
    @AppStorage(AppSettingsKey.advancedDataProtectionEnabled)
    private var advancedDataProtectionEnabled = AppSettingsKey.defaultAdvancedDataProtectionEnabled
    @AppStorage(AppSettingsKey.deleteImportedSystemAssetsAfterImport)
    private var deleteImportedSystemAssetsAfterImport = AppSettingsKey.defaultDeleteImportedSystemAssetsAfterImport

    @State private var selectedItemIDs = Set<UUID>()
    @State private var isSelecting = false
    @State private var showingManagedPhotoImporter = false
    @State private var showingFileImporter = false
    @State private var showingAlbumPicker = false
    @State private var showingCustomSort = false
    @State private var previewSelection: PreviewSelection?
    @State private var shareURLs: [URL] = []
    @State private var showingShareSheet = false
    @State private var pendingOperation: PendingMediaOperation?
    @State private var renamingItem: VaultItem?
    @State private var renameText = ""
    @State private var detailItemID: UUID?
    @State private var isDropTargeted = false
    @State private var dropOverlayResetToken = UUID()
    @State private var pendingImportedSystemAssetIdentifiers: [String] = []
    @State private var importedSystemAssetsDeletionPrompt: ImportedSystemAssetsDeletionPrompt?
    @State private var presentedImportResultSummary: MediaImportResultSummary?
    @State private var isPreparingExport = false
    @State private var exportPreparationCompletedCount = 0
    @State private var exportPreparationTotalCount = 0
    @State private var visibleItemLimit = 48
    @AppStorage("AlbumDetail.regularGridColumnCount")
    private var regularGridColumnCount = 5

    private let initialVisibleItemLimit = 48
    private let visibleItemBatchSize = 72

    private var platformAlbumBackground: Color {
        #if targetEnvironment(macCatalyst)
        Color(uiColor: .systemBackground)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    private var selectionBottomInset: CGFloat {
        isSelecting ? 110 : 16
    }

    private func navigationTitle(albumName: String?, selectedCount: Int, totalCount: Int) -> String {
        let title = albumName ?? String(localized: "相册")
        guard isSelecting else { return title }
        return String.localizedStringWithFormat(
            String(localized: "%1$@（%2$lld / %3$lld）"),
            title,
            selectedCount,
            totalCount
        )
    }

    private func loggedMediaItemsPage(limit: Int) -> MediaItemsPage {
        #if DEBUG
        return MediaPerformanceLog.measure(
            "album.viewModel.mediaItemsPage",
            "album=\(MediaPerformanceLog.idHash(albumID)) limit=\(limit)"
        ) {
            viewModel.mediaItemsPage(for: albumID, limit: limit)
        }
        #else
        return viewModel.mediaItemsPage(for: albumID, limit: limit)
        #endif
    }

    var body: some View {
        let page = loggedMediaItemsPage(limit: visibleItemLimit)
        let totalItemCount = page.totalCount
        let items = page.items
        let albumKind = viewModel.album(for: albumID)?.kind
        let currentSortOption = viewModel.sortOption(for: albumID)
        let isSecureAlbum = albumKind?.isSecure == true

        ScrollViewReader { scrollProxy in
            albumContent(
                items: items,
                totalItemCount: totalItemCount,
                albumKind: albumKind,
                isSecureAlbum: isSecureAlbum,
                scrollProxy: scrollProxy
            )
            .onDrop(of: DroppedMediaImportSupport.supportedTypeIdentifiers, isTargeted: $isDropTargeted) { providers in
                handleDroppedMedia(providers)
            }
            // Always-present overlay driven by opacity; toggling it with `if`
            // during a drag breaks Catalyst's drag tracking and leaves the
            // "Drop to import" overlay stuck on screen.
            .overlay {
                DropImportOverlayView()
                    .opacity(isDropTargeted ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
            }
            #if targetEnvironment(macCatalyst)
            .onChange(of: isDropTargeted) { _, isTargeted in
                guard isTargeted else { return }
                scheduleDropOverlayReset()
            }
            #endif
        }
        .onAppear {
            #if DEBUG
            if !isSecureAlbum {
                MediaPerformanceLog.beginAlbum(albumID: albumID, itemCount: totalItemCount, limit: visibleItemLimit)
            }
            #endif
        }
        .onChange(of: totalItemCount) { _, newValue in
            #if DEBUG
            if !isSecureAlbum {
                MediaPerformanceLog.updateAlbumItems(albumID: albumID, itemCount: newValue, limit: visibleItemLimit)
            }
            #endif
        }
        .navigationTitle(navigationTitle(albumName: viewModel.album(for: albumID)?.displayName, selectedCount: selectedItemIDs.count, totalCount: totalItemCount))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            topBarToolbar(currentSortOption: currentSortOption, albumKind: albumKind)
        }
        .overlay(alignment: .bottom) {
            if isSelecting {
                selectionActionBar(albumKind: albumKind)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .background(.clear)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.30, dampingFraction: 0.86), value: isSelecting)
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            pendingImportedSystemAssetIdentifiers = []
            viewModel.importFiles(urls, directlyInto: albumID)
        }
        .sheet(isPresented: $showingManagedPhotoImporter) {
            SystemPhotoImporterSheet(selectionLimit: MediaLibraryViewModel.maximumBatchImportCount) { importedAssets in
                showingManagedPhotoImporter = false
                guard !importedAssets.isEmpty else { return }
                pendingImportedSystemAssetIdentifiers = importedAssets.compactMap(\.assetIdentifier)
                print("[ImportCleanup][AlbumManaged] importedAssets=\(importedAssets.count) assetIDs=\(pendingImportedSystemAssetIdentifiers.count)")
                viewModel.importPickerAssets(importedAssets, directlyInto: albumID)
            }
        }
        .sheet(isPresented: $showingAlbumPicker) {
            AlbumSelectionSheet(viewModel: viewModel, currentAlbumID: albumID, selectedItemIDs: selectedItemIDs)
        }
        .sheet(isPresented: $showingCustomSort) {
            AlbumCustomSortView(viewModel: viewModel, albumID: albumID)
        }
        .sheet(isPresented: $showingShareSheet) {
            ActivityView(activityItems: shareURLs, onComplete: {
                viewModel.clearExportedTemporaryURLs(shareURLs)
                shareURLs.removeAll()
            })
        }
        .sheet(isPresented: $isPreparingExport) {
            exportPreparationSheet
        }
        .sheet(item: detailItemBinding) { detail in
            NavigationStack {
                MediaItemInfoView(detail: detail)
            }
        }
        .sheet(isPresented: importProgressSheetBinding) {
            mediaImportProgressSheet
        }
        .fullScreenCover(item: $previewSelection) { selection in
            let previewItems = viewModel.mediaItems(for: albumID)
            if albumKind?.isSecure == true, let selectedItem = previewItems.first(where: { $0.id == selection.id }) {
                SecureMediaPreviewView(
                    viewModel: viewModel,
                    albumID: albumID,
                    item: selectedItem
                )
            } else {
                MediaPreviewView(
                    viewModel: viewModel,
                    albumID: albumID,
                    items: previewItems,
                    initialItemID: selection.id
                )
            }
        }
        .alert(String(localized: "操作失败"), isPresented: errorAlertBinding) {
            Button(String(localized: "好")) {
                viewModel.dismissError()
            }
        } message: {
            Text(viewModel.lastErrorMessage ?? String(localized: "出现了一点问题。"))
        }
        .onChange(of: viewModel.importResultSummary?.id) { _, _ in
            presentImportResultIfNeeded()
        }
        .sheet(item: $presentedImportResultSummary) { summary in
            NavigationStack {
                List {
                    Section {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "已导入 %1$lld 张照片和 %2$lld 个视频。"),
                                Int64(summary.photoCount),
                                Int64(summary.videoCount)
                            )
                        )
                            .font(.body)
                            .foregroundStyle(.primary)
                    }

                    Section {
                        Button(String(localized: "知道了")) {
                            print("[ImportCleanup][Album] import result dismissed photoCount=\(summary.photoCount) videoCount=\(summary.videoCount) pendingIDs=\(pendingImportedSystemAssetIdentifiers.count) enabled=\(deleteImportedSystemAssetsAfterImport)")
                            showingManagedPhotoImporter = false
                            presentedImportResultSummary = nil
                            scheduleDeletePromptAfterImport(importedCount: summary.photoCount + summary.videoCount)
                        }
                    }
                }
                .navigationTitle(String(localized: "导入完成"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(item: $importedSystemAssetsDeletionPrompt) { prompt in
            NavigationStack {
                List {
                    Section {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "已成功导入 %lld 个项目。要不要把这些原始项目从系统图库里删掉？"),
                                Int64(prompt.importedCount)
                            )
                        )
                            .font(.body)
                            .foregroundStyle(.primary)
                    }

                    Section {
                        Button(String(localized: "删除原件"), role: .destructive) {
                            let assetIdentifiers = prompt.assetIdentifiers
                            importedSystemAssetsDeletionPrompt = nil
                            deleteImportedSystemAssets(assetIdentifiers)
                        }

                        Button(String(localized: "保留原件"), role: .cancel) {
                            importedSystemAssetsDeletionPrompt = nil
                        }
                    }
                }
                .navigationTitle(String(localized: "从系统图库删除？"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .alert(item: $pendingOperation) { pendingOperation in
            let primaryButton: Alert.Button = pendingOperation.kind == .removeFromStrongProtection
                ? .default(Text(pendingOperation.confirmTitle)) { performOperation(pendingOperation) }
                : .destructive(Text(pendingOperation.confirmTitle)) { performOperation(pendingOperation) }
            return Alert(
                title: Text(pendingOperation.title),
                message: Text(pendingOperation.message),
                primaryButton: primaryButton,
                secondaryButton: .cancel()
            )
        }
        .alert(String(localized: "重命名"), isPresented: renameAlertBinding) {
            TextField(String(localized: "名称"), text: $renameText)
            Button(String(localized: "取消"), role: .cancel) {
                renamingItem = nil
                renameText = ""
            }
            Button(String(localized: "保存")) {
                guard let renamingItem else { return }
                viewModel.renameItem(id: renamingItem.id, to: renameText)
                self.renamingItem = nil
                renameText = ""
            }
        } message: {
            Text(String(localized: "修改这个项目在应用内显示的名称。"))
        }
        .overlay {
            if totalItemCount == 0 {
                ContentUnavailableView(String(localized: "暂无内容"), systemImage: "photo.on.rectangle.angled")
            }
        }
        .onChange(of: albumID) { _, _ in
            visibleItemLimit = initialVisibleItemLimit
        }
        .onChange(of: totalItemCount) { _, newCount in
            visibleItemLimit = min(max(visibleItemLimit, initialVisibleItemLimit), max(newCount, initialVisibleItemLimit))
        }
    }

    @ViewBuilder
    private func albumContent(
        items: [VaultItem],
        totalItemCount: Int,
        albumKind: MediaAlbumKind?,
        isSecureAlbum: Bool,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        if isSecureAlbum {
            secureAlbumContent(items: items, totalItemCount: totalItemCount, albumKind: albumKind, scrollProxy: scrollProxy)
                .background(platformAlbumBackground.ignoresSafeArea())
        } else {
            regularAlbumContent(items: items, totalItemCount: totalItemCount, albumKind: albumKind, scrollProxy: scrollProxy)
                .background(platformAlbumBackground)
        }
    }

    @ViewBuilder
    private func regularAlbumContent(
        items: [VaultItem],
        totalItemCount: Int,
        albumKind: MediaAlbumKind?,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        ZoomableMediaGridView(
            items: items,
            columnCount: $regularGridColumnCount,
            contentInsetBottom: selectionBottomInset,
            renderToken: 0,
            selectedItemIDs: selectedItemIDs,
            isSelecting: isSelecting,
            onReachEnd: { item in
                loadMoreItemsIfNeeded(currentItem: item, displayedItems: items, totalItemCount: totalItemCount)
            },
            onOpenItem: { itemID in
                previewSelection = PreviewSelection(id: itemID)
            },
            onSelectionChanged: { nextSelection in
                selectedItemIDs = nextSelection
            },
            onSelectionModeChanged: { isEnabled in
                if isEnabled {
                    if !isSelecting {
                        isSelecting = true
                    }
                } else {
                    isSelecting = false
                    selectedItemIDs.removeAll()
                }
            },
            footerText: { item in
                albumKind == .trash ? trashFooterText(for: item) : nil
            },
            onContextMenuForItem: { item in
                buildRegularGridContextMenu(for: item, albumKind: albumKind)
            },
            onDragItem: makeDragItemProvider
        )
        .ignoresSafeArea(.container, edges: .bottom)
    }

    /// macOS Catalyst drag-out: decrypt to a temp file and wrap in NSItemProvider.
    /// The provider is backed by `viewModel.exportURL` which returns an already-
    /// decrypted temp file — the same file used for the regular "export / share"
    /// action. Never exposes the raw encrypted vault file.
    ///
    /// Returns nil when:
    ///   - the album is trash or archive (no export allowed from those views)
    ///   - the item's temp file cannot be produced (iCloud asset unavailable, etc.)
    private func makeDragItemProvider(for item: VaultItem) -> NSItemProvider? {
        guard let exportURL = viewModel.exportURL(for: item.id) else { return nil }
        let provider = NSItemProvider(contentsOf: exportURL)
        provider?.suggestedName = item.name
        return provider
    }

    private func buildRegularGridContextMenu(for item: VaultItem, albumKind: MediaAlbumKind?) -> UIMenu {
        var actions: [UIMenuElement] = []

        actions.append(UIAction(title: String(localized: "选择"), image: UIImage(systemName: "checkmark.circle")) { _ in
            isSelecting = true
            selectedItemIDs = [item.id]
        })
        actions.append(UIAction(title: String(localized: "重命名"), image: UIImage(systemName: "pencil")) { _ in
            renameText = item.name
            renamingItem = item
        })
        actions.append(UIAction(title: String(localized: "显示详情"), image: UIImage(systemName: "info.circle")) { _ in
            detailItemID = item.id
        })

        let exportURL = viewModel.exportURL(for: item.id)
        if let exportURL {
            actions.append(UIAction(title: String(localized: "导出"), image: UIImage(systemName: "square.and.arrow.up")) { _ in
                shareURLs = [exportURL]
                showingShareSheet = true
            })
        }

        switch albumKind {
        case .trash:
            actions.append(UIAction(title: String(localized: "恢复"), image: UIImage(systemName: "arrow.uturn.backward")) { _ in
                viewModel.restoreFromTrash(itemID: item.id)
            })
            actions.append(UIAction(title: String(localized: "彻底删除"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                requestDestructiveOperation(for: Set([item.id]), albumKind: albumKind)
            })
        case .archive:
            actions.append(UIAction(title: String(localized: "放回"), image: UIImage(systemName: "arrow.uturn.backward.circle")) { _ in
                viewModel.unarchive(itemID: item.id)
            })
            actions.append(UIAction(title: String(localized: "移到回收站"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                requestDestructiveOperation(for: Set([item.id]), albumKind: albumKind)
            })
        default:
            actions.append(UIAction(title: String(localized: "复制"), image: UIImage(systemName: "plus.square.on.square")) { _ in
                viewModel.duplicate(itemIDs: Set([item.id]))
            })
            actions.append(UIAction(title: String(localized: "添加到相册"), image: UIImage(systemName: "text.badge.plus")) { _ in
                selectedItemIDs = [item.id]
                showingAlbumPicker = true
            })
            if advancedDataProtectionEnabled {
                actions.append(UIAction(title: String(localized: "移入强加密媒体库"), image: UIImage(systemName: "lock.shield")) { _ in
                    viewModel.enableStrongProtection(itemIDs: Set([item.id]))
                })
            }
            actions.append(UIAction(title: String(localized: "归档"), image: UIImage(systemName: "archivebox")) { _ in
                viewModel.archive(itemIDs: Set([item.id]))
            })
            actions.append(UIAction(title: destructiveTitle, image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                requestDestructiveOperation(for: Set([item.id]), albumKind: albumKind)
            })
        }

        return UIMenu(children: actions)
    }

    @ViewBuilder
    private func secureAlbumContent(
        items: [VaultItem],
        totalItemCount: Int,
        albumKind: MediaAlbumKind?,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        SecureMediaListView(
            items: items,
            albumKind: albumKind,
            selectedItemIDs: selectedItemIDs,
            isSelecting: isSelecting,
            contentInsetBottom: selectionBottomInset,
            footerText: { item in
                albumKind == .trash ? trashFooterText(for: item) : nil
            },
            onReachEnd: { item in
                loadMoreItemsIfNeeded(currentItem: item, displayedItems: items, totalItemCount: totalItemCount)
            },
            onOpenItem: { itemID in
                previewSelection = PreviewSelection(id: itemID)
            },
            onSelectionChanged: { nextSelection in
                selectedItemIDs = nextSelection
            },
            onSelectionModeChanged: { isEnabled in
                isSelecting = isEnabled
                if !isEnabled {
                    selectedItemIDs.removeAll()
                }
            },
            onRenameItem: { item in
                renameText = item.name
                renamingItem = item
            },
            onShowDetails: { item in
                detailItemID = item.id
            },
            onAddToSecureAlbum: { item in
                selectedItemIDs = [item.id]
                showingAlbumPicker = true
            },
            onRemoveFromStrongProtection: { item in
                requestRemoveFromStrongProtection(for: Set([item.id]))
            },
            onDeleteItem: { item in
                requestDestructiveOperation(for: Set([item.id]), albumKind: albumKind)
            },
            onPermanentDeleteItem: { item in
                requestPermanentDeletion(for: Set([item.id]))
            }
        )
        .background(platformAlbumBackground.ignoresSafeArea())
    }

    private var destructiveTitle: String {
        guard let kind = viewModel.album(for: albumID)?.kind else {
            return String(localized: "删除")
        }

        switch kind {
        case .allPhotos, .allVideos:
            return String(localized: "移到回收站")
        case .custom:
            return String(localized: "移出相册")
        case .secureLibrary:
            return String(localized: "永久删除")
        case .secureCustom:
            return String(localized: "永久删除")
        case .trash:
            return String(localized: "彻底删除")
        case .archive:
            return String(localized: "移到回收站")
        }
    }

    private var deleteButtonTitle: String {
        if viewModel.album(for: albumID)?.kind.isSecure == true {
            return String(localized: "永久删除")
        }
        return destructiveTitle == String(localized: "移出相册")
            ? String(localized: "移出相册")
            : String(localized: "删除")
    }

    private func loadMoreItemsIfNeeded(currentItem: VaultItem, displayedItems: [VaultItem], totalItemCount: Int) {
        guard totalItemCount > visibleItemLimit,
              currentItem.id == displayedItems.last?.id else {
            return
        }

        visibleItemLimit = min(visibleItemLimit + visibleItemBatchSize, totalItemCount)
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renamingItem != nil },
            set: { isPresented in
                if !isPresented {
                    renamingItem = nil
                    renameText = ""
                }
            }
        )
    }

    private var detailItemBinding: Binding<MediaItemDetailInfo?> {
        Binding(
            get: {
                guard let detailItemID else { return nil }
                return viewModel.details(for: detailItemID)
            },
            set: { newValue in
                if newValue == nil {
                    detailItemID = nil
                }
            }
        )
    }

    @ToolbarContentBuilder
    private func topBarToolbar(currentSortOption: AlbumSortOption, albumKind: MediaAlbumKind?) -> some ToolbarContent {
        // Hide the trailing actions while the full-screen media viewer is open so
        // they don't linger in the window title bar over the photo/video.
        if previewSelection == nil {
            #if targetEnvironment(macCatalyst)
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    nativeMacSortMenu(currentSortOption: currentSortOption)
                } else {
                    nativeMacImportMenuButton
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                nativeMacSelectionModeButton(albumKind: albumKind)
            }
            #else
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSelecting {
                    sortMenu(currentSortOption: currentSortOption)
                }

                if !isSelecting {
                    importMenuButton
                }
                selectionModeButton(albumKind: albumKind)
            }
            #endif
        }
    }

    #if targetEnvironment(macCatalyst)
    private var nativeMacImportMenuButton: some View {
        Menu {
            Button {
                beginSystemPhotoImport()
            } label: {
                Label(String(localized: "从相册导入"), systemImage: "photo.on.rectangle")
            }

            Button {
                showingFileImporter = true
            } label: {
                Label(String(localized: "从文件导入"), systemImage: "folder")
            }
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
    }

    private func nativeMacSelectionModeButton(albumKind: MediaAlbumKind?) -> some View {
        Button {
            if isSelecting {
                exitSelectionMode()
            } else {
                enterSelectionMode()
            }
        } label: {
            if isSelecting {
                Image(systemName: "xmark")
            } else {
                Image(systemName: "checkmark.circle")
            }
        }
    }

    private func nativeMacSortMenu(currentSortOption: AlbumSortOption) -> some View {
        Menu {
            ForEach(availableSortOptions) { option in
                sortOptionButton(for: option, currentSortOption: currentSortOption)
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
    }
    #endif

    private func selectionActionBar(albumKind: MediaAlbumKind?) -> some View {
        HStack(spacing: 0) {
            selectionActionButton(
                title: String(localized: "导出"),
                systemImage: "square.and.arrow.up",
                role: nil,
                isDisabled: selectedItemIDs.isEmpty || isPreparingExport
            ) {
                prepareSelectedItemsForExport()
            }

            if albumKind == .archive {
                selectionDivider

                selectionActionButton(
                    title: String(localized: "放回"),
                    systemImage: "arrow.uturn.backward.circle",
                    role: nil,
                    isDisabled: selectedItemIDs.isEmpty
                ) {
                    for itemID in selectedItemIDs {
                        viewModel.unarchive(itemID: itemID)
                    }
                    isSelecting = false
                    selectedItemIDs.removeAll()
                }
            } else if albumKind != .trash && albumKind?.isSecure != true {
                selectionDivider

                selectionActionButton(
                    title: String(localized: "归档"),
                    systemImage: "archivebox",
                    role: nil,
                    isDisabled: selectedItemIDs.isEmpty
                ) {
                    viewModel.archive(itemIDs: selectedItemIDs)
                    isSelecting = false
                    selectedItemIDs.removeAll()
                }
            }

            if albumKind != .archive && albumKind != .trash {
                selectionDivider
            }

            if albumKind != .trash && albumKind != .archive {
                selectionActionButton(
                    title: String(localized: "添加到"),
                    systemImage: "text.badge.plus",
                    role: nil,
                    isDisabled: selectedItemIDs.isEmpty
                ) {
                    showingAlbumPicker = true
                }
            }

            if advancedDataProtectionEnabled && albumKind == .secureLibrary {
                selectionDivider
                selectionActionButton(
                    title: String(localized: "移出强加密"),
                    systemImage: "lock.open",
                    role: nil,
                    isDisabled: selectedItemIDs.isEmpty
                ) {
                    requestRemoveFromStrongProtection(for: selectedItemIDs)
                }
            } else if advancedDataProtectionEnabled,
                      albumKind != .trash,
                      albumKind != .archive,
                      albumKind?.isSecure != true {
                selectionDivider
                selectionActionButton(
                    title: String(localized: "强加密"),
                    systemImage: "lock.shield",
                    role: nil,
                    isDisabled: selectedItemIDs.isEmpty
                ) {
                    viewModel.enableStrongProtection(itemIDs: selectedItemIDs)
                    selectedItemIDs.removeAll()
                    isSelecting = false
                }
            }

            selectionDivider

            selectionActionButton(
                title: deleteButtonTitle,
                systemImage: "trash",
                role: .destructive,
                isDisabled: selectedItemIDs.isEmpty
            ) {
                requestDestructiveOperation(for: selectedItemIDs, albumKind: albumKind)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .modifier(SelectionBarGlassStyle())
    }

    private var importMenuButton: some View {
        Menu {
            Button {
                beginSystemPhotoImport()
            } label: {
                Label(String(localized: "从相册导入"), systemImage: "photo.on.rectangle")
            }

            Button {
                showingFileImporter = true
            } label: {
                Label(String(localized: "从文件导入"), systemImage: "folder")
            }
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
    }

    private func selectionModeButton(albumKind: MediaAlbumKind?) -> some View {
        Button {
            if isSelecting {
                exitSelectionMode()
            } else {
                enterSelectionMode()
            }
        } label: {
            if isSelecting {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
            } else {
                Image(systemName: "checkmark.circle")
            }
        }
        .buttonStyle(.borderless)
    }

    private func enterSelectionMode() {
        previewSelection = nil
        detailItemID = nil
        pendingOperation = nil
        isSelecting = true
    }

    private func enterSelectionMode(selecting itemID: UUID) {
        previewSelection = nil
        detailItemID = nil
        pendingOperation = nil
        selectedItemIDs = [itemID]
        isSelecting = true
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedItemIDs.removeAll()
    }

    private var selectionDivider: some View {
        Divider()
            .frame(height: 28)
            .padding(.vertical, 4)
    }

    private func selectionActionButton(
        title: String,
        systemImage: String,
        role: ButtonRole?,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .disabled(isDisabled)
        .buttonStyle(.plain)
    }

    private func sortMenu(currentSortOption: AlbumSortOption) -> some View {
        Menu {
            ForEach(availableSortOptions) { option in
                sortOptionButton(for: option, currentSortOption: currentSortOption)
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .accessibilityLabel(String(localized: "排序"))
    }

    private var availableSortOptions: [AlbumSortOption] {
        guard let kind = viewModel.album(for: albumID)?.kind else {
            return AlbumSortOption.allCases.filter { $0 != .custom }
        }
        switch kind {
        case .trash, .archive:
            return AlbumSortOption.allCases.filter { $0 != .custom }
        default:
            return AlbumSortOption.allCases
        }
    }

    @ViewBuilder
    private func contextMenuContent(for item: VaultItem, albumKind: MediaAlbumKind?) -> some View {
        Button {
            isSelecting = true
            selectedItemIDs = [item.id]
        } label: {
            Label(String(localized: "选择"), systemImage: "checkmark.circle")
        }

        Button {
            renameText = item.name
            renamingItem = item
        } label: {
            Label(String(localized: "重命名"), systemImage: "pencil")
        }

        Button {
            detailItemID = item.id
        } label: {
            Label(String(localized: "显示详情"), systemImage: "info.circle")
        }

        switch albumKind {
        case .trash:
            if let exportURL = viewModel.exportURL(for: item.id) {
                ShareLink(item: exportURL) {
                    Label(String(localized: "导出"), systemImage: "square.and.arrow.up")
                }
            }
            Button {
                viewModel.restoreFromTrash(itemID: item.id)
            } label: {
                Label(String(localized: "恢复"), systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                requestDestructiveOperation(for: Set([item.id]), albumKind: albumKind)
            } label: {
                Label(String(localized: "彻底删除"), systemImage: "trash")
            }
            
        case .archive:
            if let exportURL = viewModel.exportURL(for: item.id) {
                ShareLink(item: exportURL) {
                    Label(String(localized: "导出"), systemImage: "square.and.arrow.up")
                }
            }
            Button {
                viewModel.unarchive(itemID: item.id)
            } label: {
                Label(String(localized: "放回"), systemImage: "arrow.uturn.backward.circle")
            }
            Button(role: .destructive) {
                requestDestructiveOperation(for: Set([item.id]), albumKind: albumKind)
            } label: {
                Label(String(localized: "移到回收站"), systemImage: "trash")
            }

        case .secureLibrary:
            if advancedDataProtectionEnabled {
                if let exportURL = viewModel.exportURL(for: item.id) {
                    ShareLink(item: exportURL) {
                        Label(String(localized: "导出"), systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    selectedItemIDs = [item.id]
                    showingAlbumPicker = true
                } label: {
                    Label(String(localized: "添加到强加密相册"), systemImage: "lock.rectangle.stack")
                }
                Button(role: .destructive) {
                    requestRemoveFromStrongProtection(for: Set([item.id]))
                } label: {
                    Label(String(localized: "移出强加密媒体库"), systemImage: "lock.open")
                }
                Button(role: .destructive) {
                    requestPermanentDeletion(for: Set([item.id]))
                } label: {
                    Label(String(localized: "永久删除"), systemImage: "trash")
                }
            }

        case .secureCustom:
            if advancedDataProtectionEnabled {
                if let exportURL = viewModel.exportURL(for: item.id) {
                    ShareLink(item: exportURL) {
                        Label(String(localized: "导出"), systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    selectedItemIDs = [item.id]
                    showingAlbumPicker = true
                } label: {
                    Label(String(localized: "添加到强加密相册"), systemImage: "lock.rectangle.stack")
                }
                Button(role: .destructive) {
                    requestDestructiveOperation(for: Set([item.id]), albumKind: albumKind)
                } label: {
                    Label(String(localized: "移出相册"), systemImage: "minus.circle")
                }
                Button(role: .destructive) {
                    requestPermanentDeletion(for: Set([item.id]))
                } label: {
                    Label(String(localized: "永久删除"), systemImage: "trash")
                }
            }
            
        default:
            if let exportURL = viewModel.exportURL(for: item.id) {
                ShareLink(item: exportURL) {
                    Label(String(localized: "导出"), systemImage: "square.and.arrow.up")
                }
            }
            Button {
                viewModel.duplicate(itemIDs: Set([item.id]))
            } label: {
                Label(String(localized: "复制"), systemImage: "plus.square.on.square")
            }

            Button {
                selectedItemIDs = [item.id]
                showingAlbumPicker = true
            } label: {
                Label(String(localized: "添加到相册"), systemImage: "text.badge.plus")
            }

            if advancedDataProtectionEnabled {
                Button {
                    viewModel.enableStrongProtection(itemIDs: Set([item.id]))
                } label: {
                    Label(String(localized: "移入强加密媒体库"), systemImage: "lock.shield")
                }
            }
            
            Button {
                viewModel.archive(itemIDs: Set([item.id]))
            } label: {
                Label(String(localized: "归档"), systemImage: "archivebox")
            }
            
            Button(role: .destructive) {
                requestDestructiveOperation(for: Set([item.id]), albumKind: albumKind)
            } label: {
                Label(destructiveTitle, systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func sortOptionButton(
        for option: AlbumSortOption,
        currentSortOption: AlbumSortOption
    ) -> some View {
        Button {
            viewModel.setSortOption(option, for: albumID)
            if option == .custom {
                showingCustomSort = true
            }
        } label: {
            sortOptionLabel(for: option, currentSortOption: currentSortOption)
        }
    }

    @ViewBuilder
    private func sortOptionLabel(
        for option: AlbumSortOption,
        currentSortOption: AlbumSortOption
    ) -> some View {
        if currentSortOption == option {
            Label(option.title, systemImage: "checkmark")
        } else {
            Text(option.title)
        }
    }

    private func toggleSelection(for itemID: UUID) {
        if selectedItemIDs.contains(itemID) {
            selectedItemIDs.remove(itemID)
        } else {
            selectedItemIDs.insert(itemID)
        }
    }

    private func requestDestructiveOperation(for itemIDs: Set<UUID>, albumKind: MediaAlbumKind?) {
        guard !itemIDs.isEmpty else { return }

        let title: String
        let message: String
        let confirmTitle: String
        let kind: PendingMediaOperation.Kind

        switch albumKind {
        case .trash:
            title = String(localized: "彻底删除？")
            message = String(localized: "这些项目将被永久删除，无法从回收站恢复。")
            confirmTitle = String(localized: "彻底删除")
            kind = .permanentlyDelete
        case .custom:
            title = String(localized: "移出相册？")
            message = String(localized: "这些项目只会从当前相册移出，不会删除原始媒体。")
            confirmTitle = String(localized: "移出")
            kind = .removeFromAlbum
        case .secureLibrary:
            title = String(localized: "永久删除所选项目？")
            message = String(localized: "所选媒体将从设备本地永久删除，不会进入回收站，且无法恢复。")
            confirmTitle = String(localized: "永久删除")
            kind = .permanentlyDelete
        case .secureCustom:
            title = String(localized: "永久删除所选项目？")
            message = String(localized: "所选媒体将从设备本地永久删除，不会进入回收站，且无法恢复。")
            confirmTitle = String(localized: "永久删除")
            kind = .permanentlyDelete
        default:
            title = String(localized: "移到回收站？")
            message = String(localized: "这些项目会被放入回收站，可以稍后恢复。")
            confirmTitle = String(localized: "删除")
            kind = .moveToTrash
        }

        pendingOperation = PendingMediaOperation(
            itemIDs: itemIDs,
            kind: kind,
            title: title,
            message: message,
            confirmTitle: confirmTitle
        )
    }

    private func requestRemoveFromStrongProtection(for itemIDs: Set<UUID>) {
        guard !itemIDs.isEmpty else { return }
        pendingOperation = PendingMediaOperation(
            itemIDs: itemIDs,
            kind: .removeFromStrongProtection,
            title: String(localized: "移出强加密？"),
            message: String(localized: "选中的媒体将移出强加密媒体库，并回到普通相册中。移出后将不再受到强加密保护。"),
            confirmTitle: String(localized: "移出")
        )
    }

    private func requestPermanentDeletion(for itemIDs: Set<UUID>) {
        guard !itemIDs.isEmpty else { return }
        pendingOperation = PendingMediaOperation(
            itemIDs: itemIDs,
            kind: .permanentlyDelete,
            title: String(localized: "永久删除所选项目？"),
            message: String(localized: "所选媒体将从设备本地永久删除，不会进入回收站，且无法恢复。"),
            confirmTitle: String(localized: "永久删除")
        )
    }

    private func trashFooterText(for item: VaultItem) -> String {
        let remainingDays = viewModel.trashRemainingDays(for: item)
        if remainingDays <= 0 {
            return String(localized: "即将删除")
        }
        return String.localizedStringWithFormat(String(localized: "还剩 %lld 天"), remainingDays)
    }

    private func performOperation(_ operation: PendingMediaOperation) {
        switch operation.kind {
        case .removeFromStrongProtection:
            viewModel.removeFromStrongProtection(itemIDs: operation.itemIDs)
        case .permanentlyDelete where viewModel.album(for: albumID)?.kind.isSecure == true:
            viewModel.permanentlyDeleteStrongProtected(itemIDs: operation.itemIDs)
        case .permanentlyDelete, .moveToTrash, .removeFromAlbum:
            viewModel.handleDeletion(of: operation.itemIDs, from: albumID)
        }
        selectedItemIDs.removeAll()
        isSelecting = false
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.lastErrorMessage != nil && !viewModel.isImportingMedia },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissError()
                }
            }
        )
    }

    private var importProgressSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isImportingMedia },
            set: { _ in }
        )
    }

    private var mediaImportProgressSheet: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 16) {
                        ProgressView(value: viewModel.importProgressValue)
                            .progressViewStyle(.linear)

                        VStack(spacing: 6) {
                            Text(viewModel.importProgressTitle.isEmpty ? String(localized: "正在导入") : viewModel.importProgressTitle)
                                .font(.headline)
                            if !viewModel.importProgressDetail.isEmpty {
                                Text(viewModel.importProgressDetail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            Text(String.localizedStringWithFormat(String(localized: "%lld%%"), Int64(viewModel.importProgressValue * 100)))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section {
                    Button(String(localized: "停止"), role: .destructive) {
                        viewModel.cancelImport()
                    }
                } footer: {
                    Text(String(localized: "停止后，本次未完成的导入会立即终止。"))
                }
            }
            .navigationTitle(String(localized: "正在导入"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(true)
        }
    }

    private var exportPreparationSheet: some View {
        NavigationStack {
            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)

                VStack(spacing: 8) {
                    Text(String(localized: "正在解密并准备所选项目…"))
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)

                    if exportPreparationTotalCount > 0 {
                        Text(String.localizedStringWithFormat(String(localized: "%1$lld / %2$lld"), Int64(exportPreparationCompletedCount), Int64(exportPreparationTotalCount)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "准备中"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
            .navigationTitle(String(localized: "正在准备导出"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(true)
        }
    }

    private func prepareSelectedItemsForExport() {
        let itemIDs = selectedItemIDs
        guard !itemIDs.isEmpty, !isPreparingExport else { return }
        exportPreparationCompletedCount = 0
        exportPreparationTotalCount = itemIDs.count
        isPreparingExport = true

        Task {
            let result = await viewModel.prepareExportURLs(for: itemIDs) { completed, total in
                exportPreparationCompletedCount = completed
                exportPreparationTotalCount = total
            }

            isPreparingExport = false
            shareURLs = result.urls
            if result.failedCount > 0 {
                viewModel.lastErrorMessage = result.urls.isEmpty
                    ? String(localized: "导出失败")
                    : String(localized: "部分项目无法导出")
            }
            if !result.urls.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    showingShareSheet = true
                }
            }
        }
    }

    private func maybePromptToDeleteImportedSystemAssets(afterImportCount importedCount: Int) {
        defer { pendingImportedSystemAssetIdentifiers = [] }
        guard deleteImportedSystemAssetsAfterImport else {
            print("[ImportCleanup][Album] prompt skipped because feature disabled")
            return
        }
        let assetIdentifiers = Array(Set(pendingImportedSystemAssetIdentifiers.filter { !$0.isEmpty }))
        guard !assetIdentifiers.isEmpty else {
            print("[ImportCleanup][Album] prompt skipped because no asset identifiers were captured")
            return
        }
        print("[ImportCleanup][Album] showing delete prompt importedCount=\(importedCount) uniqueAssetIDs=\(assetIdentifiers.count)")
        importedSystemAssetsDeletionPrompt = ImportedSystemAssetsDeletionPrompt(
            assetIdentifiers: assetIdentifiers,
            importedCount: importedCount
        )
    }

    private func scheduleDeletePromptAfterImport(importedCount: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            maybePromptToDeleteImportedSystemAssets(afterImportCount: importedCount)
        }
    }

    private func presentImportResultIfNeeded() {
        guard !viewModel.isImportingMedia,
              let summary = viewModel.importResultSummary,
              presentedImportResultSummary == nil else { return }
        print("[ImportCleanup][Album] scheduling import result prompt photoCount=\(summary.photoCount) videoCount=\(summary.videoCount)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard !viewModel.isImportingMedia,
                  let latestSummary = viewModel.importResultSummary,
                  presentedImportResultSummary == nil else { return }
            print("[ImportCleanup][Album] presenting import result prompt")
            presentedImportResultSummary = latestSummary
            viewModel.dismissImportResult()
        }
    }

    private func deleteImportedSystemAssets(_ assetIdentifiers: [String]) {
        Task {
            do {
                print("[ImportCleanup][Album] delete confirmed assetIDs=\(assetIdentifiers.count)")
                _ = try await SystemPhotoLibraryCleanupService.shared.deleteAssets(withLocalIdentifiers: assetIdentifiers)
                print("[ImportCleanup][Album] delete finished successfully")
            } catch {
                await MainActor.run {
                    print("[ImportCleanup][Album] delete failed error=\(error.localizedDescription)")
                    viewModel.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func beginSystemPhotoImport() {
        guard deleteImportedSystemAssetsAfterImport else {
            print("[ImportCleanup][Album] begin managed import without cleanup requirement")
            showingManagedPhotoImporter = true
            return
        }

        Task {
            let status = await SystemPhotoLibraryCleanupService.shared.ensureReadWriteAuthorization()
            await MainActor.run {
                print("[ImportCleanup][Album] readWrite authorization status=\(status.rawValue)")
                if status == .authorized || status == .limited {
                    showingManagedPhotoImporter = true
                } else {
                    viewModel.lastErrorMessage = String(localized: "如果你想在导入后删除系统图库原件，请先允许本应用访问\u{201C}照片\u{201D}。")
                }
            }
        }
    }

    private func handleDroppedMedia(_ providers: [NSItemProvider]) -> Bool {
        isDropTargeted = false
        if let albumKind = viewModel.album(for: albumID)?.kind,
           albumKind == .trash || albumKind == .archive {
            return false
        }

        guard viewModel.canShowRealData else {
            return false
        }

        guard viewModel.canImportAdditionalItems(providers.count) else {
            return false
        }

        Task {
            let urls = await DroppedMediaImportSupport.loadURLs(from: providers)
            await MainActor.run {
                guard !urls.isEmpty else { return }
                pendingImportedSystemAssetIdentifiers = []
                viewModel.importFiles(urls, directlyInto: albumID)
            }
        }

        return true
    }

    #if targetEnvironment(macCatalyst)
    private func scheduleDropOverlayReset() {
        let token = UUID()
        dropOverlayResetToken = token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard dropOverlayResetToken == token else { return }
            isDropTargeted = false
        }
    }
    #endif

    private var trashAlbumID: UUID {
        viewModel.trashAlbum?.id ?? albumID
    }
}

private struct ItemContextMenuModifier<MenuContent: View>: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder let content: () -> MenuContent

    @ViewBuilder
    func body(content viewContent: Content) -> some View {
        if isEnabled {
            viewContent.contextMenu(menuItems: content)
        } else {
            viewContent
        }
    }
}

private struct SecureMediaListView: UIViewControllerRepresentable {
    let items: [VaultItem]
    let albumKind: MediaAlbumKind?
    let selectedItemIDs: Set<UUID>
    let isSelecting: Bool
    let contentInsetBottom: CGFloat
    let footerText: (VaultItem) -> String?
    let onReachEnd: (VaultItem) -> Void
    let onOpenItem: (UUID) -> Void
    let onSelectionChanged: (Set<UUID>) -> Void
    let onSelectionModeChanged: (Bool) -> Void
    let onRenameItem: (VaultItem) -> Void
    let onShowDetails: (VaultItem) -> Void
    let onAddToSecureAlbum: (VaultItem) -> Void
    let onRemoveFromStrongProtection: (VaultItem) -> Void
    let onDeleteItem: (VaultItem) -> Void
    let onPermanentDeleteItem: (VaultItem) -> Void

    func makeUIViewController(context: Context) -> SecureMediaListViewController {
        let controller = SecureMediaListViewController()
        controller.items = items
        controller.albumKind = albumKind
        controller.selectedItemIDs = selectedItemIDs
        controller.isSelecting = isSelecting
        controller.contentInsetBottom = contentInsetBottom
        controller.footerText = footerText
        controller.onReachEnd = onReachEnd
        controller.onOpenItem = onOpenItem
        controller.onSelectionChanged = onSelectionChanged
        controller.onSelectionModeChanged = onSelectionModeChanged
        controller.onRenameItem = onRenameItem
        controller.onShowDetails = onShowDetails
        controller.onAddToSecureAlbum = onAddToSecureAlbum
        controller.onRemoveFromStrongProtection = onRemoveFromStrongProtection
        controller.onDeleteItem = onDeleteItem
        controller.onPermanentDeleteItem = onPermanentDeleteItem
        return controller
    }

    func updateUIViewController(_ controller: SecureMediaListViewController, context: Context) {
        let previousSelectedItemIDs = controller.selectedItemIDs
        let previousIsSelecting = controller.isSelecting
        controller.albumKind = albumKind
        controller.contentInsetBottom = contentInsetBottom
        controller.footerText = footerText
        controller.onReachEnd = onReachEnd
        controller.onOpenItem = onOpenItem
        controller.onSelectionChanged = onSelectionChanged
        controller.onSelectionModeChanged = onSelectionModeChanged
        controller.onRenameItem = onRenameItem
        controller.onShowDetails = onShowDetails
        controller.onAddToSecureAlbum = onAddToSecureAlbum
        controller.onRemoveFromStrongProtection = onRemoveFromStrongProtection
        controller.onDeleteItem = onDeleteItem
        controller.onPermanentDeleteItem = onPermanentDeleteItem
        controller.selectedItemIDs = selectedItemIDs
        controller.isSelecting = isSelecting
        controller.updateItems(items)
        controller.reconfigureSelectionChanges(from: previousSelectedItemIDs, previousIsSelecting: previousIsSelecting)
    }
}

private final class SecureMediaListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    var items: [VaultItem] = []
    var albumKind: MediaAlbumKind?
    var selectedItemIDs: Set<UUID> = []
    var isSelecting = false
    var contentInsetBottom: CGFloat = 0 {
        didSet {
            tableView.contentInset.bottom = contentInsetBottom
            tableView.verticalScrollIndicatorInsets.bottom = contentInsetBottom
        }
    }
    var footerText: ((VaultItem) -> String?)?
    var onReachEnd: ((VaultItem) -> Void)?
    var onOpenItem: ((UUID) -> Void)?
    var onSelectionChanged: ((Set<UUID>) -> Void)?
    var onSelectionModeChanged: ((Bool) -> Void)?
    var onRenameItem: ((VaultItem) -> Void)?
    var onShowDetails: ((VaultItem) -> Void)?
    var onAddToSecureAlbum: ((VaultItem) -> Void)?
    var onRemoveFromStrongProtection: ((VaultItem) -> Void)?
    var onDeleteItem: ((VaultItem) -> Void)?
    var onPermanentDeleteItem: ((VaultItem) -> Void)?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var lastRenderedItemIDs: [UUID] = []
    private var dragSelectGesture: UILongPressGestureRecognizer?
    private var isDragSelecting = false
    private var dragVisitedItemIDs = Set<UUID>()
    private var lastDragLocation: CGPoint?
    private var autoScrollDisplayLink: CADisplayLink?
    private var autoScrollDirection: AutoScrollDirection?
    private var autoScrollSpeed: CGFloat = 0

    private enum AutoScrollDirection {
        case up
        case down
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isOpaque = true
        view.backgroundColor = platformBackgroundColor
        configureTableView()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        finishDragSelection()
    }

    deinit {
        stopAutoScroll()
    }

    func updateItems(_ nextItems: [VaultItem]) {
        let nextIDs = nextItems.map(\.id)
        let shouldReloadAll = nextIDs != lastRenderedItemIDs
        items = nextItems
        guard shouldReloadAll else { return }
        lastRenderedItemIDs = nextIDs
        tableView.reloadData()
    }

    func reconfigureSelectionChanges(from previousSelectedItemIDs: Set<UUID>, previousIsSelecting: Bool) {
        let changedIDs: Set<UUID>
        if previousIsSelecting != isSelecting {
            changedIDs = Set(items.map(\.id))
        } else {
            changedIDs = previousSelectedItemIDs.symmetricDifference(selectedItemIDs)
        }
        reloadVisibleRows(matching: changedIDs)
    }

    private func configureTableView() {
        tableView.isOpaque = true
        tableView.backgroundColor = platformBackgroundColor
        tableView.backgroundView = UIView()
        tableView.backgroundView?.backgroundColor = platformBackgroundColor
        tableView.tableHeaderView = UIView(frame: .zero)
        tableView.tableFooterView = UIView(frame: .zero)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 52, bottom: 0, right: 16)
        tableView.sectionHeaderTopPadding = 0
        tableView.contentInset.bottom = contentInsetBottom
        tableView.verticalScrollIndicatorInsets.bottom = contentInsetBottom
        tableView.allowsSelection = true
        tableView.allowsMultipleSelection = false
        tableView.allowsMultipleSelectionDuringEditing = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SecureMediaRowCell")
        view.addSubview(tableView)

        let dragSelectGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleDragSelection(_:)))
        dragSelectGesture.minimumPressDuration = 0.35
        dragSelectGesture.cancelsTouchesInView = false
        dragSelectGesture.delaysTouchesBegan = false
        dragSelectGesture.delegate = self
        tableView.addGestureRecognizer(dragSelectGesture)
        self.dragSelectGesture = dragSelectGesture
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SecureMediaRowCell", for: indexPath)
        configure(cell, with: items[indexPath.row])
        return cell
    }

    private var platformBackgroundColor: UIColor {
        #if targetEnvironment(macCatalyst)
        .systemBackground
        #else
        .systemGroupedBackground
        #endif
    }

    private var platformCellBackgroundColor: UIColor {
        #if targetEnvironment(macCatalyst)
        .secondarySystemBackground
        #else
        .secondarySystemGroupedBackground
        #endif
    }

    private func configure(_ cell: UITableViewCell, with item: VaultItem) {
        cell.selectionStyle = isSelecting ? .default : .none
        cell.backgroundColor = platformCellBackgroundColor
        var backgroundConfiguration = UIBackgroundConfiguration.listCell()
        backgroundConfiguration.backgroundColor = platformCellBackgroundColor
        cell.backgroundConfiguration = backgroundConfiguration
        var content = UIListContentConfiguration.subtitleCell()
        content.text = item.name
        content.secondaryText = secureRowSubtitle(for: item)
        content.image = UIImage(systemName: item.mediaKind.symbolName)
        content.imageProperties.tintColor = .secondaryLabel
        content.textProperties.font = .preferredFont(forTextStyle: .headline)
        content.textProperties.color = .label
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.color = .secondaryLabel
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
        cell.contentConfiguration = content

        if isSelecting {
            cell.accessoryType = selectedItemIDs.contains(item.id) ? .checkmark : .none
            cell.tintColor = .systemBlue
        } else {
            cell.accessoryType = .disclosureIndicator
        }
    }

    private func secureRowSubtitle(for item: VaultItem) -> String {
        if let footer = footerText?(item), !footer.isEmpty {
            return footer
        }
        return ""
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row == items.count - 1 else { return }
        onReachEnd?(items[indexPath.row])
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard let item = items[safe: indexPath.row] else { return }
        if isSelecting {
            toggleSelection(for: item.id)
        } else {
            onOpenItem?(item.id)
        }
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = items[safe: indexPath.row] else { return nil }
        let delete = UIContextualAction(style: .destructive, title: String(localized: "永久删除")) { [weak self] _, _, completion in
            self?.onDeleteItem?(item)
            completion(true)
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = items[safe: indexPath.row] else { return nil }
        let edit = UIContextualAction(style: .normal, title: String(localized: "编辑")) { [weak self] _, _, completion in
            self?.enterSelectionMode(selecting: item.id)
            completion(true)
        }
        edit.image = UIImage(systemName: "pencil")
        edit.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [edit])
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !isSelecting else {
            return nil
        }
        guard let item = items[safe: indexPath.row] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.contextMenu(for: item) ?? UIMenu()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dragSelectGesture || otherGestureRecognizer === dragSelectGesture else {
            return false
        }
        // Before the long press actually begins, let the table view keep its
        // native pan/swipe handling. Once drag-selecting starts, we own touch
        // movement until the finger lifts.
        return !isDragSelecting
    }

    @objc private func handleDragSelection(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: tableView)
        switch gesture.state {
        case .began:
            guard let indexPath = tableView.indexPathForRow(at: location),
                  let item = items[safe: indexPath.row] else { return }
            if !isSelecting {
                setSelectionMode(true)
                applySelection(selectedItemIDs.union([item.id]))
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                return
            }
            guard isSelecting else {
                return
            }
            isDragSelecting = true
            tableView.isScrollEnabled = false
            dragVisitedItemIDs.removeAll()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            toggleDragSelection(for: item.id)
            updateAutoScroll(for: location)
        case .changed:
            guard isDragSelecting else { return }
            lastDragLocation = location
            if let indexPath = tableView.indexPathForRow(at: location),
               let item = items[safe: indexPath.row] {
                toggleDragSelection(for: item.id)
            }
            updateAutoScroll(for: location)
        case .ended, .cancelled, .failed:
            finishDragSelection()
        default:
            break
        }
    }

    private func contextMenu(for item: VaultItem) -> UIMenu {
        let select = UIAction(title: String(localized: "选择"), image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
            self?.enterSelectionMode(selecting: item.id)
        }
        let rename = UIAction(title: String(localized: "重命名"), image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.onRenameItem?(item)
        }
        let details = UIAction(title: String(localized: "显示详情"), image: UIImage(systemName: "info.circle")) { [weak self] _ in
            self?.onShowDetails?(item)
        }

        var actions: [UIMenuElement] = [select, rename, details]
        switch albumKind {
        case .secureLibrary:
            actions.append(UIAction(title: String(localized: "添加到强加密相册"), image: UIImage(systemName: "lock.rectangle.stack")) { [weak self] _ in
                self?.onAddToSecureAlbum?(item)
            })
            actions.append(UIAction(title: String(localized: "移出强加密媒体库"), image: UIImage(systemName: "lock.open"), attributes: .destructive) { [weak self] _ in
                self?.onRemoveFromStrongProtection?(item)
            })
            actions.append(UIAction(title: String(localized: "永久删除"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.onPermanentDeleteItem?(item)
            })
        case .secureCustom:
            actions.append(UIAction(title: String(localized: "添加到强加密相册"), image: UIImage(systemName: "lock.rectangle.stack")) { [weak self] _ in
                self?.onAddToSecureAlbum?(item)
            })
            actions.append(UIAction(title: String(localized: "移出相册"), image: UIImage(systemName: "minus.circle"), attributes: .destructive) { [weak self] _ in
                self?.onDeleteItem?(item)
            })
            actions.append(UIAction(title: String(localized: "永久删除"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.onPermanentDeleteItem?(item)
            })
        default:
            actions.append(UIAction(title: String(localized: "永久删除"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.onDeleteItem?(item)
            })
        }
        return UIMenu(children: actions)
    }

    private func enterSelectionMode(selecting itemID: UUID) {
        setSelectionMode(true)
        applySelection([itemID])
    }

    private func setSelectionMode(_ enabled: Bool) {
        guard isSelecting != enabled else { return }
        let previousIsSelecting = isSelecting
        isSelecting = enabled
        if !enabled {
            finishDragSelection()
        }
        DispatchQueue.main.async { [onSelectionModeChanged] in
            onSelectionModeChanged?(enabled)
        }
        reconfigureSelectionChanges(from: selectedItemIDs, previousIsSelecting: previousIsSelecting)
    }

    private func toggleSelection(for itemID: UUID) {
        var nextSelection = selectedItemIDs
        if nextSelection.contains(itemID) {
            nextSelection.remove(itemID)
        } else {
            nextSelection.insert(itemID)
        }
        applySelection(nextSelection)
    }

    private func toggleDragSelection(for itemID: UUID) {
        guard !dragVisitedItemIDs.contains(itemID) else { return }
        dragVisitedItemIDs.insert(itemID)
        var nextSelection = selectedItemIDs
        if nextSelection.contains(itemID) {
            nextSelection.remove(itemID)
        } else {
            nextSelection.insert(itemID)
        }
        applySelection(nextSelection)
    }

    private func applySelection(_ nextSelection: Set<UUID>) {
        let previousSelection = selectedItemIDs
        selectedItemIDs = nextSelection
        DispatchQueue.main.async { [onSelectionChanged] in
            onSelectionChanged?(nextSelection)
        }
        reloadVisibleRows(matching: previousSelection.symmetricDifference(nextSelection))
    }

    private func reloadVisibleRows(matching changedIDs: Set<UUID>) {
        guard !changedIDs.isEmpty else { return }
        let indexPaths = tableView.indexPathsForVisibleRows?.filter { indexPath in
            guard let item = items[safe: indexPath.row] else { return false }
            return changedIDs.contains(item.id)
        } ?? []
        guard !indexPaths.isEmpty else { return }
        UIView.performWithoutAnimation {
            tableView.reloadRows(at: indexPaths, with: .none)
        }
    }

    private func updateAutoScroll(for location: CGPoint) {
        lastDragLocation = location
        guard isDragSelecting else {
            stopAutoScroll()
            return
        }
        let threshold: CGFloat = 96
        let topDistance = location.y - tableView.contentOffset.y
        let bottomDistance = tableView.contentOffset.y + tableView.bounds.height - location.y

        let nextDirection: AutoScrollDirection?
        let edgeDistance: CGFloat
        if topDistance < threshold {
            nextDirection = .up
            edgeDistance = threshold - max(topDistance, 0)
        } else if bottomDistance < threshold {
            nextDirection = .down
            edgeDistance = threshold - max(bottomDistance, 0)
        } else {
            nextDirection = nil
            edgeDistance = 0
        }

        guard let nextDirection else {
            stopAutoScroll()
            return
        }
        autoScrollDirection = nextDirection
        autoScrollSpeed = max(2, pow(edgeDistance / threshold, 1.35) * 16)
        guard autoScrollDisplayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(handleAutoScrollTick))
        displayLink.add(to: .main, forMode: .common)
        autoScrollDisplayLink = displayLink
    }

    @objc private func handleAutoScrollTick() {
        guard isDragSelecting, let autoScrollDirection else {
            stopAutoScroll()
            return
        }
        let delta = autoScrollSpeed * (autoScrollDirection == .down ? 1 : -1)
        let nextOffset = clampedOffsetY(tableView.contentOffset.y + delta)
        let appliedDelta = nextOffset - tableView.contentOffset.y
        guard abs(appliedDelta) > 0.1 else {
            stopAutoScroll()
            return
        }
        tableView.contentOffset.y = nextOffset
        if var lastDragLocation {
            lastDragLocation.y += appliedDelta
            self.lastDragLocation = lastDragLocation
            if let indexPath = tableView.indexPathForRow(at: lastDragLocation),
               let item = items[safe: indexPath.row] {
                toggleDragSelection(for: item.id)
            }
            updateAutoScroll(for: lastDragLocation)
        }
    }

    private func finishDragSelection() {
        guard isDragSelecting || autoScrollDisplayLink != nil else { return }
        isDragSelecting = false
        tableView.isScrollEnabled = true
        dragVisitedItemIDs.removeAll()
        lastDragLocation = nil
        stopAutoScroll()
    }

    private func stopAutoScroll() {
        autoScrollDisplayLink?.invalidate()
        autoScrollDisplayLink = nil
        autoScrollDirection = nil
        autoScrollSpeed = 0
    }

    private func clampedOffsetY(_ proposedY: CGFloat) -> CGFloat {
        let minY = -tableView.adjustedContentInset.top
        let maxY = max(minY, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
        return min(max(proposedY, minY), maxY)
    }
}

private struct ZoomableMediaGridView: UIViewControllerRepresentable {
    let items: [VaultItem]
    @Binding var columnCount: Int
    let contentInsetBottom: CGFloat
    let renderToken: Int
    let selectedItemIDs: Set<UUID>
    let isSelecting: Bool
    let onReachEnd: (VaultItem) -> Void
    let onOpenItem: (UUID) -> Void
    let onSelectionChanged: (Set<UUID>) -> Void
    let onSelectionModeChanged: (Bool) -> Void
    let footerText: ((VaultItem) -> String?)?
    let onContextMenuForItem: ((VaultItem) -> UIMenu?)?
    /// macOS Catalyst drag-out: returns an NSItemProvider backed by a decrypted
    /// temporary file for the given vault item, or nil if export is not possible.
    let onDragItem: ((VaultItem) -> NSItemProvider?)?

    func makeCoordinator() -> Coordinator {
        Coordinator(columnCount: $columnCount)
    }

    func makeUIViewController(context: Context) -> ZoomableMediaGridViewController {
        #if DEBUG
        MediaPerformanceLog.recordFirstGridMake()
        MediaPerformanceLog.mark("grid.makeUIViewController.input", "items=\(items.count) columns=\(columnCount) selecting=\(isSelecting)")
        #endif
        let controller = ZoomableMediaGridViewController()
        controller.items = items
        controller.columnCount = columnCount
        controller.contentInsetBottom = contentInsetBottom
        controller.renderToken = renderToken
        controller.selectedItemIDs = selectedItemIDs
        controller.isSelecting = isSelecting
        controller.onReachEnd = onReachEnd
        controller.onOpenItem = onOpenItem
        controller.onSelectionChanged = onSelectionChanged
        controller.onSelectionModeChanged = onSelectionModeChanged
        controller.footerText = footerText
        controller.onContextMenuForItem = onContextMenuForItem
        controller.onDragItem = onDragItem
        controller.onColumnCountChanged = { nextValue in
            DispatchQueue.main.async {
                context.coordinator.columnCount.wrappedValue = nextValue
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: ZoomableMediaGridViewController, context: Context) {
        #if DEBUG
        MediaPerformanceLog.mark("grid.updateUIViewController", "items=\(items.count) columns=\(columnCount) selected=\(selectedItemIDs.count) selecting=\(isSelecting)")
        #endif
        context.coordinator.columnCount = $columnCount
        let previousSelectedItemIDs = controller.selectedItemIDs
        let previousIsSelecting = controller.isSelecting
        controller.items = items
        controller.columnCount = columnCount
        controller.contentInsetBottom = contentInsetBottom
        controller.renderToken = renderToken
        controller.selectedItemIDs = selectedItemIDs
        controller.isSelecting = isSelecting
        controller.onReachEnd = onReachEnd
        controller.onOpenItem = onOpenItem
        controller.onSelectionChanged = onSelectionChanged
        controller.onSelectionModeChanged = onSelectionModeChanged
        controller.footerText = footerText
        controller.onContextMenuForItem = onContextMenuForItem
        controller.onDragItem = onDragItem
        controller.onColumnCountChanged = { nextValue in
            DispatchQueue.main.async {
                context.coordinator.columnCount.wrappedValue = nextValue
            }
        }
        let didReload = controller.reloadKeepingPositionIfNeeded()
        if !didReload {
            #if DEBUG
            MediaPerformanceLog.mark("grid.selection.reconfigure.request", "previousSelected=\(previousSelectedItemIDs.count) selected=\(selectedItemIDs.count)")
            #endif
            controller.reconfigureSelectionChanges(from: previousSelectedItemIDs, previousIsSelecting: previousIsSelecting)
        }
    }

    final class Coordinator {
        var columnCount: Binding<Int>

        init(columnCount: Binding<Int>) {
            self.columnCount = columnCount
        }
    }
}

private final class ZoomableMediaGridViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UICollectionViewDataSourcePrefetching, UIGestureRecognizerDelegate {
    var items: [VaultItem] = []
    var columnCount: Int = 5 {
        didSet {
            effectiveColumnCount = CGFloat(columnCount)
            updateLayout(animated: false)
        }
    }
    /// macOS Catalyst drag-out: provides an NSItemProvider for a given vault item.
    /// Set by ZoomableMediaGridView; nil means drag-out is disabled.
    var onDragItem: ((VaultItem) -> NSItemProvider?)?
    var contentInsetBottom: CGFloat = 0 {
        didSet {
            collectionView.contentInset.bottom = contentInsetBottom
            collectionView.verticalScrollIndicatorInsets.bottom = contentInsetBottom
        }
    }
    var renderToken: Int = 0
    var selectedItemIDs: Set<UUID> = []
    var isSelecting = false
    var onReachEnd: ((VaultItem) -> Void)?
    var onOpenItem: ((UUID) -> Void)?
    var onSelectionChanged: ((Set<UUID>) -> Void)?
    var onSelectionModeChanged: ((Bool) -> Void)?
    var onColumnCountChanged: ((Int) -> Void)?
    var footerText: ((VaultItem) -> String?)?
    var onContextMenuForItem: ((VaultItem) -> UIMenu?)?

    private let layout = UICollectionViewFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var effectiveColumnCount: CGFloat = 5
    private let snapColumnCounts: [Int] = [2, 3, 4, 5, 6, 7, 8, 9]

    private var platformBackgroundColor: UIColor {
        #if targetEnvironment(macCatalyst)
        .systemBackground
        #else
        .systemGroupedBackground
        #endif
    }
    private let spacing: CGFloat = 4
    private let sectionInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    private var pinchStartColumnCount: CGFloat = 5
    private var pinchAnchorItemID: UUID?
    private var pinchAnchorScreenOriginY: CGFloat = 0
    private var cellRegistration: UICollectionView.CellRegistration<MediaGridCell, VaultItem>!
    private weak var pinchGesture: UIPinchGestureRecognizer?
    private var lastRenderedItemIDs: [UUID] = []
    private var lastRenderToken: Int = 0
    private var autoScrollDisplayLink: CADisplayLink?
    private var autoScrollDirection: AutoScrollDirection?
    private var autoScrollSpeed: CGFloat = 0
    private var isDragSelecting = false
    private var dragStartItemID: UUID?
    private var dragBaselineSelectedItemIDs = Set<UUID>()
    private var dragSelectionMode: DragSelectionMode = .select
    private var lastDragLocation: CGPoint?
    private var thumbnailPrefetchTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingPreheatWorkItem: DispatchWorkItem?
    private var preheatBatchTask: Task<Void, Never>?
    private var lastPreheatRangeKey: String?
    private weak var dragSelectGesture: UILongPressGestureRecognizer?
    private var isDraggingGrid = false
    private var isDeceleratingGrid = false
    private var isPinchingGrid = false
    private var isFastScrolling = false
    private var thumbnailLoadingSuspended = false
    private var lastScrollVelocityY: CGFloat = 0
    private var resumeThumbnailWorkItem: DispatchWorkItem?
    private var lastLoggedPreheatPauseReason: String?
    private let fastScrollVelocityThreshold: CGFloat = 1500
    private let idleVelocityThreshold: CGFloat = 300
    private let thumbnailIdleResumeDelay: TimeInterval = 0.15
    private let idleVisibleReconfigureBatchSize = 16
    private let idlePreheatBatchSize = 2

    private enum AutoScrollDirection {
        case up
        case down
    }

    private enum DragSelectionMode {
        case select
        case deselect
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        #if DEBUG
        MediaPerformanceLog.mark("grid.viewDidLoad", "items=\(items.count)")
        #endif
        view.backgroundColor = platformBackgroundColor
        configureCollectionView()
        setThumbnailLoadingSuspended(true, reason: "initial")
        #if targetEnvironment(macCatalyst)
        // Enable Finder drag-out on macOS Catalyst. The delegate is implemented
        // in the extension below; it decrypts to a temp file on demand.
        collectionView.dragDelegate = self
        collectionView.dragInteractionEnabled = true
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        #if DEBUG
        let layoutStart = CFAbsoluteTimeGetCurrent()
        #endif
        collectionView.frame = view.bounds
        updateLayout(animated: false)
        #if DEBUG
        MediaPerformanceLog.mark("grid.viewDidLayoutSubviews", "duration=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - layoutStart) * 1000))ms bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height))")
        #endif
        scheduleResumeThumbnailLoadingAfterScrollSettles()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        collectionView.isScrollEnabled = true
        isDragSelecting = false
        stopNativeAutoScroll()
        cancelPendingPreheat()
        cancelPreheatBatch()
        resumeThumbnailWorkItem?.cancel()
        resumeThumbnailWorkItem = nil
        setThumbnailLoadingSuspended(false, reason: "viewWillDisappear")
    }

    deinit {
        stopNativeAutoScroll()
        cancelPendingPreheat()
        cancelPreheatBatch()
        resumeThumbnailWorkItem?.cancel()
        DispatchQueue.main.async {
            VisibleThumbnailRequestCoordinator.shared.setSuspended(false, reason: "deinit")
        }
        thumbnailPrefetchTasks.values.forEach { $0.cancel() }
    }

    @discardableResult
    func reloadKeepingPositionIfNeeded() -> Bool {
        let nextItemIDs = items.map(\.id)
        guard nextItemIDs != lastRenderedItemIDs || renderToken != lastRenderToken else {
            #if DEBUG
            MediaPerformanceLog.mark("grid.reload.skip", "items=\(items.count)")
            #endif
            scheduleResumeThumbnailLoadingAfterScrollSettles()
            return false
        }

        let firstVisible = collectionView.indexPathsForVisibleItems.sorted().first
        let firstVisibleID = firstVisible.flatMap { items[safe: $0.item]?.id }
        let previousY = firstVisible.flatMap { collectionView.layoutAttributesForItem(at: $0)?.frame.minY }.map { $0 - collectionView.contentOffset.y }

        lastRenderedItemIDs = nextItemIDs
        lastRenderToken = renderToken
        lastPreheatRangeKey = nil
        #if DEBUG
        MediaPerformanceLog.setStage("grid-reloadData")
        let reloadStart = CFAbsoluteTimeGetCurrent()
        #endif
        collectionView.reloadData()
        #if DEBUG
        let reloadMS = (CFAbsoluteTimeGetCurrent() - reloadStart) * 1000
        let layoutStart = CFAbsoluteTimeGetCurrent()
        #endif
        updateLayout(animated: false)

        if let firstVisibleID,
           let index = items.firstIndex(where: { $0.id == firstVisibleID }),
           let previousY {
            let indexPath = IndexPath(item: index, section: 0)
            collectionView.layoutIfNeeded()
            if let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
                collectionView.contentOffset.y = clampedOffsetY(attributes.frame.minY - previousY)
            }
        }
        #if DEBUG
        collectionView.layoutIfNeeded()
        let layoutMS = (CFAbsoluteTimeGetCurrent() - layoutStart) * 1000
        MediaPerformanceLog.recordReload(durationMS: reloadMS, layoutMS: layoutMS, itemCount: items.count)
        #endif
        scheduleResumeThumbnailLoadingAfterScrollSettles()
        return true
    }

    func reconfigureSelectionChanges(from previousSelectedItemIDs: Set<UUID>, previousIsSelecting: Bool) {
        let changedIDs: Set<UUID>
        if previousIsSelecting != isSelecting {
            changedIDs = Set(items.map(\.id))
        } else {
            changedIDs = previousSelectedItemIDs.symmetricDifference(selectedItemIDs)
        }

        let indexPaths = collectionView.indexPathsForVisibleItems.filter { indexPath in
            guard let item = items[safe: indexPath.item] else { return false }
            return changedIDs.contains(item.id)
        }

        guard !indexPaths.isEmpty else {
            return
        }
        #if DEBUG
        MediaPerformanceLog.mark("grid.selection.reconfigure", "changed=\(changedIDs.count) visible=\(indexPaths.count)")
        #endif
        collectionView.reconfigureItems(at: indexPaths)
    }

    private func stopNativeAutoScroll() {
        autoScrollDisplayLink?.invalidate()
        autoScrollDisplayLink = nil
        autoScrollDirection = nil
        autoScrollSpeed = 0
    }

    @objc private func handleNativeAutoScrollTick() {
        guard isDragSelecting, let autoScrollDirection else {
            stopNativeAutoScroll()
            return
        }
        let delta = autoScrollSpeed * (autoScrollDirection == .down ? 1 : -1)
        collectionView.contentOffset.y = clampedOffsetY(collectionView.contentOffset.y + delta)
        if var lastDragLocation {
            // Gesture locations are in the collection view content coordinate
            // space, so keep the stored finger point aligned with auto-scroll.
            lastDragLocation.y += delta
            self.lastDragLocation = lastDragLocation
            selectRange(at: lastDragLocation)
        }
        trimPrefetchTasksToCurrentRange()
    }

    private func configureCollectionView() {
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = spacing
        layout.minimumInteritemSpacing = spacing
        layout.sectionInset = sectionInset

        collectionView.backgroundColor = platformBackgroundColor
        collectionView.dataSource = self
        collectionView.prefetchDataSource = self
        collectionView.delegate = self
        collectionView.allowsSelection = true
        collectionView.allowsMultipleSelection = false
        collectionView.alwaysBounceVertical = true
        collectionView.contentInset.bottom = contentInsetBottom
        collectionView.verticalScrollIndicatorInsets.bottom = contentInsetBottom
        view.addSubview(collectionView)

        cellRegistration = UICollectionView.CellRegistration<MediaGridCell, VaultItem> { [weak self] cell, _, item in
            guard let self else { return }
            cell.configure(
                item: item,
                isSelected: selectedItemIDs.contains(item.id),
                isSelecting: isSelecting,
                footerText: footerText?(item)
            )
        }

        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        collectionView.addGestureRecognizer(pinchGesture)
        self.pinchGesture = pinchGesture

        let dragSelectGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleDragSelection(_:)))
        dragSelectGesture.minimumPressDuration = 0.3
        dragSelectGesture.cancelsTouchesInView = true
        dragSelectGesture.delegate = self
        collectionView.addGestureRecognizer(dragSelectGesture)
        self.dragSelectGesture = dragSelectGesture
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        #if DEBUG
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            MediaPerformanceLog.recordCellFor(durationMS: (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        #endif
        let item = items[indexPath.item]
        let cell = collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard !isSelecting,
              let indexPath = indexPaths.first,
              let item = items[safe: indexPath.item] else { return nil }
        return UIContextMenuConfiguration(identifier: indexPath as NSIndexPath, previewProvider: nil) { [weak self] _ in
            self?.onContextMenuForItem?(item)
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        #if DEBUG
        MediaPerformanceLog.recordFirstContentVisibleIfNeeded()
        #endif
        guard indexPath.item == items.count - 1 else { return }
        onReachEnd?(items[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = items[safe: indexPath.item] else { return }
        collectionView.deselectItem(at: indexPath, animated: false)
        if isSelecting {
            toggleSelection(for: item.id)
        } else {
            onOpenItem?(item.id)
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        // Pinch zoom owns two-finger gestures in the media grid. Continuous
        // selection is handled by the custom long-press drag recognizer below.
        false
    }

    func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        setSelectionMode(true)
        if let item = items[safe: indexPath.item], !selectedItemIDs.contains(item.id) {
            applySelection(selectedItemIDs.union([item.id]))
        }
    }

    func collectionViewDidEndMultipleSelectionInteraction(_ collectionView: UICollectionView) {
        finishDragSelection()
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard !isGridScrollingOrSuspended else {
            logPreheatPaused(reason: "scrolling")
            return
        }
        #if DEBUG
        MediaPerformanceLog.mark("grid.prefetch.request", "count=\(indexPaths.count)")
        #endif
        resumePreheatAfterIdle()
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        #if DEBUG
        MediaPerformanceLog.recordPrefetchCancelled(count: indexPaths.count)
        #endif
        for indexPath in indexPaths {
            guard let item = items[safe: indexPath.item] else { continue }
            thumbnailPrefetchTasks[item.id]?.cancel()
            thumbnailPrefetchTasks.removeValue(forKey: item.id)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        #if DEBUG
        MediaPerformanceLog.recordScrollEvent()
        #endif
        let velocityY = scrollView.panGestureRecognizer.velocity(in: scrollView).y
        lastScrollVelocityY = velocityY

        trimPrefetchTasksToCurrentRange()

        if scrollView.isDragging {
            isDraggingGrid = true
            setThumbnailLoadingSuspended(true, reason: "dragging")
            cancelIdleThumbnailResume()
            pausePreheatForScrolling(reason: "scrolling")
        }

        if abs(velocityY) > fastScrollVelocityThreshold {
            setFastScrolling(true, velocityY: velocityY)
            setThumbnailLoadingSuspended(true, reason: "fastScrolling")
            cancelIdleThumbnailResume()
            pausePreheatForScrolling(reason: "scrolling")
            return
        }

        if !isActivelyScrolling {
            setFastScrolling(false, velocityY: velocityY)
            scheduleResumeThumbnailLoadingAfterScrollSettles()
            return
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isDraggingGrid = true
        setThumbnailLoadingSuspended(true, reason: "dragging")
        cancelIdleThumbnailResume()
        pausePreheatForScrolling(reason: "scrolling")
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        isDraggingGrid = false
        isDeceleratingGrid = decelerate
        if decelerate {
            setThumbnailLoadingSuspended(true, reason: "decelerating")
            pausePreheatForScrolling(reason: "scrolling")
        } else {
            scheduleResumeThumbnailLoadingAfterScrollSettles()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isDeceleratingGrid = false
        scheduleResumeThumbnailLoadingAfterScrollSettles()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        isDraggingGrid = false
        isDeceleratingGrid = false
        scheduleResumeThumbnailLoadingAfterScrollSettles()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let availableWidth = collectionView.bounds.width - sectionInset.left - sectionInset.right - spacing * max(effectiveColumnCount - 1, 0)
        let itemWidth = floor(availableWidth / max(effectiveColumnCount, 1))
        return CGSize(width: itemWidth, height: itemWidth)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard !isDragSelecting else { return }
        let location = gesture.location(in: collectionView)
        switch gesture.state {
        case .began:
            isPinchingGrid = true
            setThumbnailLoadingSuspended(true, reason: "pinching")
            pausePreheatForScrolling(reason: "pinching")
            cancelIdleThumbnailResume()
            pinchStartColumnCount = effectiveColumnCount
            capturePinchAnchor(at: location)
        case .changed:
            let nextColumns = min(max(pinchStartColumnCount / max(gesture.scale, 0.2), CGFloat(snapColumnCounts.first ?? 3)), CGFloat(snapColumnCounts.last ?? 7))
            effectiveColumnCount = nextColumns
            updateLayout(animated: false)
            preservePinchAnchor()
            trimPrefetchTasksToCurrentRange()
        case .ended, .cancelled, .failed:
            isPinchingGrid = false
            let snapped = nearestColumnCount(to: effectiveColumnCount)
            effectiveColumnCount = CGFloat(snapped)
            columnCount = snapped
            onColumnCountChanged?(snapped)
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.updateLayout(animated: false)
                self.collectionView.layoutIfNeeded()
                self.preservePinchAnchor()
            } completion: { _ in
                self.scheduleResumeThumbnailLoadingAfterScrollSettles()
            }
        default:
            break
        }
    }

    private func capturePinchAnchor(at location: CGPoint) {
        if let indexPath = collectionView.indexPathForItem(at: location),
           let item = items[safe: indexPath.item],
           let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
            pinchAnchorItemID = item.id
            pinchAnchorScreenOriginY = attributes.frame.minY - collectionView.contentOffset.y
            return
        }

        let visibleIndexPaths = collectionView.indexPathsForVisibleItems
        let nearest = visibleIndexPaths.min { lhs, rhs in
            let leftDistance = collectionView.layoutAttributesForItem(at: lhs).map { abs($0.frame.midY - location.y) } ?? .greatestFiniteMagnitude
            let rightDistance = collectionView.layoutAttributesForItem(at: rhs).map { abs($0.frame.midY - location.y) } ?? .greatestFiniteMagnitude
            return leftDistance < rightDistance
        }

        if let nearest,
           let item = items[safe: nearest.item],
           let attributes = collectionView.layoutAttributesForItem(at: nearest) {
            pinchAnchorItemID = item.id
            pinchAnchorScreenOriginY = attributes.frame.minY - collectionView.contentOffset.y
        }
    }

    private func preservePinchAnchor() {
        guard let pinchAnchorItemID,
              let index = items.firstIndex(where: { $0.id == pinchAnchorItemID }) else {
            return
        }
        collectionView.layoutIfNeeded()
        let indexPath = IndexPath(item: index, section: 0)
        guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        collectionView.contentOffset.y = clampedOffsetY(attributes.frame.minY - pinchAnchorScreenOriginY)
    }

    private func updateLayout(animated: Bool) {
        layout.invalidateLayout()
        if animated {
            collectionView.performBatchUpdates(nil)
        }
    }

    @objc private func handleDragSelection(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: collectionView)

        switch gesture.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(at: location),
                  let item = items[safe: indexPath.item] else { return }
            setSelectionMode(true)
            isDragSelecting = true
            setThumbnailLoadingSuspended(true, reason: "dragSelecting")
            pausePreheatForScrolling(reason: "dragSelecting")
            collectionView.isScrollEnabled = false
            pinchGesture?.isEnabled = false
            dragStartItemID = item.id
            dragBaselineSelectedItemIDs = selectedItemIDs
            dragSelectionMode = selectedItemIDs.contains(item.id) ? .deselect : .select
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selectRange(to: item.id)
            updateAutoScroll(for: location)
        case .changed:
            guard isDragSelecting else { return }
            lastDragLocation = location
            selectRange(at: location)
            updateAutoScroll(for: location)
        case .ended, .cancelled, .failed:
            finishDragSelection()
        default:
            break
        }
    }

    private func finishDragSelection() {
        isDragSelecting = false
        dragStartItemID = nil
        dragBaselineSelectedItemIDs.removeAll()
        dragSelectionMode = .select
        lastDragLocation = nil
        collectionView.isScrollEnabled = true
        pinchGesture?.isEnabled = true
        stopNativeAutoScroll()
        scheduleResumeThumbnailLoadingAfterScrollSettles()
    }

    private func setSelectionMode(_ enabled: Bool) {
        guard isSelecting != enabled else { return }
        isSelecting = enabled
        DispatchQueue.main.async { [onSelectionModeChanged] in
            onSelectionModeChanged?(enabled)
        }
        reconfigureSelectionChanges(from: selectedItemIDs, previousIsSelecting: !enabled)
    }

    private func toggleSelection(for itemID: UUID) {
        var nextSelection = selectedItemIDs
        if nextSelection.contains(itemID) {
            nextSelection.remove(itemID)
        } else {
            nextSelection.insert(itemID)
        }
        applySelection(nextSelection)
    }

    private func applySelection(_ nextSelection: Set<UUID>) {
        let previousSelection = selectedItemIDs
        selectedItemIDs = nextSelection
        DispatchQueue.main.async { [onSelectionChanged] in
            onSelectionChanged?(nextSelection)
        }
        reconfigureSelectionChanges(from: previousSelection, previousIsSelecting: isSelecting)
    }

    private func selectRange(at location: CGPoint) {
        guard let indexPath = collectionView.indexPathForItem(at: location),
              let item = items[safe: indexPath.item] else { return }
        selectRange(to: item.id)
    }

    private func selectRange(to itemID: UUID) {
        guard let startItemID = dragStartItemID,
              let startIndex = items.firstIndex(where: { $0.id == startItemID }),
              let endIndex = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        let lowerBound = min(startIndex, endIndex)
        let upperBound = max(startIndex, endIndex)
        let rangeIDs = Set(items[lowerBound...upperBound].map(\.id))
        switch dragSelectionMode {
        case .select:
            applySelection(dragBaselineSelectedItemIDs.union(rangeIDs))
        case .deselect:
            applySelection(dragBaselineSelectedItemIDs.subtracting(rangeIDs))
        }
    }

    private func updateAutoScroll(for location: CGPoint) {
        lastDragLocation = location
        guard isDragSelecting else {
            stopNativeAutoScroll()
            return
        }

        // Measure distances from the actual visible content boundaries rather than
        // the raw frame edges. adjustedContentInset accounts for navigation bar
        // top inset and tab-bar / contentInsetBottom at the bottom, so the trigger
        // zone is consistent regardless of the surrounding chrome. The threshold is
        // 160 pt (up from 128) to make edge-scroll reliable in the 3-column /
        // largest-zoom layout where cells are ~122 pt tall.
        let threshold: CGFloat = 160
        let inset = collectionView.adjustedContentInset
        let screenY = location.y - collectionView.bounds.minY
        let topDistance = screenY - inset.top
        let bottomDistance = (collectionView.bounds.maxY - collectionView.bounds.minY) - inset.bottom - screenY

        let nextDirection: AutoScrollDirection?
        let edgeDistance: CGFloat
        if topDistance < threshold {
            nextDirection = .up
            edgeDistance = threshold - max(topDistance, 0)
        } else if bottomDistance < threshold {
            nextDirection = .down
            edgeDistance = threshold - max(bottomDistance, 0)
        } else {
            nextDirection = nil
            edgeDistance = 0
        }

        guard let nextDirection else {
            stopNativeAutoScroll()
            return
        }

        autoScrollDirection = nextDirection
        autoScrollSpeed = max(2, pow(edgeDistance / threshold, 1.35) * 18)
        guard autoScrollDisplayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(handleNativeAutoScrollTick))
        displayLink.add(to: .main, forMode: .common)
        autoScrollDisplayLink = displayLink
    }

    private func schedulePreheatAroundVisibleItems(delay: TimeInterval) {
        guard !isGridScrollingOrSuspended else {
            logPreheatPaused(reason: "scrolling")
            return
        }
        cancelPendingPreheat()
        let workItem = DispatchWorkItem { [weak self] in
            self?.preheatAroundVisibleItems()
        }
        pendingPreheatWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelPendingPreheat() {
        pendingPreheatWorkItem?.cancel()
        pendingPreheatWorkItem = nil
    }

    private func cancelPreheatBatch() {
        preheatBatchTask?.cancel()
        preheatBatchTask = nil
    }

    private func trimPrefetchTasksToCurrentRange() {
        guard let range = currentPreheatRange() else { return }
        cancelPrefetchTasks(outside: range.keepIDs)
        if !isDragSelecting || isGridScrollingOrSuspended {
            cancelPreheatBatch()
        }
    }

    private func preheatAroundVisibleItems() {
        guard !isGridScrollingOrSuspended else {
            logPreheatPaused(reason: "scrolling")
            return
        }
        guard let range = currentPreheatRange() else { return }
        let rangeKey = "\(range.startIndex)-\(range.endIndex)-\(Int(round(effectiveColumnCount)))-\(items.count)"
        guard rangeKey != lastPreheatRangeKey else { return }
        lastPreheatRangeKey = rangeKey
        cancelPrefetchTasks(outside: range.keepIDs)

        let side = MediaThumbnailService.gridThumbnailSide
        let size = CGSize(width: side, height: side)
        let targetItems = items[range.startIndex...range.endIndex].filter { item in
            thumbnailPrefetchTasks[item.id] == nil &&
            MediaThumbnailService.shared.cachedThumbnailInMemory(for: item.id, size: size) == nil
        }
        #if DEBUG
        MediaPerformanceLog.mark(
            "grid.preheat.range",
            "visible=\(collectionView.indexPathsForVisibleItems.count) start=\(range.startIndex) end=\(range.endIndex) targets=\(targetItems.count) columns=\(Int(round(effectiveColumnCount)))"
        )
        #endif
        startBatchedThumbnailPrefetch(for: Array(targetItems), size: size)
    }

    private func currentPreheatRange() -> (startIndex: Int, endIndex: Int, keepIDs: Set<UUID>)? {
        guard !items.isEmpty else { return nil }
        let visibleIndexPaths = collectionView.indexPathsForVisibleItems
        guard let firstVisible = visibleIndexPaths.map(\.item).min(),
              let lastVisible = visibleIndexPaths.map(\.item).max() else { return nil }

        let columns = max(1, Int(round(effectiveColumnCount)))
        let rowBuffer = columns
        let startIndex = max(0, firstVisible - rowBuffer)
        let endIndex = min(items.count - 1, lastVisible + rowBuffer)
        let keepStartIndex = max(0, firstVisible - rowBuffer)
        let keepEndIndex = min(items.count - 1, lastVisible + rowBuffer)
        let keepIDs = Set(items[keepStartIndex...keepEndIndex].map(\.id))
        return (startIndex, endIndex, keepIDs)
    }

    private func cancelPrefetchTasks(outside keepIDs: Set<UUID>) {
        let removableTaskIDs = thumbnailPrefetchTasks.keys.filter { !keepIDs.contains($0) }
        #if DEBUG
        MediaPerformanceLog.recordPrefetchCancelled(count: removableTaskIDs.count)
        #endif
        for itemID in removableTaskIDs {
            guard let task = thumbnailPrefetchTasks[itemID] else { continue }
            task.cancel()
            thumbnailPrefetchTasks.removeValue(forKey: itemID)
        }
    }

    private func startThumbnailPrefetch(for item: VaultItem, size: CGSize) {
        guard !isGridScrollingOrSuspended else {
            logPreheatPaused(reason: "scrolling")
            return
        }
        #if DEBUG
        MediaPerformanceLog.mark("grid.preheat.task.start", "item=\(MediaPerformanceLog.idHash(item.id))")
        #endif
        thumbnailPrefetchTasks[item.id] = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            guard await MainActor.run(body: { !self.isGridScrollingOrSuspended }) else {
                await MainActor.run {
                    self.logPreheatPaused(reason: "scrolling")
                    self.thumbnailPrefetchTasks.removeValue(forKey: item.id)
                }
                return
            }
            _ = await MediaThumbnailService.shared.thumbnail(for: item, size: size, priority: .utility)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                #if DEBUG
                MediaPerformanceLog.mark("grid.preheat.task.finish", "item=\(MediaPerformanceLog.idHash(item.id))")
                #endif
                self.thumbnailPrefetchTasks.removeValue(forKey: item.id)
            }
        }
    }

    private func startBatchedThumbnailPrefetch(for targetItems: [VaultItem], size: CGSize) {
        cancelPreheatBatch()
        guard !targetItems.isEmpty, !isGridScrollingOrSuspended else { return }

        let batchSize = idlePreheatBatchSize
        #if DEBUG
        MediaPerformanceLog.mark("grid.preheat.batch.start", "totalTargets=\(targetItems.count) currentBatch=\(min(batchSize, targetItems.count)) batchSize=\(batchSize)")
        #endif
        preheatBatchTask = Task { [weak self] in
            var index = 0
            while index < targetItems.count && !Task.isCancelled {
                let upperBound = min(index + batchSize, targetItems.count)
                let batch = Array(targetItems[index..<upperBound])
                await MainActor.run {
                    guard let self, !self.isGridScrollingOrSuspended else { return }
                    #if DEBUG
                    MediaPerformanceLog.mark("grid.preheat.batch.dispatch", "range=\(index)..<\(upperBound) count=\(batch.count)")
                    #endif
                    for item in batch {
                        guard self.thumbnailPrefetchTasks[item.id] == nil,
                              MediaThumbnailService.shared.cachedThumbnailInMemory(for: item.id, size: size) == nil else { continue }
                        self.startThumbnailPrefetch(for: item, size: size)
                    }
                }
                index = upperBound
                try? await Task.sleep(nanoseconds: 32_000_000)
            }
        }
    }

    private func setThumbnailLoadingSuspended(_ suspended: Bool, reason: String) {
        guard thumbnailLoadingSuspended != suspended else { return }
        thumbnailLoadingSuspended = suspended
        VisibleThumbnailRequestCoordinator.shared.setSuspended(suspended, reason: reason)
        #if DEBUG
        MediaPerformanceLog.mark("grid.thumbnail.suspend", "\(suspended) reason=\(reason)")
        #endif
        if suspended {
            lastPreheatRangeKey = nil
            cancelPendingPreheat()
            cancelPreheatBatch()
            thumbnailPrefetchTasks.values.forEach { $0.cancel() }
            thumbnailPrefetchTasks.removeAll()
            #if DEBUG
            MediaPerformanceLog.mark("thumbnail.uiUpdate.deferred", "reason=scrolling")
            #endif
        }
    }

    private var isActivelyScrolling: Bool {
        collectionView.isDragging ||
            collectionView.isDecelerating ||
            isPinchingGrid ||
            isDragSelecting ||
            abs(lastScrollVelocityY) > fastScrollVelocityThreshold
    }

    private var isGridScrollingOrSuspended: Bool {
        thumbnailLoadingSuspended || isActivelyScrolling
    }

    private func cancelIdleThumbnailResume() {
        resumeThumbnailWorkItem?.cancel()
        resumeThumbnailWorkItem = nil
    }

    private func pausePreheatForScrolling(reason: String) {
        logPreheatPaused(reason: reason)
        lastPreheatRangeKey = nil
        cancelPendingPreheat()
        cancelPreheatBatch()
        thumbnailPrefetchTasks.values.forEach { $0.cancel() }
        thumbnailPrefetchTasks.removeAll()
    }

    private func resumePreheatAfterIdle() {
        guard !isGridScrollingOrSuspended else { return }
        #if DEBUG
        MediaPerformanceLog.mark("grid.preheat.resumeAfterIdle", "visible=\(collectionView.indexPathsForVisibleItems.count)")
        #endif
        schedulePreheatAroundVisibleItems(delay: 0.25)
    }

    private func reconfigureVisibleItemsAfterIdleInBatches() {
        let visibleIndexPaths = collectionView.indexPathsForVisibleItems.sorted()
        guard !visibleIndexPaths.isEmpty else {
            resumePreheatAfterIdle()
            return
        }
        reconfigureVisibleItemsAfterIdleInBatches(visibleIndexPaths, startIndex: 0)
    }

    private func reconfigureVisibleItemsAfterIdleInBatches(_ visibleIndexPaths: [IndexPath], startIndex: Int) {
        guard !isGridScrollingOrSuspended else {
            #if DEBUG
            MediaPerformanceLog.mark("thumbnail.uiUpdate.deferred", "reason=scrolling")
            #endif
            return
        }
        guard startIndex < visibleIndexPaths.count else {
            resumePreheatAfterIdle()
            return
        }

        let endIndex = min(startIndex + idleVisibleReconfigureBatchSize, visibleIndexPaths.count)
        let batch = Array(visibleIndexPaths[startIndex..<endIndex])
        VisibleThumbnailRequestCoordinator.shared.performVisibleRequestPass {
            collectionView.reconfigureItems(at: batch)
        }
        #if DEBUG
        MediaPerformanceLog.mark("thumbnail.uiUpdate.flush", "count=\(batch.count)")
        #endif

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.024) { [weak self] in
            self?.reconfigureVisibleItemsAfterIdleInBatches(visibleIndexPaths, startIndex: endIndex)
        }
    }

    private func scheduleResumeThumbnailLoadingAfterScrollSettles() {
        cancelIdleThumbnailResume()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let velocityY = self.collectionView.panGestureRecognizer.velocity(in: self.collectionView).y
            if self.collectionView.isDragging || self.collectionView.isDecelerating || self.isPinchingGrid || self.isDragSelecting || abs(velocityY) > self.idleVelocityThreshold {
                self.scheduleResumeThumbnailLoadingAfterScrollSettles()
                return
            }
            self.isDraggingGrid = false
            self.isDeceleratingGrid = false
            self.setFastScrolling(false, velocityY: velocityY)
            self.setThumbnailLoadingSuspended(false, reason: "idle")
            self.lastLoggedPreheatPauseReason = nil
            #if DEBUG
            MediaPerformanceLog.mark("grid.thumbnail.resume", "reason=idle visibleCount=\(self.collectionView.indexPathsForVisibleItems.count)")
            #endif
            self.reconfigureVisibleItemsAfterIdleInBatches()
        }
        resumeThumbnailWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + thumbnailIdleResumeDelay, execute: workItem)
    }

    private func setFastScrolling(_ fastScrolling: Bool, velocityY: CGFloat) {
        guard isFastScrolling != fastScrolling else { return }
        isFastScrolling = fastScrolling
        #if DEBUG
        MediaPerformanceLog.mark("grid.scroll.fastScrolling", "\(fastScrolling) velocity=\(String(format: "%.1f", velocityY))")
        #endif
    }

    private func logPreheatPaused(reason: String) {
        guard lastLoggedPreheatPauseReason != reason else { return }
        lastLoggedPreheatPauseReason = reason
        #if DEBUG
        MediaPerformanceLog.mark("grid.preheat.paused", "reason=\(reason)")
        #endif
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === dragSelectGesture {
            let location = gestureRecognizer.location(in: collectionView)
            return collectionView.indexPathForItem(at: location) != nil
        }
        if gestureRecognizer === pinchGesture {
            return !isDragSelecting
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === dragSelectGesture || otherGestureRecognizer === dragSelectGesture {
            return false
        }
        if gestureRecognizer === pinchGesture || otherGestureRecognizer === pinchGesture {
            return !isDragSelecting
        }
        return true
    }

    private func nearestColumnCount(to value: CGFloat) -> Int {
        snapColumnCounts.min { lhs, rhs in
            abs(CGFloat(lhs) - value) < abs(CGFloat(rhs) - value)
        } ?? 5
    }

    private func clampedOffsetY(_ proposedY: CGFloat) -> CGFloat {
        let minY = -collectionView.adjustedContentInset.top
        let maxY = max(
            minY,
            collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
        )
        return min(max(proposedY, minY), maxY)
    }
}

// MARK: - macOS Catalyst drag-out

#if targetEnvironment(macCatalyst)
extension ZoomableMediaGridViewController: UICollectionViewDragDelegate {
    /// Provide drag items when the user begins dragging a cell to Finder.
    /// Only active on macOS Catalyst. Falls through to nothing when:
    ///   - the grid is in multi-select mode (drag = extend selection)
    ///   - `onDragItem` is not set (e.g., trash / archive albums)
    ///   - the export pipeline can't produce a temp file (encrypted inaccessible, etc.)
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard !isSelecting,
              indexPath.item < items.count,
              let onDragItem else { return [] }

        let item = items[indexPath.item]
        guard let provider = onDragItem(item) else { return [] }

        let dragItem = UIDragItem(itemProvider: provider)
        dragItem.localObject = item
        return [dragItem]
    }

    /// Round-rect preview that matches the cell corner radius.
    func collectionView(
        _ collectionView: UICollectionView,
        dragPreviewParametersForItemAt indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        let params = UIDragPreviewParameters()
        params.backgroundColor = .clear
        params.visiblePath = UIBezierPath(roundedRect: cell.bounds, cornerRadius: 10)
        return params
    }
}
#endif

private final class MediaGridCell: UICollectionViewCell {
    private let thumbnailImageView: UIImageView = {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return v
    }()

    private let placeholderView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.secondarySystemFill
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return v
    }()

    private let placeholderIconView: UIImageView = {
        let v = UIImageView()
        v.contentMode = .center
        v.tintColor = .secondaryLabel
        v.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let kindBadgeView: UIImageView = {
        let v = UIImageView()
        v.contentMode = .center
        v.tintColor = .white
        v.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.6
        v.layer.shadowRadius = 2
        v.layer.shadowOffset = CGSize(width: 0, height: 1)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let selectionRing: UIView = {
        let v = UIView()
        v.layer.cornerRadius = 10
        v.layer.borderWidth = 3
        v.layer.borderColor = UIColor.clear.cgColor
        v.isUserInteractionEnabled = false
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return v
    }()

    private let selectionBadgeContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    private let selectionCircleView: UIView = {
        let v = UIView()
        v.layer.cornerRadius = 12
        v.frame = CGRect(origin: .zero, size: CGSize(width: 24, height: 24))
        return v
    }()

    private let selectionCheckmarkView: UIImageView = {
        let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        let v = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: cfg))
        v.tintColor = .white
        v.contentMode = .center
        v.frame = CGRect(origin: .zero, size: CGSize(width: 24, height: 24))
        v.isHidden = true
        return v
    }()

    private let footerPillView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        v.isHidden = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let footerLabel: UILabel = {
        let l = UILabel()
        l.textColor = .white
        l.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        l.numberOfLines = 1
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private(set) var currentItemID: UUID?
    private var pendingRequestID: UUID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = 10

        placeholderView.frame = contentView.bounds
        contentView.addSubview(placeholderView)

        placeholderView.addSubview(placeholderIconView)

        thumbnailImageView.frame = contentView.bounds
        contentView.addSubview(thumbnailImageView)

        selectionRing.frame = contentView.bounds
        contentView.addSubview(selectionRing)

        contentView.addSubview(kindBadgeView)
        contentView.addSubview(selectionBadgeContainer)
        selectionBadgeContainer.addSubview(selectionCircleView)
        selectionBadgeContainer.addSubview(selectionCheckmarkView)

        footerPillView.addSubview(footerLabel)
        contentView.addSubview(footerPillView)

        NSLayoutConstraint.activate([
            placeholderIconView.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            placeholderIconView.centerYAnchor.constraint(equalTo: placeholderView.centerYAnchor),

            kindBadgeView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            kindBadgeView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            kindBadgeView.widthAnchor.constraint(equalToConstant: 20),
            kindBadgeView.heightAnchor.constraint(equalToConstant: 20),

            selectionBadgeContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            selectionBadgeContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            selectionBadgeContainer.widthAnchor.constraint(equalToConstant: 24),
            selectionBadgeContainer.heightAnchor.constraint(equalToConstant: 24),

            footerPillView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            footerPillView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),

            footerLabel.topAnchor.constraint(equalTo: footerPillView.topAnchor, constant: 4),
            footerLabel.bottomAnchor.constraint(equalTo: footerPillView.bottomAnchor, constant: -4),
            footerLabel.leadingAnchor.constraint(equalTo: footerPillView.leadingAnchor, constant: 7),
            footerLabel.trailingAnchor.constraint(equalTo: footerPillView.trailingAnchor, constant: -7),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        footerPillView.layer.cornerRadius = footerPillView.bounds.height / 2
    }

    func configure(item: VaultItem, isSelected: Bool, isSelecting: Bool, footerText: String?) {
        let itemChanged = currentItemID != item.id
        currentItemID = item.id

        if itemChanged {
            cancelPendingRequest()
            thumbnailImageView.image = nil
            placeholderIconView.image = UIImage(systemName: item.mediaKind.symbolName)
            placeholderView.isHidden = false
        }

        kindBadgeView.image = UIImage(systemName: item.mediaKind.symbolName)

        selectionBadgeContainer.isHidden = !isSelecting
        selectionRing.layer.borderColor = isSelected ? UIColor.tintColor.cgColor : UIColor.clear.cgColor
        selectionCircleView.backgroundColor = isSelected ? .tintColor : UIColor.white.withAlphaComponent(0.2)
        selectionCircleView.layer.borderWidth = isSelected ? 0 : 1.5
        selectionCircleView.layer.borderColor = UIColor.white.cgColor
        selectionCheckmarkView.isHidden = !isSelected

        if let text = footerText {
            footerLabel.text = text
            footerPillView.isHidden = false
        } else {
            footerPillView.isHidden = true
        }

        let side = MediaThumbnailService.gridThumbnailSide
        let size = CGSize(width: side, height: side)
        if let cached = MediaThumbnailService.shared.cachedThumbnailInMemory(for: item.id, size: size) {
            thumbnailImageView.image = cached
            placeholderView.isHidden = true
            return
        }

        if VisibleThumbnailRequestCoordinator.shared.allowsVisibleRequests {
            enqueueThumbnailRequest(item: item, size: size)
        }
    }

    func enqueueThumbnailRequest(item: VaultItem, size: CGSize) {
        guard currentItemID == item.id else { return }
        cancelPendingRequest()
        let reqID = VisibleThumbnailRequestCoordinator.shared.enqueue(item: item, size: size) { [weak self] requestID, itemID, image in
            guard let self,
                  self.pendingRequestID == requestID,
                  self.currentItemID == itemID,
                  let image else { return }
            self.pendingRequestID = nil
            UIView.transition(with: self.thumbnailImageView, duration: 0.16, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.thumbnailImageView.image = image
                self.placeholderView.isHidden = true
            }
        }
        pendingRequestID = reqID
    }

    func cancelPendingRequest() {
        guard let id = pendingRequestID else { return }
        VisibleThumbnailRequestCoordinator.shared.cancel(id)
        pendingRequestID = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct MediaLibraryDebugView: View {
    @ObservedObject var viewModel: MediaLibraryViewModel
    let albumID: UUID

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "当前资源")) {
                    ForEach(viewModel.debugInfo(for: albumID)) { info in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(info.name)
                                    .font(.headline)
                                Spacer()
                                Text(info.exists ? String(localized: "存在") : String(localized: "丢失"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(info.exists ? .green : .red)
                            }

                            Text(String.localizedStringWithFormat(
                                String(localized: "%1$@ · %2$@ · %3$lld bytes"),
                                info.mediaKind,
                                info.contentType.isEmpty ? String(localized: "未知类型") : info.contentType,
                                info.byteCount
                            ))
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Text(info.relativePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Text(info.absolutePath)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                    }
                }

                Section(String(localized: "最近日志")) {
                    ForEach(viewModel.debugMessages, id: \.self) { message in
                        Text(message)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(String(localized: "资源库调试"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "完成")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SelectionBarGlassStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .padding(.horizontal, 6)
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color(.separator).opacity(0.2), lineWidth: 0.5)
                }
                .shadow(color: Color.black.opacity(0.08), radius: 10, y: 2)
        }
    }
}

#Preview {
    NavigationStack {
        AlbumDetailView(
            viewModel: PreviewSupport.mediaLibraryViewModel(),
            albumID: UUID()
        )
    }
}
