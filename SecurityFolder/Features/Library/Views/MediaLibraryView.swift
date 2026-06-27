import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import UIKit

struct MediaLibraryView: View {
    @ObservedObject var viewModel: MediaLibraryViewModel
    let adaptiveLayoutMode: AdaptiveLayoutMode
    // 预留给未来在媒体库侧栏底部插入附加内容。
    // 当前顶层已经恢复成系统原生 TabView，所以正常情况下这里会是 nil。
    let sidebarBottomAccessory: AnyView?
    let onOpenSettings: (() -> Void)?
    let embeddedSettingsView: AnyView?
    @AppStorage(AppSettingsKey.advancedDataProtectionEnabled)
    private var advancedDataProtectionEnabled = AppSettingsKey.defaultAdvancedDataProtectionEnabled
    @AppStorage(AppSettingsKey.deleteImportedSystemAssetsAfterImport)
    private var deleteImportedSystemAssetsAfterImport = AppSettingsKey.defaultDeleteImportedSystemAssetsAfterImport

    @State private var newAlbumName = ""
    @State private var showingNewAlbumPrompt = false
    @State private var showingNewSecureAlbumPrompt = false
    @State private var editingAlbumID: UUID?
    @State private var renamingAlbumName = ""
    @State private var showingRenamePrompt = false
    @State private var showingCoverEditor = false
    @State private var showingSymbolPicker = false
    @State private var showingCoverPhotoPicker = false
    @State private var coverPhotoPickerItem: PhotosPickerItem?
    @State private var pendingCoverImage: UIImage?
    @State private var showingCoverCropper = false
    @State private var showingLibraryCustomSort = false
    @State private var selectedAlbumID: UUID?
    @State private var showingManagedPhotoImporter = false
    @State private var pendingImportedSystemAssetIdentifiers: [String] = []
    @State private var importedSystemAssetsDeletionPrompt: ImportedSystemAssetsDeletionPrompt?
    @State private var presentedImportResultSummary: MediaImportResultSummary?
    @State private var showingFileImporter = false
    @State private var isLibraryDropTargeted = false
    @State private var dropOverlayResetToken = UUID()
    @State private var showingEmbeddedSettings = false
    @State private var embeddedSettingsResetToken = UUID()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private let symbolColumns = [
        GridItem(.adaptive(minimum: 64), spacing: 16)
    ]

    init(
        viewModel: MediaLibraryViewModel,
        adaptiveLayoutMode: AdaptiveLayoutMode = .compact,
        sidebarBottomAccessory: AnyView? = nil,
        onOpenSettings: (() -> Void)? = nil,
        embeddedSettingsView: AnyView? = nil
    ) {
        self.viewModel = viewModel
        self.adaptiveLayoutMode = adaptiveLayoutMode
        self.sidebarBottomAccessory = sidebarBottomAccessory
        self.onOpenSettings = onOpenSettings
        self.embeddedSettingsView = embeddedSettingsView
    }

