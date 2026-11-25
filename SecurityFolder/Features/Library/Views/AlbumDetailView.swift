import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import UIKit
import GameController

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
    var searchesWholeSpace = false
    var searchFocusRequest: UUID? = nil
    var sharedSearchQuery: Binding<MediaSearchQuery>? = nil
    @State private var localSearchQuery = MediaSearchQuery()

    private var searchQuery: MediaSearchQuery {
        get { sharedSearchQuery?.wrappedValue ?? localSearchQuery }
        nonmutating set {
            if let sharedSearchQuery { sharedSearchQuery.wrappedValue = newValue }
            else { localSearchQuery = newValue }
        }
    }

    private var searchQueryBinding: Binding<MediaSearchQuery> {
        sharedSearchQuery ?? $localSearchQuery
    }
    @State private var showingSearchFilters = false
    @State private var matchingItems: [VaultItem] = []
    @State private var searchIsAvailable = true
    @State private var isSearching = false
    @State private var hasFocusedSearch = false
    @FocusState private var searchFocused: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AppSettingsKey.advancedDataProtectionEnabled)
    private var advancedDataProtectionEnabled = AppSettingsKey.defaultAdvancedDataProtectionEnabled
    @AppStorage(AppSettingsKey.deleteImportedSystemAssetsAfterImport)
    private var deleteImportedSystemAssetsAfterImport = AppSettingsKey.defaultDeleteImportedSystemAssetsAfterImport

    @State private var selectedItemIDs = Set<UUID>()
    @State private var isSelecting = false
    @StateObject private var importFlow = MediaImportFlowController()
    @State private var showingAlbumPicker = false
    @State private var showingCustomSort = false
    @State private var previewSelection: PreviewSelection?
    @State private var photoPreviewItemID: UUID?
    @State private var photoTransitionSource = PhotoPreviewTransitionSource()
    @State private var shareURLs: [URL] = []
    @State private var showingShareSheet = false
    @State private var pendingOperation: PendingMediaOperation?
    @State private var renamingItem: VaultItem?
    @State private var renameText = ""
    @State private var detailItemID: UUID?
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

    private var usesSearchResults: Bool { searchesWholeSpace || searchQuery.isActive }

    private var searchFieldPlacement: SearchFieldPlacement {
        #if targetEnvironment(macCatalyst)
        .toolbar
        #else
        horizontalSizeClass == .regular ? .toolbar : .navigationBarDrawer(displayMode: .always)
        #endif
    }

    private var automaticallyFocusesSearch: Bool {
        sharedSearchQuery == nil && (UIDevice.current.userInterfaceIdiom != .pad || GCKeyboard.coalesced != nil)
    }

    private var searchRequest: MediaSearchRequest {
        MediaSearchRequest(query: searchQuery, albumID: albumID, wholeSpace: searchesWholeSpace,
                           revision: viewModel.mediaPresentationRevision, enabled: searchIsAvailable)
    }

    private var previewItems: [VaultItem] {
        guard searchIsAvailable else { return [] }
        return usesSearchResults ? matchingItems : viewModel.mediaItems(for: albumID)
    }

    private func loggedMediaItemsPage(limit: Int) -> MediaItemsPage {
        guard searchIsAvailable else { return MediaItemsPage(items: [], totalCount: 0) }
        if usesSearchResults {
            let matches = matchingItems
            return MediaItemsPage(items: Array(matches.prefix(limit)), totalCount: matches.count)
        }

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
            .onDrop(of: viewModel.vaultDropTypeIdentifiers, isTargeted: $importFlow.isDropTargeted) { providers in
                importFlow.handleDroppedMedia(providers, targetAlbumID: albumID, viewModel: viewModel)
            }
            // Always-present overlay driven by opacity; toggling it with `if`
            // during a drag breaks Catalyst's drag tracking and leaves the
            // "Drop to import" overlay stuck on screen.
            .overlay {
                DropImportOverlayView()
                    .opacity(importFlow.isDropTargeted ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: importFlow.isDropTargeted)
            }
        }
        .task(id: items.map(\.id)) {
            await viewModel.loadMissingVideoDurations(itemIDs: items.map(\.id))
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
        .navigationTitle(navigationTitle(albumName: searchesWholeSpace ? String(localized: "搜索当前空间") : viewModel.album(for: albumID)?.displayName, selectedCount: selectedItemIDs.count, totalCount: totalItemCount))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(MediaSearchFieldStyle(
            text: searchQueryBinding.text,
            placement: searchFieldPlacement,
            prompt: searchesWholeSpace ? String(localized: "搜索照片、视频和相册") : String(localized: "在此相册中搜索"),
            focus: $searchFocused,
            isEnabled: sharedSearchQuery == nil && !isSelecting
        ))
        .onChange(of: searchFocusRequest, initial: true) { _, request in
            if request != nil && searchIsAvailable && automaticallyFocusesSearch { searchFocused = true }
        }
        .task {
            if searchesWholeSpace && !hasFocusedSearch && !searchQuery.isActive {
                hasFocusedSearch = true
                await Task.yield()
                guard searchIsAvailable, automaticallyFocusesSearch else { return }
                searchFocused = true
            }
        }
        .task(id: searchRequest) {
            let request = searchRequest
            guard usesSearchResults, request.enabled,
                  !searchesWholeSpace || request.query.isActive else {
                matchingItems = []
                isSearching = false
                return
            }
            isSearching = true
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            let matches = await viewModel.searchItems(query: request.query, albumID: request.albumID, wholeSpace: request.wholeSpace)
            guard !Task.isCancelled, searchIsAvailable, request == searchRequest else { return }
            matchingItems = matches
            isSearching = false
        }
        .onChange(of: searchQuery) { _, _ in
            matchingItems = []
            isSearching = usesSearchResults && (!searchesWholeSpace || searchQuery.isActive)
            visibleItemLimit = initialVisibleItemLimit
            exitSelectionMode()
        }
        .onChange(of: viewModel.mediaPresentationRevision) { _, _ in
            selectedItemIDs.formIntersection(Set(viewModel.items.map(\.id)))
            if usesSearchResults { matchingItems = [] }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultDidLock)) { _ in
            viewModel.isDraggingVaultItems = false
            searchIsAvailable = false
            matchingItems = []
            isSearching = false
            searchQuery = MediaSearchQuery()
            searchFocused = false
            showingSearchFilters = false
            previewSelection = nil
            photoPreviewItemID = nil
            exitSelectionMode()
        }
        .onDisappear {
            viewModel.isDraggingVaultItems = false
        }
        .toolbar {
            if searchFocused {
                ToolbarItem(placement: .keyboard) {
                    Button(String(localized: "完成")) { searchFocused = false }
                }
            }

            topBarToolbar(currentSortOption: currentSortOption)
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
        .mediaImportFlow(
            controller: importFlow,
            viewModel: viewModel,
            deleteOriginalAfterImport: deleteImportedSystemAssetsAfterImport,
            targetAlbumID: { albumID }
        )
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
        .background {
            PhotoPreviewPresentation(itemID: $photoPreviewItemID, source: photoTransitionSource) { itemID, close in
                MediaPreviewView(
                    viewModel: viewModel,
                    albumID: albumID,
                    items: previewItems,
                    initialItemID: itemID,
                    photoTransitionSource: photoTransitionSource,
                    closesAfterMutation: usesSearchResults,
                    onDismissOverride: close
                )
            }
            .frame(width: 0, height: 0)
        }
        .fullScreenCover(item: $previewSelection) { selection in
            let previewItems = self.previewItems
            if albumKind?.isSecure == true {
                if let selectedItem = previewItems.first(where: { $0.id == selection.id }) {
                    SecureMediaPreviewView(
                        viewModel: viewModel,
                        albumID: albumID,
                        item: selectedItem
                    )
                } else {
                    Color.black
                        .ignoresSafeArea()
                        .onAppear {
                            previewSelection = nil
                        }
                }
            } else {
                MediaPreviewView(
                    viewModel: viewModel,
                    albumID: albumID,
                    items: previewItems,
                    initialItemID: selection.id,
                    closesAfterMutation: usesSearchResults
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
            if totalItemCount == 0 && !isSearching {
                ContentUnavailableView {
                    Label(searchesWholeSpace && !searchQuery.isActive ? String(localized: "搜索当前空间") : (usesSearchResults ? String(localized: "未找到结果") : String(localized: "暂无内容")), systemImage: usesSearchResults ? "magnifyingglass" : "photo.on.rectangle.angled")
                } description: {
                    Text(searchesWholeSpace && !searchQuery.isActive ? String(localized: "输入名称，或使用筛选查找照片与视频。") : (usesSearchResults ? String(localized: "尝试其他名称，或调整筛选条件。") : ""))
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { searchSummary }
        .onChange(of: albumID) { _, _ in
            visibleItemLimit = initialVisibleItemLimit
            searchQuery = MediaSearchQuery()
        }
        .onChange(of: totalItemCount) { _, newCount in
            visibleItemLimit = min(max(visibleItemLimit, initialVisibleItemLimit), max(newCount, initialVisibleItemLimit))
        }
    }

    @ViewBuilder
    private var searchSummary: some View {
        if searchIsAvailable && searchQuery.isActive {
            VStack(alignment: .leading, spacing: 8) {
                if searchesWholeSpace && !searchQuery.normalizedText.isEmpty {
                    let albums = viewModel.searchAlbums(text: searchQuery.text)
                    if !albums.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(albums) { album in
                                    NavigationLink {
                                        AlbumDetailView(viewModel: viewModel, albumID: album.id)
                                    } label: {
                                        Label(album.name, systemImage: "rectangle.stack")
                                            .padding(.horizontal, 12).frame(minHeight: 44)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .accessibilityLabel(String(localized: "匹配的相册"))
                    }
                }
                if searchQuery.isActive { searchStatus }
            }
            .padding(.horizontal).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
        }
    }

    private var searchStatus: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if isSearching {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "正在搜索"))
                    } else {
                        Text(String.localizedStringWithFormat(String(localized: "%lld 个结果"), Int64(matchingItems.count)))
                    }
                }
                if searchQuery.type != .all {
                    Text(searchQuery.type.title)
                }
                if searchQuery.usesDateRange {
                    Text("\(searchQuery.dateField.title): \(searchQuery.startDate.formatted(date: .abbreviated, time: .omitted)) – \(searchQuery.endDate.formatted(date: .abbreviated, time: .omitted))")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if searchQuery.type != .all || searchQuery.usesDateRange {
                Button(String(localized: "清除筛选")) { clearSearchFilters() }
                    .frame(minHeight: 44)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(.subheadline).foregroundStyle(.secondary)
    }

    private func clearSearchFilters() {
        let text = searchQuery.text
        searchQuery = MediaSearchQuery()
        searchQuery.text = text
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
            renderToken: viewModel.mediaPresentationRevision,
            currentAlbumID: albumID,
            photoTransitionSource: photoTransitionSource,
            allItems: { previewItems },
            onRevealItems: { [limit = $visibleItemLimit] requiredCount in
                limit.wrappedValue = max(limit.wrappedValue, requiredCount)
            },
            selectedItemIDs: selectedItemIDs,
            isSelecting: isSelecting,
            onReachEnd: { item in
                loadMoreItemsIfNeeded(currentItem: item, displayedItems: items, totalItemCount: totalItemCount)
            },
            onOpenItem: { itemID in
                searchFocused = false
                #if targetEnvironment(macCatalyst)
                previewSelection = PreviewSelection(id: itemID)
                #else
                if let item = items.first(where: { $0.id == itemID }), item.mediaKind != .video {
                    photoPreviewItemID = itemID
                } else {
                    previewSelection = PreviewSelection(id: itemID)
                }
                #endif
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
            onDragItem: { makeDragItemProvider(for: $0, allowExternalExport: $1 && albumKind != .trash) },
            onDragActivityChanged: { viewModel.isDraggingVaultItems = $0 }
        )
        .ignoresSafeArea(.container, edges: .bottom)
    }

    /// The internal payload is available without decrypting the file.
    private func makeDragItemProvider(for item: VaultItem, allowExternalExport: Bool) -> NSItemProvider? {
        let provider = NSItemProvider()
        provider.suggestedName = item.name

        let payload = VaultItemDragPayload(
            space: item.space,
            sourceAlbumID: albumID,
            itemID: item.id
        )
        if let encodedPayload = try? JSONEncoder().encode(payload) {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.privyVaultItemTransfer.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(encodedPayload, nil)
                return nil
            }
        }

        if allowExternalExport, !item.isStrongProtected, !item.isInTrash,
           let generation = VaultCryptoService.shared.temporaryExportGeneration(for: item.space) {
            let itemID = item.id
            let space = item.space
            let path = item.relativePath
            let filename = item.originalFilename
            let library = viewModel
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                // Catalyst can synchronously wait on the main thread for this pasteboard flavor.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let url = try VaultFileStorageService.shared.decryptedTemporaryURL(
                            for: path, originalFilename: filename, space: space, exportGeneration: generation
                        )
                        guard VaultCryptoService.shared.temporaryExportGeneration(for: space) == generation,
                              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                            throw CocoaError(.fileReadNoSuchFile)
                        }
                        completion(url.dataRepresentation, nil)
                        Task { @MainActor in
                            library.markDragExportPrepared(itemID: itemID, relativePath: path, generation: generation)
                        }
                    } catch {
                        completion(nil, error)
                    }
                }
                return nil
            }
        }

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

        if albumKind != .trash {
            actions.append(UIAction(title: String(localized: "导出"), image: UIImage(systemName: "square.and.arrow.up")) { _ in
                prepareItemsForExport(Set([item.id]))
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
            actions.append(UIAction(title: String(localized: "管理相册"), image: UIImage(systemName: "rectangle.stack")) { _ in
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
            currentAlbumID: albumID,
            renderToken: viewModel.mediaPresentationRevision,
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
                searchFocused = false
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
            onManageAlbums: { item in
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
            },
            onDragItem: { makeDragItemProvider(for: $0, allowExternalExport: false) },
            onDragActivityChanged: { viewModel.isDraggingVaultItems = $0 }
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
        let prefetchThreshold = max(regularGridColumnCount * 2, 10)
        guard totalItemCount > visibleItemLimit,
              displayedItems.count == visibleItemLimit,
              displayedItems.suffix(prefetchThreshold).contains(where: { $0.id == currentItem.id }) else {
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
    private func topBarToolbar(currentSortOption: AlbumSortOption) -> some ToolbarContent {
        if previewSelection == nil && photoPreviewItemID == nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !isSelecting {
                        Button { enterSelectionMode() } label: {
                            Label(String(localized: "选择"), systemImage: "checkmark.circle")
                        }
                    }
                    if !searchesWholeSpace {
                        if !isSelecting {
                            Menu {
                                Button {
                                    importFlow.beginSystemPhotoImport(
                                        deleteOriginalAfterImport: deleteImportedSystemAssetsAfterImport,
                                        viewModel: viewModel
                                    )
                                } label: {
                                    Label(String(localized: "从相册导入"), systemImage: "photo.on.rectangle")
                                }
                                Button { importFlow.showingFileImporter = true } label: {
                                    Label(String(localized: "从文件导入"), systemImage: "folder")
                                }
                            } label: {
                                Label(String(localized: "导入"), systemImage: "plus")
                            }
                        }
                        Menu {
                            ForEach(availableSortOptions) { option in
                                sortOptionButton(for: option, currentSortOption: currentSortOption)
                            }
                        } label: {
                            Label(String(localized: "排序"), systemImage: "arrow.up.arrow.down")
                        }
                    }
                    Button { searchFocused = false; showingSearchFilters = true } label: {
                        Label(String(localized: "筛选"), systemImage: "line.3.horizontal.decrease")
                    }
                } label: {
                    Label(String(localized: "更多"), systemImage: "ellipsis")
                }
                .labelStyle(.iconOnly)
                .popover(isPresented: $showingSearchFilters) {
                    MediaSearchFiltersView(query: searchQueryBinding)
                        .frame(idealWidth: 380, idealHeight: 540)
                        .presentationCompactAdaptation(.sheet)
                        .presentationDetents([.medium, .large])
                }
            }
            if isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "取消")) { exitSelectionMode() }
                }
            }
        }
    }

    private func selectionActionBar(albumKind: MediaAlbumKind?) -> some View {
        HStack(spacing: 0) {
            if albumKind != .trash {
                selectionActionButton(
                    title: String(localized: "导出"),
                    systemImage: "square.and.arrow.up",
                    role: nil,
                    isDisabled: selectedItemIDs.isEmpty || isPreparingExport
                ) {
                    prepareSelectedItemsForExport()
                }
            }

            if albumKind == .trash {
                selectionActionButton(
                    title: String(localized: "恢复"),
                    systemImage: "arrow.uturn.backward",
                    role: nil,
                    isDisabled: selectedItemIDs.isEmpty
                ) {
                    viewModel.restoreFromTrash(itemIDs: selectedItemIDs)
                    isSelecting = false
                    selectedItemIDs.removeAll()
                }
            } else if albumKind == .archive {
                selectionDivider

                selectionActionButton(
                    title: String(localized: "放回"),
                    systemImage: "arrow.uturn.backward.circle",
                    role: nil,
                    isDisabled: selectedItemIDs.isEmpty
                ) {
                    viewModel.unarchive(itemIDs: selectedItemIDs)
                    isSelecting = false
                    selectedItemIDs.removeAll()
                }
            } else if albumKind?.isSecure != true {
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
                    title: String(localized: "相册", comment: "Short album-management label in the bottom action bar"),
                    systemImage: "rectangle.stack",
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

    private func enterSelectionMode() {
        searchFocused = false
        previewSelection = nil
        photoPreviewItemID = nil
        detailItemID = nil
        pendingOperation = nil
        isSelecting = true
    }

    private func enterSelectionMode(selecting itemID: UUID) {
        searchFocused = false
        previewSelection = nil
        photoPreviewItemID = nil
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
        prepareItemsForExport(selectedItemIDs)
    }

    private func prepareItemsForExport(_ itemIDs: Set<UUID>) {
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

    private var trashAlbumID: UUID {
        viewModel.trashAlbum?.id ?? albumID
    }
}

private struct SecureMediaListView: UIViewControllerRepresentable {
    let items: [VaultItem]
    let currentAlbumID: UUID
    let renderToken: Int
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
    let onManageAlbums: (VaultItem) -> Void
    let onRemoveFromStrongProtection: (VaultItem) -> Void
    let onDeleteItem: (VaultItem) -> Void
    let onPermanentDeleteItem: (VaultItem) -> Void
    let onDragItem: (VaultItem) -> NSItemProvider?
    let onDragActivityChanged: (Bool) -> Void

    func makeUIViewController(context: Context) -> SecureMediaListViewController {
        let controller = SecureMediaListViewController()
        controller.items = items
        controller.currentAlbumID = currentAlbumID
        controller.renderToken = renderToken
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
        controller.onManageAlbums = onManageAlbums
        controller.onRemoveFromStrongProtection = onRemoveFromStrongProtection
        controller.onDeleteItem = onDeleteItem
        controller.onPermanentDeleteItem = onPermanentDeleteItem
        controller.onDragItem = onDragItem
        controller.onDragActivityChanged = onDragActivityChanged
        return controller
    }

    func updateUIViewController(_ controller: SecureMediaListViewController, context: Context) {
        let previousSelectedItemIDs = controller.selectedItemIDs
        let previousIsSelecting = controller.isSelecting
        controller.currentAlbumID = currentAlbumID
        controller.renderToken = renderToken
        controller.albumKind = albumKind
        controller.contentInsetBottom = contentInsetBottom
        controller.footerText = footerText
        controller.onReachEnd = onReachEnd
        controller.onOpenItem = onOpenItem
        controller.onSelectionChanged = onSelectionChanged
        controller.onSelectionModeChanged = onSelectionModeChanged
        controller.onRenameItem = onRenameItem
        controller.onShowDetails = onShowDetails
        controller.onManageAlbums = onManageAlbums
        controller.onRemoveFromStrongProtection = onRemoveFromStrongProtection
        controller.onDeleteItem = onDeleteItem
        controller.onPermanentDeleteItem = onPermanentDeleteItem
        controller.onDragItem = onDragItem
        controller.onDragActivityChanged = onDragActivityChanged
        controller.selectedItemIDs = selectedItemIDs
        controller.isSelecting = isSelecting
        controller.updateItems(items)
        controller.reconfigureSelectionChanges(from: previousSelectedItemIDs, previousIsSelecting: previousIsSelecting)
    }
}

private final class SecureMediaListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    var items: [VaultItem] = []
    var currentAlbumID: UUID?
    var renderToken = 0
    private var lastRenderToken = -1
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
    var onManageAlbums: ((VaultItem) -> Void)?
    var onRemoveFromStrongProtection: ((VaultItem) -> Void)?
    var onDeleteItem: ((VaultItem) -> Void)?
    var onPermanentDeleteItem: ((VaultItem) -> Void)?
    var onDragItem: ((VaultItem) -> NSItemProvider?)?
    var onDragActivityChanged: ((Bool) -> Void)?

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
        let shouldReloadAll = nextIDs != lastRenderedItemIDs || renderToken != lastRenderToken
        lastRenderToken = renderToken
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

        #if targetEnvironment(macCatalyst)
        tableView.dragDelegate = self
        tableView.dragInteractionEnabled = true
        #endif
        let dragSelectGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleDragSelection(_:)))
        dragSelectGesture.minimumPressDuration = 0.35
        dragSelectGesture.cancelsTouchesInView = false
        dragSelectGesture.delaysTouchesBegan = false
        #if targetEnvironment(macCatalyst)
        dragSelectGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        #endif
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

        cell.accessoryView = nil
        if isSelecting {
            cell.accessoryType = selectedItemIDs.contains(item.id) ? .checkmark : .none
            cell.tintColor = .systemBlue
        } else {
            cell.accessoryType = .disclosureIndicator
            let colors = MediaAlbumColorsView()
            colors.configure(item: item, currentAlbumID: currentAlbumID, isSelecting: false)
            if !colors.isHidden {
                // A custom accessoryView replaces accessoryType, so draw the chevron alongside the colors.
                let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
                chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .default)
                    .applying(UIImage.SymbolConfiguration(weight: .semibold))
                chevron.tintColor = .tertiaryLabel
                chevron.contentMode = .center
                let accessory = UIStackView(arrangedSubviews: [colors, chevron])
                accessory.axis = .horizontal
                accessory.alignment = .center
                accessory.spacing = 8
                accessory.isUserInteractionEnabled = false
                accessory.frame.size = accessory.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
                cell.accessoryView = accessory
            }
        }
    }

    private func secureRowSubtitle(for item: VaultItem) -> String {
        if let footer = footerText?(item), !footer.isEmpty {
            return footer
        }
        return item.mediaKind == .video ? item.videoDurationText : ""
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
            actions.append(UIAction(title: String(localized: "管理相册"), image: UIImage(systemName: "lock.rectangle.stack")) { [weak self] _ in
                self?.onManageAlbums?(item)
            })
            actions.append(UIAction(title: String(localized: "移出强加密媒体库"), image: UIImage(systemName: "lock.open"), attributes: .destructive) { [weak self] _ in
                self?.onRemoveFromStrongProtection?(item)
            })
            actions.append(UIAction(title: String(localized: "永久删除"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.onPermanentDeleteItem?(item)
            })
        case .secureCustom:
            actions.append(UIAction(title: String(localized: "管理相册"), image: UIImage(systemName: "lock.rectangle.stack")) { [weak self] _ in
                self?.onManageAlbums?(item)
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
    let currentAlbumID: UUID
    let photoTransitionSource: PhotoPreviewTransitionSource
    let allItems: () -> [VaultItem]
    let onRevealItems: (Int) -> Void
    let selectedItemIDs: Set<UUID>
    let isSelecting: Bool
    let onReachEnd: (VaultItem) -> Void
    let onOpenItem: (UUID) -> Void
    let onSelectionChanged: (Set<UUID>) -> Void
    let onSelectionModeChanged: (Bool) -> Void
    let footerText: ((VaultItem) -> String?)?
    let onContextMenuForItem: ((VaultItem) -> UIMenu?)?
    let onDragItem: ((VaultItem, Bool) -> NSItemProvider?)?
    let onDragActivityChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(columnCount: $columnCount)
    }

    func makeUIViewController(context: Context) -> ZoomableMediaGridViewController {
        #if DEBUG
        MediaPerformanceLog.recordFirstGridMake()
        MediaPerformanceLog.mark("grid.makeUIViewController.input", "items=\(items.count) columns=\(columnCount) selecting=\(isSelecting)")
        #endif
        let controller = ZoomableMediaGridViewController()
        controller.currentAlbumID = currentAlbumID
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
        controller.onDragActivityChanged = onDragActivityChanged
        configureTransitionSource(controller)
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
        controller.currentAlbumID = currentAlbumID
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
        controller.onDragActivityChanged = onDragActivityChanged
        configureTransitionSource(controller)
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

    private func configureTransitionSource(_ controller: ZoomableMediaGridViewController) {
        let allItems = allItems
        let onRevealItems = onRevealItems
        photoTransitionSource.thumbnailView = { [weak controller] itemID, reveal in
            guard let controller else { return nil }
            // The preview can page beyond the grid's first loaded batch. Reveal its
            // destination synchronously so UIKit can find a real return thumbnail.
            if reveal, !controller.items.contains(where: { $0.id == itemID }) {
                let availableItems = allItems()
                guard let index = availableItems.firstIndex(where: { $0.id == itemID }) else { return nil }
                let requiredCount = max(controller.items.count, index + 1)
                onRevealItems(requiredCount)
                controller.items = Array(availableItems.prefix(requiredCount))
                controller.reloadKeepingPositionIfNeeded()
            }
            return controller.thumbnailView(for: itemID, revealIfNeeded: reveal)
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
    var currentAlbumID: UUID?
    var columnCount: Int = 5 {
        didSet {
            guard columnCount != oldValue else { return }
            effectiveColumnCount = CGFloat(columnCount)
            updateLayout(animated: false)
        }
    }
    /// macOS Catalyst drag-out: provides an NSItemProvider for a given vault item.
    /// Set by ZoomableMediaGridView; nil means drag-out is disabled.
    var onDragItem: ((VaultItem, Bool) -> NSItemProvider?)?
    var onDragActivityChanged: ((Bool) -> Void)?
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
    #if targetEnvironment(macCatalyst)
    private weak var marqueePanGesture: UIPanGestureRecognizer?
    private weak var backgroundTapGesture: UITapGestureRecognizer?
    private let marqueeSelectionView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.tintColor.withAlphaComponent(0.14)
        view.layer.borderColor = UIColor.tintColor.cgColor
        view.layer.borderWidth = 1.5
        view.layer.cornerRadius = 4
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }()
    private var isMarqueeSelecting = false
    private var marqueeStartPoint: CGPoint = .zero
    private var marqueeBaselineSelectedIDs = Set<UUID>()
    private var marqueePreviewSelectedIDs: Set<UUID>?
    private var marqueeModifierFlags: UIKeyModifierFlags = []
    private let externalDragHint: UIStackView = {
        let label = UILabel()
        label.text = String(localized: "文件太大，拖出请使用「导出」。")
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center

        let hint = UIStackView(arrangedSubviews: [label])
        hint.isLayoutMarginsRelativeArrangement = true
        hint.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        hint.backgroundColor = .secondarySystemBackground
        hint.layer.cornerRadius = 8
        hint.isUserInteractionEnabled = false
        hint.isHidden = true
        hint.translatesAutoresizingMaskIntoConstraints = false
        return hint
    }()
    private var hideExternalDragHintTask: Task<Void, Never>?
    #endif
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
        view.addSubview(externalDragHint)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            externalDragHint.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 12),
            externalDragHint.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            externalDragHint.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: 12)
        ])
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        #if DEBUG
        let layoutStart = CFAbsoluteTimeGetCurrent()
        #endif
        if collectionView.frame != view.bounds {
            let sizeChanged = collectionView.frame.size != view.bounds.size
            collectionView.frame = view.bounds
            if sizeChanged {
                updateLayout(animated: false)
            }
        }
        #if DEBUG
        MediaPerformanceLog.mark("grid.viewDidLayoutSubviews", "duration=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - layoutStart) * 1000))ms bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height))")
        #endif
        scheduleResumeThumbnailLoadingAfterScrollSettles()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        #if targetEnvironment(macCatalyst)
        updateExternalDragHint(isOversized: false)
        finishMarqueeSelection(commit: false)
        #endif
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
        guard nextItemIDs != lastRenderedItemIDs else {
            if renderToken != lastRenderToken {
                lastRenderToken = renderToken
                let visible = collectionView.indexPathsForVisibleItems.filter { $0.item < items.count }
                collectionView.reconfigureItems(at: visible)
            }
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

    func thumbnailView(for itemID: UUID, revealIfNeeded: Bool) -> UIView? {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        let indexPath = IndexPath(item: index, section: 0)
        if revealIfNeeded, collectionView.cellForItem(at: indexPath) == nil {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
        }
        return (collectionView.cellForItem(at: indexPath) as? MediaGridCell)?.transitionThumbnailView
    }

    func reconfigureSelectionChanges(from previousSelectedItemIDs: Set<UUID>, previousIsSelecting: Bool) {
        let changedIDs: Set<UUID>
        if previousIsSelecting != displaysSelection {
            changedIDs = Set(items.map(\.id))
        } else {
            changedIDs = previousSelectedItemIDs.symmetricDifference(displayedSelectedItemIDs)
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
        #if targetEnvironment(macCatalyst)
        let isSelectingWithAutoScroll = isDragSelecting || isMarqueeSelecting
        #else
        let isSelectingWithAutoScroll = isDragSelecting
        #endif
        guard isSelectingWithAutoScroll, let autoScrollDirection else {
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
            #if targetEnvironment(macCatalyst)
            if isMarqueeSelecting {
                updateMarqueeSelection(to: lastDragLocation)
            } else {
                selectRange(at: lastDragLocation)
            }
            #else
            selectRange(at: lastDragLocation)
            #endif
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
                isSelected: displayedSelectedItemIDs.contains(item.id),
                isSelecting: displaysSelection,
                footerText: footerText?(item),
                currentAlbumID: currentAlbumID
            )
        }

        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        collectionView.addGestureRecognizer(pinchGesture)
        self.pinchGesture = pinchGesture

        let dragSelectGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleDragSelection(_:)))
        dragSelectGesture.minimumPressDuration = 0.3
        dragSelectGesture.cancelsTouchesInView = true
        #if targetEnvironment(macCatalyst)
        dragSelectGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        #endif
        dragSelectGesture.delegate = self
        collectionView.addGestureRecognizer(dragSelectGesture)
        self.dragSelectGesture = dragSelectGesture

        #if targetEnvironment(macCatalyst)
        collectionView.addSubview(marqueeSelectionView)
        let marqueePanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleMarqueeSelection(_:)))
        marqueePanGesture.maximumNumberOfTouches = 1
        marqueePanGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        marqueePanGesture.allowedScrollTypesMask = []
        marqueePanGesture.delegate = self
        collectionView.addGestureRecognizer(marqueePanGesture)
        self.marqueePanGesture = marqueePanGesture

        let backgroundTapGesture = UITapGestureRecognizer(target: self, action: #selector(clearSelectionFromBackgroundTap))
        backgroundTapGesture.allowedTouchTypes = marqueePanGesture.allowedTouchTypes
        backgroundTapGesture.cancelsTouchesInView = false
        backgroundTapGesture.delegate = self
        backgroundTapGesture.require(toFail: marqueePanGesture)
        collectionView.addGestureRecognizer(backgroundTapGesture)
        self.backgroundTapGesture = backgroundTapGesture
        #endif
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
        let prefetchStartIndex = max(0, items.count - max(columnCount * 2, 10))
        guard indexPath.item >= prefetchStartIndex else { return }
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
        #if targetEnvironment(macCatalyst)
        let isSelectingWithAutoScroll = isDragSelecting || isMarqueeSelecting
        #else
        let isSelectingWithAutoScroll = isDragSelecting
        #endif
        guard isSelectingWithAutoScroll else {
            stopNativeAutoScroll()
            return
        }

        // Measure distances from the actual visible content boundaries rather than
        // the raw frame edges. adjustedContentInset accounts for navigation bar
        // top inset and tab-bar / contentInsetBottom at the bottom, so the trigger
        // zone is consistent regardless of the surrounding chrome. The threshold is
        // 160 pt to make edge-scroll reliable in the 3-column /
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
            _ = await MainActor.run {
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
        #if targetEnvironment(macCatalyst)
        if gestureRecognizer === backgroundTapGesture {
            return isSelecting && !isMarqueeSelecting
                && collectionView.indexPathForItem(at: gestureRecognizer.location(in: collectionView)) == nil
        }
        if gestureRecognizer === marqueePanGesture {
            return !isDragSelecting && !isPinchingGrid
        }
        #endif
        if gestureRecognizer === pinchGesture {
            return !isDragSelecting
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === dragSelectGesture || otherGestureRecognizer === dragSelectGesture {
            return false
        }
        #if targetEnvironment(macCatalyst)
        if gestureRecognizer === marqueePanGesture || otherGestureRecognizer === marqueePanGesture {
            return false
        }
        #endif
        if gestureRecognizer === pinchGesture || otherGestureRecognizer === pinchGesture {
            return !isDragSelecting
        }
        return true
    }

    #if targetEnvironment(macCatalyst)
    @objc private func clearSelectionFromBackgroundTap() {
        guard !isMarqueeSelecting else { return }
        applySelection([])
        setSelectionMode(false)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === marqueePanGesture else { return true }
        let startPoint = touch.location(in: collectionView)
        guard collectionView.indexPathForItem(at: startPoint) == nil else { return false }
        marqueeStartPoint = startPoint
        return true
    }

    @objc private func handleMarqueeSelection(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: collectionView)

        switch gesture.state {
        case .began:
            isMarqueeSelecting = true
            marqueeModifierFlags = gesture.modifierFlags
            let keepsExistingSelection = marqueeModifierFlags.contains(.command) || marqueeModifierFlags.contains(.shift)
            marqueeBaselineSelectedIDs = keepsExistingSelection ? selectedItemIDs : []
            marqueeSelectionView.frame = CGRect(origin: location, size: .zero)
            marqueeSelectionView.isHidden = false
            collectionView.bringSubviewToFront(marqueeSelectionView)
            updateMarqueeSelection(to: location)
            updateAutoScroll(for: location)
        case .changed:
            guard isMarqueeSelecting else { return }
            updateMarqueeSelection(to: location)
            updateAutoScroll(for: location)
        case .ended:
            finishMarqueeSelection(commit: true)
        case .cancelled, .failed:
            finishMarqueeSelection(commit: false)
        default:
            break
        }
    }

    private func updateMarqueeSelection(to location: CGPoint) {
        let rect = CGRect(
            x: min(marqueeStartPoint.x, location.x),
            y: min(marqueeStartPoint.y, location.y),
            width: abs(location.x - marqueeStartPoint.x),
            height: abs(location.y - marqueeStartPoint.y)
        )
        marqueeSelectionView.frame = rect

        let hitAttributes = collectionView.collectionViewLayout.layoutAttributesForElements(in: rect) ?? []
        let hitIDs = Set(
            hitAttributes
                .filter { $0.representedElementCategory == .cell }
                .compactMap { items[safe: $0.indexPath.item]?.id }
        )

        let nextSelection: Set<UUID>
        if marqueeModifierFlags.contains(.command) {
            nextSelection = marqueeBaselineSelectedIDs.symmetricDifference(hitIDs)
        } else {
            nextSelection = marqueeBaselineSelectedIDs.union(hitIDs)
        }
        let previousIDs = displayedSelectedItemIDs
        let previousIsSelecting = displaysSelection
        marqueePreviewSelectedIDs = nextSelection
        reconfigureSelectionChanges(from: previousIDs, previousIsSelecting: previousIsSelecting)
    }

    private func finishMarqueeSelection(commit: Bool) {
        guard isMarqueeSelecting else { return }
        let previewIDs = displayedSelectedItemIDs
        marqueePreviewSelectedIDs = nil
        isMarqueeSelecting = false
        lastDragLocation = nil
        stopNativeAutoScroll()
        marqueeSelectionView.isHidden = true
        marqueeSelectionView.frame = .zero
        marqueeBaselineSelectedIDs.removeAll()
        marqueeModifierFlags = []
        if commit {
            applySelection(previewIDs)
            setSelectionMode(!previewIDs.isEmpty)
        }
        reconfigureSelectionChanges(from: previewIDs, previousIsSelecting: true)
    }
    #endif

    private var displayedSelectedItemIDs: Set<UUID> {
        #if targetEnvironment(macCatalyst)
        marqueePreviewSelectedIDs ?? selectedItemIDs
        #else
        selectedItemIDs
        #endif
    }

    private var displaysSelection: Bool {
        #if targetEnvironment(macCatalyst)
        isSelecting || marqueePreviewSelectedIDs != nil
        #else
        isSelecting
        #endif
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
extension SecureMediaListViewController: UITableViewDragDelegate {
    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard let item = items[safe: indexPath.row], let onDragItem else { return [] }
        return mediaDragTargets(startingWith: item, items: items, selecting: isSelecting, selectedItemIDs: selectedItemIDs)
            .compactMap { onDragItem($0).map { UIDragItem(itemProvider: $0) } }
    }

    func tableView(_ tableView: UITableView, dragSessionWillBegin session: UIDragSession) {
        onDragActivityChanged?(true)
    }

    func tableView(_ tableView: UITableView, dragSessionDidEnd session: UIDragSession) {
        onDragActivityChanged?(false)
    }
}

private func mediaDragTargets(
    startingWith item: VaultItem,
    items: [VaultItem],
    selecting: Bool,
    selectedItemIDs: Set<UUID>
) -> [VaultItem] {
    selecting && selectedItemIDs.contains(item.id)
        ? items.filter { selectedItemIDs.contains($0.id) }
        : [item]
}

extension ZoomableMediaGridViewController: UICollectionViewDragDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard let item = items[safe: indexPath.item] else { return [] }
        return makeDragItems(startingWith: item)
    }

    private func makeDragItems(startingWith item: VaultItem) -> [UIDragItem] {
        guard let onDragItem else { return [] }
        let targets = mediaDragTargets(startingWith: item, items: items, selecting: isSelecting, selectedItemIDs: selectedItemIDs)
        // Finder can wait synchronously for the URL. Larger batches use the export sheet.
        var remainingBytes = Int64(10 * 1024 * 1024)
        var isOversized = false
        let allowsExport = targets.allSatisfy { !$0.isInTrash && !$0.isStrongProtected }
        let offersExternalFiles = allowsExport && targets.allSatisfy { item in
            let bytes = VaultFileStorageService.shared.byteCount(for: item.relativePath)
            guard bytes > 0 else { return false }
            guard bytes <= remainingBytes else {
                isOversized = true
                return false
            }
            remainingBytes -= bytes
            return true
        }
        updateExternalDragHint(isOversized: isOversized)
        return targets.compactMap { onDragItem($0, offersExternalFiles).map { UIDragItem(itemProvider: $0) } }
    }

    private func updateExternalDragHint(isOversized: Bool) {
        hideExternalDragHintTask?.cancel()
        externalDragHint.isHidden = !isOversized
        guard isOversized else { return }
        let deadline = ContinuousClock.now + .seconds(4)
        hideExternalDragHintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.externalDragHint.isHidden = true
        }
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionWillBegin session: UIDragSession) {
        onDragActivityChanged?(true)
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
        onDragActivityChanged?(false)
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
    var transitionThumbnailView: UIView { thumbnailImageView }
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

    private let livePhotoBadgeView: UIImageView = {
        let view = UIImageView(image: UIImage(systemName: "livephoto"))
        view.contentMode = .center
        view.tintColor = .white
        view.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.6
        view.layer.shadowRadius = 2
        view.layer.shadowOffset = CGSize(width: 0, height: 1)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let durationLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        label.textAlignment = .center
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        label.layer.cornerRadius = 4
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let albumColorsView = MediaAlbumColorsView()

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

        contentView.addSubview(livePhotoBadgeView)
        contentView.addSubview(durationLabel)
        albumColorsView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(albumColorsView)
        contentView.addSubview(selectionBadgeContainer)
        selectionBadgeContainer.addSubview(selectionCircleView)
        selectionBadgeContainer.addSubview(selectionCheckmarkView)

        footerPillView.addSubview(footerLabel)
        contentView.addSubview(footerPillView)

        NSLayoutConstraint.activate([
            placeholderIconView.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            placeholderIconView.centerYAnchor.constraint(equalTo: placeholderView.centerYAnchor),

            durationLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            durationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            durationLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -4),
            durationLabel.heightAnchor.constraint(equalToConstant: 18),
            albumColorsView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            albumColorsView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

            livePhotoBadgeView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            livePhotoBadgeView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            livePhotoBadgeView.widthAnchor.constraint(equalToConstant: 20),
            livePhotoBadgeView.heightAnchor.constraint(equalToConstant: 20),

            selectionBadgeContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            selectionBadgeContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            selectionBadgeContainer.widthAnchor.constraint(equalToConstant: 24),
            selectionBadgeContainer.heightAnchor.constraint(equalToConstant: 24),

            footerPillView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            footerPillView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -28),

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

    func configure(item: VaultItem, isSelected: Bool, isSelecting: Bool, footerText: String?, currentAlbumID: UUID?) {
        let itemChanged = currentItemID != item.id
        currentItemID = item.id

        if itemChanged {
            cancelPendingRequest()
            thumbnailImageView.image = nil
            placeholderIconView.image = UIImage(systemName: item.mediaKind.symbolName)
            placeholderView.isHidden = false
        }

        livePhotoBadgeView.isHidden = item.mediaKind != .livePhoto
        durationLabel.isHidden = item.mediaKind != .video
        durationLabel.text = " \(item.videoDurationText) "
        albumColorsView.configure(item: item, currentAlbumID: currentAlbumID, isSelecting: isSelecting)

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
        cancelPendingRequest()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