    var body: some View {
        rootContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onChange(of: selectedAlbumID) { _, newAlbumID in
                if newAlbumID != nil {
                    showingEmbeddedSettings = false
                }
            }
            #if targetEnvironment(macCatalyst)
            .onChange(of: isLibraryDropTargeted) { _, isTargeted in
                guard isTargeted else { return }
                scheduleDropOverlayReset()
            }
            #endif
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.image, .movie],
                allowsMultipleSelection: true
            ) { result in
                guard case let .success(urls) = result else { return }
                pendingImportedSystemAssetIdentifiers = []
                if let importAlbumID {
                    viewModel.importFiles(urls, directlyInto: importAlbumID)
                }
        }
            .sheet(isPresented: $showingManagedPhotoImporter) {
                SystemPhotoImporterSheet(selectionLimit: MediaLibraryViewModel.maximumBatchImportCount) { importedAssets in
                    showingManagedPhotoImporter = false
                    guard !importedAssets.isEmpty else { return }
                    pendingImportedSystemAssetIdentifiers = importedAssets.compactMap(\.assetIdentifier)
                    print("[ImportCleanup][LibraryManaged] importedAssets=\(importedAssets.count) assetIDs=\(pendingImportedSystemAssetIdentifiers.count)")
                    if let importAlbumID {
                        viewModel.importPickerAssets(importedAssets, directlyInto: importAlbumID)
                    }
                }
            }
            .alert(String(localized: "新建相册"), isPresented: $showingNewAlbumPrompt) {
                TextField(String(localized: "相册名称"), text: $newAlbumName)
                Button(String(localized: "取消"), role: .cancel) {
                    newAlbumName = ""
                }
                Button(String(localized: "创建")) {
                    viewModel.createAlbum(named: newAlbumName)
                    newAlbumName = ""
                }
            } message: {
                Text(String(localized: "图片和视频都可以同时出现在多个相册中。"))
            }
            .alert(String(localized: "新建强加密相册"), isPresented: $showingNewSecureAlbumPrompt) {
                TextField(String(localized: "相册名称"), text: $newAlbumName)
                Button(String(localized: "取消"), role: .cancel) {
                    newAlbumName = ""
                }
                Button(String(localized: "创建")) {
                    viewModel.createSecureAlbum(named: newAlbumName)
                    newAlbumName = ""
                }
            } message: {
                Text(String(localized: "强加密相册只显示文件名称，只有点击对应项目时才会解密预览。"))
            }
            .alert(String(localized: "重命名相册"), isPresented: $showingRenamePrompt) {
                TextField(String(localized: "相册名称"), text: $renamingAlbumName)
                Button(String(localized: "取消"), role: .cancel) {
                    editingAlbumID = nil
                }
                Button(String(localized: "保存")) {
                    if let editingAlbumID {
                        viewModel.renameAlbum(id: editingAlbumID, to: renamingAlbumName)
                    }
                    editingAlbumID = nil
                }
            }
            .sheet(isPresented: $showingLibraryCustomSort) {
                LibraryCustomSortView(viewModel: viewModel)
            }
            .sheet(isPresented: importProgressSheetBinding) {
                mediaImportProgressSheet
            }
            .sheet(isPresented: $showingCoverEditor, onDismiss: {
                if !showingSymbolPicker && !showingCoverPhotoPicker && !showingCoverCropper {
                    editingAlbumID = nil
                }
            }) {
                NavigationStack {
                    List {
                        Section {
                            if currentEditingAlbumAllowsPrimaryCover {
                                Button {
                                    if let editingAlbumID {
                                        viewModel.assignCover(albumID: editingAlbumID)
                                    }
                                    showingCoverEditor = false
                                    editingAlbumID = nil
                                } label: {
                                    Label(String(localized: "显示首张图片"), systemImage: "photo")
                                }
                            }

                            Button {
                                showingCoverEditor = false
                                showingCoverPhotoPicker = true
                            } label: {
                                Label(String(localized: "从系统图库导入"), systemImage: "photo.on.rectangle")
                            }

                            Button {
                                showingCoverEditor = false
                                showingSymbolPicker = true
                            } label: {
                                Label(String(localized: "选择符号"), systemImage: "sparkles")
                            }

                            Button {
                                if let editingAlbumID {
                                    viewModel.clearCover(albumID: editingAlbumID)
                                }
                                showingCoverEditor = false
                                editingAlbumID = nil
                            } label: {
                                Label(String(localized: "不显示封面"), systemImage: "rectangle.slash")
                            }
                        }
                    }
                    .navigationTitle(String(localized: "编辑封面"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showingCoverEditor = false
                            } label: {
                                Image(systemName: "xmark")
                                    .fontWeight(.medium)
                            }
                            .accessibilityLabel(String(localized: "关闭"))
                        }
                    }
                }
                .presentationDetents([.medium])
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
                                print("[ImportCleanup][Library] import result dismissed photoCount=\(summary.photoCount) videoCount=\(summary.videoCount) pendingIDs=\(pendingImportedSystemAssetIdentifiers.count) enabled=\(deleteImportedSystemAssetsAfterImport)")
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
            .sheet(isPresented: $showingSymbolPicker, onDismiss: {
                editingAlbumID = nil
            }) {
                NavigationStack {
                    ScrollView {
                        LazyVGrid(columns: symbolColumns, spacing: 16) {
                            ForEach(viewModel.coverSymbols, id: \.self) { symbolName in
                                Button {
                                    if let editingAlbumID {
                                        viewModel.setCoverSymbol(symbolName, for: editingAlbumID)
                                    }
                                    editingAlbumID = nil
                                    showingSymbolPicker = false
                                } label: {
                                    Image(systemName: symbolName)
                                        .font(.title2)
                                        .frame(width: 54, height: 54)
                                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.primary)
                            }
                        }
                        .padding()
                    }
                    .navigationTitle(String(localized: "选择符号"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showingSymbolPicker = false
                            } label: {
                                Image(systemName: "xmark")
                                    .fontWeight(.medium)
                            }
                            .accessibilityLabel(String(localized: "取消"))
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .photosPicker(
                isPresented: $showingCoverPhotoPicker,
                selection: $coverPhotoPickerItem,
                matching: .images
            )
            .onChange(of: coverPhotoPickerItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    guard let data = try? await newItem.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    await MainActor.run {
                        pendingCoverImage = image
                        showingCoverCropper = true
                        coverPhotoPickerItem = nil
                    }
                }
            }
            .sheet(isPresented: $showingCoverCropper, onDismiss: {
                pendingCoverImage = nil
                if !showingCoverEditor && !showingSymbolPicker && !showingCoverPhotoPicker {
                    editingAlbumID = nil
                }
            }) {
                if let pendingCoverImage {
                    CoverImageCropView(
                        image: pendingCoverImage,
                        onCancel: {
                            showingCoverCropper = false
                        },
                        onConfirm: { croppedImage in
                            if let editingAlbumID {
                                viewModel.setImportedCoverImage(croppedImage, for: editingAlbumID)
                            }
                            showingCoverCropper = false
                            editingAlbumID = nil
                        }
                    )
                }
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if usesSplitLayout {
            // iPad 大屏下，媒体库自己切成左右双栏：
            // - 左边显示相册侧栏
            // - 右边显示选中的二级相册内容
            //
            // 如果大屏模式下改成"设置按钮打开右侧详情"，
            // 也只在这里切换 detail，不去干扰左侧相册结构。
            NavigationSplitView(columnVisibility: $columnVisibility) {
                librarySidebar
                    // On macOS the import/sort actions and a sidebar toggle live in the
                    // window title bar next to the traffic lights. On iPad, keep the nav bar.
                    #if targetEnvironment(macCatalyst)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        macSidebarToolbar
                    }
                    #else
                    .navigationTitle(String(localized: "媒体库"))
                    .toolbar {
                        libraryToolbarContent
                    }
                    #endif
                    .navigationSplitViewColumnWidth(min: 220, ideal: 285, max: 340)
            } detail: {
                libraryDetailContent
            }
        } else {
            NavigationStack {
                libraryListContent
                    .navigationTitle(String(localized: "媒体库"))
                    .toolbar {
                        libraryToolbarContent
                    }
                    .navigationDestination(item: $selectedAlbumID) { albumID in
                        AlbumDetailView(viewModel: viewModel, albumID: albumID)
                    }
            }
        }
    }

    @ViewBuilder
    private var librarySidebar: some View {
        if viewModel.canShowRealData {
            VStack(alignment: .leading, spacing: 0) {
                // 侧栏本体保持原生 plain list，只在行内做轻量选中态。
                librarySidebarList
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .onDrop(of: DroppedMediaImportSupport.supportedTypeIdentifiers, isTargeted: $isLibraryDropTargeted) { providers in
                        handleDroppedMedia(providers, targetAlbumID: importAlbumID)
                    }
            }
            // Keep the overlay always present and drive it with opacity. Inserting/
            // removing it with `if` during a drag disrupts SwiftUI's drag tracking
            // on Catalyst, so `isTargeted` would get stuck true (the "Drop to import"
            // overlay wouldn't disappear when the drag ended off-window).
            .overlay {
                DropImportOverlayView()
                    .opacity(isLibraryDropTargeted ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isLibraryDropTargeted)
            }
            .background(Color.clear)
        } else {
            libraryUnavailablePlaceholder
        }
    }

    #if targetEnvironment(macCatalyst)
    // Import / sort actions, hoisted into the window title bar next to the
    // traffic lights. The sidebar show/hide toggle is added automatically by
    // NavigationSplitView, so we don't add our own (that produced a duplicate).
    @ToolbarContentBuilder
    private var macSidebarToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Menu {
                libraryImportMenuItems
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .disabled(!viewModel.canShowRealData)

            Menu {
                librarySortMenuItems
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .accessibilityLabel(String(localized: "排序"))
            .disabled(!viewModel.canShowRealData)
        }
    }
    #endif

    private var sidebarRowInsets: EdgeInsets {
        #if targetEnvironment(macCatalyst)
        EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6)
        #else
        EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        #endif
    }

    private var sidebarSelectionCornerRadius: CGFloat {
        #if targetEnvironment(macCatalyst)
        7
        #else
        14
        #endif
    }

    private var secondarySidebarSelectionCornerRadius: CGFloat {
        #if targetEnvironment(macCatalyst)
        7
        #else
        26
        #endif
    }

    private var sidebarAlbumVerticalPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        3
        #else
        8
        #endif
    }

    private var sidebarSecondaryVerticalPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        5
        #else
        10
        #endif
    }

    private var platformLibraryBackground: Color {
        #if targetEnvironment(macCatalyst)
        Color(uiColor: .systemBackground)
        #else
        Color.clear
        #endif
    }

    private var librarySidebarList: some View {
        List {
            Section {
                // 这里是"全部照片 / 全部视频 / 强加密媒体库 / 自定义相册"的主列表。
                // 如果你后面想改侧栏相册排序或插入新的系统相册，优先从这个 Section 下手。
                ForEach(viewModel.mediaAlbums) { album in
                    sidebarAlbumRow(album)
                }
            } 

            Section {
                // 这里单独放归档 / 回收站，和上面的主相册刻意分成第二组。
                if let archiveAlbum = viewModel.archiveAlbum {
                    Button {
                        showAlbumDetail(archiveAlbum.id)
                    } label: {
                        sidebarSecondaryAlbumRow(
                            archiveAlbum,
                            isSelected: selectedAlbumID == archiveAlbum.id
                        )
	                    }
	                    .listRowSeparator(.hidden)
	                    .listRowBackground(Color.clear)
	                    .listRowInsets(sidebarRowInsets)
	                    .buttonStyle(.plain)
                }

                if let trashAlbum = viewModel.trashAlbum {
                    Button {
                        showAlbumDetail(trashAlbum.id)
                    } label: {
                        sidebarSecondaryAlbumRow(
                            trashAlbum,
                            isSelected: selectedAlbumID == trashAlbum.id
                        )
	                    }
	                    .listRowSeparator(.hidden)
	                    .listRowBackground(Color.clear)
	                    .listRowInsets(sidebarRowInsets)
	                    .buttonStyle(.plain)
                }
            } header: {
                sidebarSectionSpacer
            }

            if usesSplitLayout, embeddedSettingsView != nil || onOpenSettings != nil {
                Section {
                    Button {
                        if let onOpenSettings {
                            onOpenSettings()
                        } else {
                            showingEmbeddedSettings = true
                            embeddedSettingsResetToken = UUID()
                            selectedAlbumID = nil
                        }
                    } label: {
                        HStack {
                            Image(systemName: "gear")
                                .foregroundStyle(showingEmbeddedSettings ? Color.accentColor : .primary)
                                .frame(width: 22)

                            Text(String(localized: "设置"))
                                .foregroundStyle(showingEmbeddedSettings ? Color.accentColor : .primary)
                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(showingEmbeddedSettings ? Color.accentColor : Color.secondary.opacity(0.6))
                        }
                        .padding(.horizontal, 12)
	                        .padding(.vertical, sidebarSecondaryVerticalPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
	                        .modifier(SimpleSidebarSelectionModifier(isSelected: showingEmbeddedSettings, cornerRadius: secondarySidebarSelectionCornerRadius))
	                        .contentShape(RoundedRectangle(cornerRadius: secondarySidebarSelectionCornerRadius, style: .continuous))
                    }
                    .tint(.primary)
	                    .buttonStyle(.plain)
	                    .listRowSeparator(.hidden)
	                    .listRowBackground(Color.clear)
	                    .listRowInsets(sidebarRowInsets)
                } header: {
                    Color.clear
                        .frame(height: 22)
                        .listRowInsets(.init())
                }
            }

            if let sidebarBottomAccessory {
                Section {
                    sidebarBottomAccessory
                } header: {
                    sidebarSectionSpacer
                }
            }
        }
    }

    private var sidebarSectionSpacer: some View {
        // 去掉 Section 标题后，继续保留系统分组间距。
        Color.clear
            .frame(height: 10)
            .listRowInsets(.init())
    }

    @ViewBuilder
    private var libraryListContent: some View {
        if viewModel.canShowRealData {
            libraryAlbumList
                .listStyle(.insetGrouped)
                .background(platformLibraryBackground.ignoresSafeArea())
                .onDrop(of: DroppedMediaImportSupport.supportedTypeIdentifiers, isTargeted: $isLibraryDropTargeted) { providers in
                    handleDroppedMedia(providers, targetAlbumID: importAlbumID)
                }
                .overlay {
                    DropImportOverlayView()
                        .opacity(isLibraryDropTargeted ? 1 : 0)
                        .animation(.easeInOut(duration: 0.15), value: isLibraryDropTargeted)
                }
        } else {
            libraryUnavailablePlaceholder
        }
    }

    private var libraryAlbumList: some View {
        List {
            Section(String(localized: "相册")) {
                ForEach(viewModel.mediaAlbums) { album in
                    albumButton(album)
                }
            }

            Section(String(localized: "其他相册")) {
                if let archiveAlbum = viewModel.archiveAlbum {
                    Button {
                        showAlbumDetail(archiveAlbum.id)
                    } label: {
                        secondaryAlbumRow(archiveAlbum)
                    }
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                }

                if let trashAlbum = viewModel.trashAlbum {
                    Button {
                        showAlbumDetail(trashAlbum.id)
                    } label: {
                        secondaryAlbumRow(trashAlbum)
                    }
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu { libraryImportMenuItems } label: { Image(systemName: "plus") }
                .disabled(!viewModel.canShowRealData)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu { librarySortMenuItems } label: { Image(systemName: "line.3.horizontal.decrease") }
                .accessibilityLabel(String(localized: "排序"))
                .disabled(!viewModel.canShowRealData)
        }
    }

    @ViewBuilder
    private var libraryImportMenuItems: some View {
        Section(String(localized: "新建")) {
            Button {
                newAlbumName = String(localized: "新建相册")
                showingNewAlbumPrompt = true
            } label: {
                Label(String(localized: "新建相册"), systemImage: "plus.square.on.square")
            }
            if advancedDataProtectionEnabled {
                Button {
                    newAlbumName = String(localized: "新建强加密相册")
                    showingNewSecureAlbumPrompt = true
                } label: {
                    Label(String(localized: "新建强加密相册"), systemImage: "lock.square.stack")
                }
            }
        }
        Section(String(localized: "导入")) {
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
        }
    }

    @ViewBuilder
    private var librarySortMenuItems: some View {
        Section(String(localized: "排序")) {
            ForEach(LibraryAlbumSortOption.allCases) { option in
                Button {
                    if option == .custom {
                        viewModel.setLibrarySortOption(option)
                        showingLibraryCustomSort = true
                    } else {
                        viewModel.setLibrarySortOption(option)
                    }
                } label: {
                    librarySortLabel(for: option)
                }
            }
        }
    }

    @ViewBuilder
    private var libraryDetailContent: some View {
        if showingEmbeddedSettings, let embeddedSettingsView {
            embeddedSettingsView
                .id(embeddedSettingsResetToken)
        } else if let selectedAlbumID {
            NavigationStack {
                AlbumDetailView(viewModel: viewModel, albumID: selectedAlbumID)
            }
            .id(selectedAlbumID)
        } else {
            SplitPlaceholderView(
                title: String(localized: "资源库"),
                systemImage: "photo.on.rectangle.angled",
                message: String(localized: "在左侧选择一个相册后，这里会显示对应内容。")
            )
            .id("library-empty-detail")
        }
    }

    private var libraryUnavailablePlaceholder: some View {
        EmptyStateCard(
            title: String.localizedStringWithFormat(
                String(localized: "%@暂无内容"),
                viewModel.space.title
            ),
            message: String(localized: "这个空间保留相同入口，但不会显示真实媒体，也不会保存导入数据。"),
            systemImage: "photo.on.rectangle.angled"
        )
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var currentEditingAlbumAllowsPrimaryCover: Bool {
        guard let editingAlbumID, let album = viewModel.album(for: editingAlbumID) else { return false }
        return album.kind != .secureLibrary
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

    private func albumButton(_ album: AlbumCellModel) -> some View {
        Button {
            showAlbumDetail(album.id)
        } label: {
            AlbumCellView(album: album)
        }
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .contextMenu {
            albumContextMenu(for: album)
        } preview: {
            AlbumCellView(album: album, accentSelection: selectedAlbumID == album.id)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    Color.white,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if album.allowsDeletion {
                Button(role: .destructive) {
                    print("[MediaLibraryUI] swipe delete tapped for album=\(album.title) id=\(album.id.uuidString)")
                    viewModel.deleteAlbum(id: album.id)
                } label: {
                    Label(String(localized: "删除"), systemImage: "trash")
                }
            }
        }
        .onDrop(of: DroppedMediaImportSupport.supportedTypeIdentifiers, isTargeted: nil) { providers in
            handleDroppedMedia(providers, targetAlbumID: album.id)
        }
    }

    private func sidebarAlbumRow(_ album: AlbumCellModel) -> some View {
        Button {
            showAlbumDetail(album.id)
        } label: {
            // 大屏侧栏相册选中态统一在 SimpleSidebarSelectionModifier 里调。
            // 现在只保留一个尽量简单的灰色胶囊背景，不再使用复杂的自定义玻璃效果。
            AlbumCellView(album: album, accentSelection: selectedAlbumID == album.id)
                .padding(.horizontal, 10)
                .padding(.vertical, sidebarAlbumVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(SimpleSidebarSelectionModifier(isSelected: selectedAlbumID == album.id, cornerRadius: sidebarSelectionCornerRadius))
                .contentShape(RoundedRectangle(cornerRadius: sidebarSelectionCornerRadius, style: .continuous))
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(sidebarRowInsets)
        .buttonStyle(.plain)
        .contextMenu {
            albumContextMenu(for: album)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if album.allowsDeletion {
                Button(role: .destructive) {
                    print("[MediaLibraryUI] swipe delete tapped for album=\(album.title) id=\(album.id.uuidString)")
                    viewModel.deleteAlbum(id: album.id)
                } label: {
                    Label(String(localized: "删除"), systemImage: "trash")
                }
            }
        }
        .onDrop(of: DroppedMediaImportSupport.supportedTypeIdentifiers, isTargeted: nil) { providers in
            handleDroppedMedia(providers, targetAlbumID: album.id)
        }
    }

    private func secondaryAlbumRow(_ album: AlbumCellModel) -> some View {
        HStack {
            Image(systemName: album.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            Text(album.title)
                .foregroundStyle(.primary)

            Spacer()

            Text(album.subtitle)
                .foregroundStyle(.secondary)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func sidebarSecondaryAlbumRow(_ album: AlbumCellModel, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: sidebarSystemImage(for: album))
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .frame(width: 22)

            Text(album.title)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)

            Spacer()

            Text(album.subtitle)
                .font(.footnote)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 12)
        .padding(.vertical, sidebarSecondaryVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SimpleSidebarSelectionModifier(isSelected: isSelected, cornerRadius: secondarySidebarSelectionCornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: secondarySidebarSelectionCornerRadius, style: .continuous))
    }

    private func sidebarSystemImage(for album: AlbumCellModel) -> String {
        switch album.systemImage {
        case "archivebox":
            return "archivebox"
        case "trash":
            return "trash"
        default:
            return album.systemImage
        }
    }

    @ViewBuilder
    private func albumContextMenu(for album: AlbumCellModel) -> some View {
        Button(String(localized: "编辑封面")) {
            editingAlbumID = album.id
            showingCoverEditor = true
        }
        .disabled(album.usesRowStyle)

        if album.allowsDeletion {
            Button(String(localized: "重命名")) {
                editingAlbumID = album.id
                renamingAlbumName = album.title
                showingRenamePrompt = true
            }

            Button(String(localized: "复制")) {
                viewModel.duplicateAlbum(id: album.id)
            }

            Button(String(localized: "删除相册"), role: .destructive) {
                print("[MediaLibraryUI] context delete tapped for album=\(album.title) id=\(album.id.uuidString)")
                viewModel.deleteAlbum(id: album.id)
            }
        }
    }

    private func showAlbumDetail(_ albumID: UUID) {
        // 大屏模式下如果右侧正停在设置的二级界面，
        // 先通知设置页回到根级，再在下一拍切回相册详情，
        // 避免右侧残留上一次的设置导航栈。
        if showingEmbeddedSettings {
            NotificationCenter.default.post(name: .settingsShouldResetToRoot, object: nil)
            embeddedSettingsResetToken = UUID()
            DispatchQueue.main.async {
                showingEmbeddedSettings = false
                selectedAlbumID = albumID
            }
        } else {
            showingEmbeddedSettings = false
            selectedAlbumID = albumID
        }
    }

    private func beginSystemPhotoImport() {
        guard deleteImportedSystemAssetsAfterImport else {
            print("[ImportCleanup][Library] begin managed import without cleanup requirement")
            showingManagedPhotoImporter = true
            return
        }

        Task {
            let status = await SystemPhotoLibraryCleanupService.shared.ensureReadWriteAuthorization()
            await MainActor.run {
                print("[ImportCleanup][Library] readWrite authorization status=\(status.rawValue)")
                if status == .authorized || status == .limited {
                    showingManagedPhotoImporter = true
                } else {
                    viewModel.lastErrorMessage = String(localized: "如果你想在导入后删除系统图库原件，请先允许本应用访问\u{201C}照片\u{201D}。")
                }
            }
        }
    }

    private func maybePromptToDeleteImportedSystemAssets(afterImportCount importedCount: Int) {
        defer { pendingImportedSystemAssetIdentifiers = [] }
        guard deleteImportedSystemAssetsAfterImport else {
            print("[ImportCleanup][Library] prompt skipped because feature disabled")
            return
        }
        let assetIdentifiers = Array(Set(pendingImportedSystemAssetIdentifiers.filter { !$0.isEmpty }))
        guard !assetIdentifiers.isEmpty else {
            print("[ImportCleanup][Library] prompt skipped because no asset identifiers were captured")
            return
        }
        print("[ImportCleanup][Library] showing delete prompt importedCount=\(importedCount) uniqueAssetIDs=\(assetIdentifiers.count)")
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
        guard selectedAlbumID == nil, !showingEmbeddedSettings else {
            print("[ImportCleanup][Library] skipping import result prompt because a detail screen is active")
            return
        }
        guard !viewModel.isImportingMedia,
              let summary = viewModel.importResultSummary,
              presentedImportResultSummary == nil else { return }
        print("[ImportCleanup][Library] scheduling import result prompt photoCount=\(summary.photoCount) videoCount=\(summary.videoCount)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard selectedAlbumID == nil, !showingEmbeddedSettings else {
                print("[ImportCleanup][Library] cancelled delayed import result prompt because a detail screen became active")
                return
            }
            guard !viewModel.isImportingMedia,
                  let latestSummary = viewModel.importResultSummary,
                  presentedImportResultSummary == nil else { return }
            print("[ImportCleanup][Library] presenting import result prompt")
            presentedImportResultSummary = latestSummary
            viewModel.dismissImportResult()
        }
    }

    private func deleteImportedSystemAssets(_ assetIdentifiers: [String]) {
        Task {
            do {
                print("[ImportCleanup][Library] delete confirmed assetIDs=\(assetIdentifiers.count)")
                _ = try await SystemPhotoLibraryCleanupService.shared.deleteAssets(withLocalIdentifiers: assetIdentifiers)
                print("[ImportCleanup][Library] delete finished successfully")
            } catch {
                await MainActor.run {
                    print("[ImportCleanup][Library] delete failed error=\(error.localizedDescription)")
                    viewModel.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleDroppedMedia(_ providers: [NSItemProvider], targetAlbumID: UUID?) -> Bool {
        isLibraryDropTargeted = false
        guard let targetAlbumID, viewModel.canShowRealData else {
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
                viewModel.importFiles(urls, directlyInto: targetAlbumID)
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
            isLibraryDropTargeted = false
        }
    }
    #endif

    private var importAlbumID: UUID? {
        viewModel.mediaAlbums.first?.id ?? viewModel.trashAlbum?.id ?? viewModel.archiveAlbum?.id
    }

    private var usesSplitLayout: Bool {
        // 媒体库自己的大屏判定：
        // 只使用根容器解析出的 size-class 模式，避免局部 sheet/键盘影响根布局。
        adaptiveLayoutMode.usesWideLayout
    }

    @ViewBuilder
    private func librarySortLabel(for option: LibraryAlbumSortOption) -> some View {
        if viewModel.librarySortOption == option {
            Label(option.title, systemImage: "checkmark")
        } else {
            Text(option.title)
        }
    }
}

private struct SimpleSidebarSelectionModifier: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(selectionFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(selectionStroke, lineWidth: 1)
            )
    }

    private var selectionFill: Color {
        guard isSelected else { return .clear }
        #if targetEnvironment(macCatalyst)
        return Color.accentColor.opacity(0.16)
        #else
        return Color(.systemGray5)
        #endif
    }

    private var selectionStroke: Color {
        #if targetEnvironment(macCatalyst)
        return .clear
        #else
        return isSelected ? Color(.systemGray5) : .clear
        #endif
    }
}

private struct CoverImageCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onConfirm: (UIImage) -> Void

    @State private var offset: CGSize = .zero
    @State private var accumulatedOffset: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var accumulatedScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let squareSize = min(proxy.size.width - 32, proxy.size.height - 140)

                ZStack {
                    Color.black.ignoresSafeArea()

                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .ignoresSafeArea()

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(dragGesture.simultaneously(with: magnificationGesture))

                    Rectangle()
                        .stroke(.white, lineWidth: 2)
                        .frame(width: squareSize, height: squareSize)
                        .allowsHitTesting(false)
                }
                .compositingGroup()
                .overlay(alignment: .bottom) {
                    Text(String(localized: "拖动和缩放图片，裁剪为正方形封面"))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.bottom, 24)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "取消"), action: onCancel)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "使用")) {
                            onConfirm(renderCroppedImage(squareSize: squareSize))
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "裁剪封面"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: accumulatedOffset.width + value.translation.width,
                    height: accumulatedOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                accumulatedOffset = offset
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = max(1, accumulatedScale * value)
            }
            .onEnded { _ in
                accumulatedScale = scale
            }
    }

    private func renderCroppedImage(squareSize: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: squareSize, height: squareSize), format: format)

        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: squareSize, height: squareSize)))

            let baseSize = fittedSize(for: image.size, in: CGSize(width: squareSize, height: squareSize))
            let drawSize = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
            let drawOrigin = CGPoint(
                x: (squareSize - drawSize.width) / 2 + offset.width,
                y: (squareSize - drawSize.height) / 2 + offset.height
            )

            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }
    }

    private func fittedSize(for imageSize: CGSize, in bounds: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let widthScale = bounds.width / imageSize.width
        let heightScale = bounds.height / imageSize.height
        let fitScale = max(widthScale, heightScale)
        return CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)
    }
}

#Preview {
    NavigationStack {
        MediaLibraryView(viewModel: PreviewSupport.mediaLibraryViewModel())
    }
}
