import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DuplicateMediaView: View {
    private struct PreviewSession: Identifiable {
        let id: UUID
        let items: [VaultItem]
    }

    @ObservedObject var library: MediaLibraryViewModel
    @State private var scanID: UUID?
    @AppStorage(AppSettingsKey.duplicateScanIncludesSimilarPhotos) private var includeNearPhotos = false
    @State private var result: DuplicateMediaScan.Result?
    @State private var itemByteCounts: [UUID: Int64] = [:]
    @State private var preview: PreviewSession?
    @State private var selectedIDs: Set<UUID> = []
    @State private var showingTrashConfirmation = false
    @State private var errorMessage: String?
    #if !targetEnvironment(macCatalyst)
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var twoFingerSelection: TwoFingerSelection?
    #endif

    var body: some View {
        let groups = result.map(visibleGroups) ?? []
        let showsActions = scanID == nil && !groups.isEmpty
        let selectableCopies = showsActions ? exactCopiesToSelect() : []
        Group {
        #if targetEnvironment(macCatalyst)
        MacSettingsPageContainer {
            MacSettingsSection(footer: String(localized: "查找当前空间中内容完全相同的普通照片和视频。")) {
                if scanID != nil {
                    HStack(spacing: 12) {
                        Text("正在查找重复项…")
                        Spacer(minLength: 0)
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                        Button("取消", role: .cancel) { scanID = nil }
                            .buttonStyle(.borderless)
                    }
                } else {
                    MacSettingsActionRow(
                        String(localized: "查找重复项"),
                        buttonTitle: result == nil ? String(localized: "开始查重") : String(localized: "重新查重")
                    ) {
                        selectedIDs.removeAll()
                        scanID = UUID()
                    }
                }

                Divider()

                MacSettingsToggleRow(
                    String(localized: "同时查找近似照片"),
                    isOn: $includeNearPhotos,
                    isDisabled: scanID != nil
                )
                .onChange(of: includeNearPhotos) { _, _ in
                    result = nil
                    selectedIDs.removeAll()
                }
            }

            if scanID == nil, let result {
                if groups.isEmpty {
                    ContentUnavailableView(
                        "未找到重复项",
                        systemImage: "photo.on.rectangle.angled"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
                if result.skippedCount > 0 {
                    Text("有 \(result.skippedCount) 个文件无法读取，已跳过。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.id) { group in
                    let canSelectAnother = group.items.filter { !selectedIDs.contains($0.id) }.count > 1
                    MacSettingsSection(group.isApproximate ? String(localized: "疑似副本") : String(localized: "重复项")) {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Divider()
                            }
                            mediaRow(item, canSelectAnother: canSelectAnother, groupItems: group.items)
                        }
                    }
                }
            }
        }
        #else
        List {
            Section {
                Group {
                    if scanID != nil {
                        HStack(spacing: 12) {
                            Text("正在查找重复项…")
                            Spacer(minLength: 0)
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                            Button("取消", role: .cancel) { scanID = nil }
                                .buttonStyle(.borderless)
                        }
                    } else {
                        Button {
                            selectedIDs.removeAll()
                            scanID = UUID()
                        } label: {
                            if result == nil {
                                Text("开始查重")
                            } else {
                                Text("重新查重")
                            }
                        }
                    }
                }
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                Toggle("同时查找近似照片", isOn: $includeNearPhotos)
                    .toggleStyle(.switch)
                    .disabled(scanID != nil)
                    .onChange(of: includeNearPhotos) { _, _ in
                        result = nil
                        selectedIDs.removeAll()
                    }
            } footer: {
                Text("查找当前空间中内容完全相同的普通照片和视频。")
            }

            if scanID == nil, let result {
                if groups.isEmpty {
                    ContentUnavailableView(
                        "未找到重复项",
                        systemImage: "photo.on.rectangle.angled"
                    )
                }
                if result.skippedCount > 0 {
                    Text("有 \(result.skippedCount) 个文件无法读取，已跳过。")
                        .foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.id) { group in
                    let canSelectAnother = group.items.filter { !selectedIDs.contains($0.id) }.count > 1
                    Section {
                        ForEach(group.items) { item in
                            mediaRow(item, canSelectAnother: canSelectAnother, groupItems: group.items)
                                .onGeometryChange(for: CGRect.self) { proxy in
                                    proxy.frame(in: .global)
                                } action: { frame in
                                    rowFrames[item.id] = frame
                                }
                                .onDisappear { rowFrames.removeValue(forKey: item.id) }
                        }
                    } header: {
                        if group.isApproximate {
                            Text("疑似副本")
                        } else {
                            Text("重复项")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .gesture(DuplicateTwoFingerPan(
            isEnabled: showsActions,
            onChange: handleTwoFingerPan
        ))
        #endif
        }
        .navigationTitle("查找重复项")
        .navigationBarTitleDisplayMode(.inline)
        #if !targetEnvironment(macCatalyst)
        .toolbar(showsActions ? .hidden : .automatic, for: .tabBar)
        .toolbar {
            if showsActions {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("全选重复项") { selectedIDs = selectableCopies }
                        .disabled(selectableCopies.isEmpty || selectedIDs == selectableCopies)

                    Spacer()

                    Button(role: .destructive) {
                        showingTrashConfirmation = true
                    } label: {
                        if selectedIDs.isEmpty {
                            Text("删除")
                        } else {
                            Text("删除 (\(selectedIDs.count))")
                        }
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
        #else
        .safeAreaInset(edge: .bottom) {
            if showsActions {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Button("全选重复项") { selectedIDs = selectableCopies }
                            .disabled(selectableCopies.isEmpty || selectedIDs == selectableCopies)

                        Spacer()

                        Button(role: .destructive) {
                            showingTrashConfirmation = true
                        } label: {
                            if selectedIDs.isEmpty {
                                Text("删除")
                            } else {
                                Text("删除 (\(selectedIDs.count))")
                            }
                        }
                        .disabled(selectedIDs.isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
            }
        }
        #endif
        .task(id: scanID) {
            guard let scanID else { return }
            await scan(id: scanID)
        }
        .onDisappear { scanID = nil }
        .onReceive(NotificationCenter.default.publisher(for: .vaultDidLock)) { _ in
            scanID = nil
            result = nil
            itemByteCounts = [:]
            selectedIDs.removeAll()
            preview = nil
            showingTrashConfirmation = false
        }
        .fullScreenCover(item: $preview) { session in
            MediaViewerView(
                items: session.items,
                initialItemID: session.id,
                policy: .regular,
                actions: MediaViewerActions(
                    exportURL: { _ in nil },
                    showDetails: { _ in },
                    detailInfo: { library.details(for: $0.id) }
                ) { _ in EmptyView() },
                selectionIDs: $selectedIDs,
                canSelectItem: { canSelect($0.id) },
                onDismiss: { preview = nil }
            )
        }
        .alert("将 \(selectedIDs.count) 项移到回收站", isPresented: $showingTrashConfirmation) {
            Button("取消", role: .cancel) {}
            Button("移到回收站", role: .destructive, action: moveSelectedToTrash)
        }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var candidates: [VaultItem] {
        library.items.filter {
            $0.space == library.space && !$0.isInTrash && !$0.isArchived && !$0.isStrongProtected
        }
    }

    private func mediaRow(_ item: VaultItem, canSelectAnother: Bool, groupItems: [VaultItem]) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        return HStack(spacing: 8) {
            Button {
                preview = PreviewSession(id: item.id, items: groupItems)
            } label: {
                HStack(spacing: 12) {
                    MediaThumbnailView(item: item)
                        .frame(width: 44, height: 44)
                        .clipShape(.rect(cornerRadius: 6))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .lineLimit(1)
                        Text(rowSubtitle(for: item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                setSelected(!isSelected, itemID: item.id)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!isSelected && !canSelectAnother)
            .accessibilityLabel(isSelected ? Text("取消选择") : Text("选择"))
            .accessibilityValue(Text(item.name))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private func rowSubtitle(for item: VaultItem) -> String {
        let dateText = item.importedAt.formatted(.dateTime.year().month().day())
        let formatText = UTType(item.contentTypeIdentifier)?.preferredFilenameExtension?.uppercased()
            ?? (item.originalFilename as NSString).pathExtension.uppercased()
        let sizeText = itemByteCounts[item.id].flatMap { bytes -> String? in
            bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil
        }
        return [sizeText, formatText.isEmpty ? nil : formatText, dateText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func canSelect(_ itemID: UUID) -> Bool {
        guard let result,
              let group = result.groups.first(where: { $0.ids.contains(itemID) }) else { return false }
        return candidates.contains { $0.id != itemID && group.ids.contains($0.id) && !selectedIDs.contains($0.id) }
    }

    private func setSelected(_ isSelected: Bool, itemID: UUID) {
        if isSelected {
            guard canSelect(itemID) else { return }
            selectedIDs.insert(itemID)
        } else {
            selectedIDs.remove(itemID)
        }
    }

    #if !targetEnvironment(macCatalyst)
    private struct TwoFingerSelection {
        let startID: UUID
        let baseline: Set<UUID>
        let isSelecting: Bool
    }

    private func handleTwoFingerPan(_ state: UIGestureRecognizer.State, location: CGPoint, translation: CGPoint) {
        switch state {
        case .began:
            let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            guard let first = rowID(at: start.y) ?? rowID(at: location.y) else { return }
            twoFingerSelection = TwoFingerSelection(
                startID: first,
                baseline: selectedIDs,
                isSelecting: !selectedIDs.contains(first)
            )
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            updateTwoFingerSelection(at: location)
        case .changed:
            updateTwoFingerSelection(at: location)
        case .ended, .cancelled, .failed:
            twoFingerSelection = nil
        default:
            break
        }
    }

    private func rowID(at y: CGFloat) -> UUID? {
        if let exact = rowFrames.first(where: { y >= $0.value.minY && y <= $0.value.maxY })?.key {
            return exact
        }
        return rowFrames.min { abs($0.value.midY - y) < abs($1.value.midY - y) }?.key
    }

    private func updateTwoFingerSelection(at location: CGPoint) {
        guard let selection = twoFingerSelection,
              let result,
              let endID = rowID(at: location.y) else { return }
        let orderedIDs = visibleGroups(from: result).flatMap { $0.items.map(\.id) }
        guard let startIndex = orderedIDs.firstIndex(of: selection.startID),
              let endIndex = orderedIDs.firstIndex(of: endID) else { return }

        let range = orderedIDs[min(startIndex, endIndex)...max(startIndex, endIndex)]
        if selection.isSelecting {
            selectedIDs = selection.baseline
            for id in range {
                setSelected(true, itemID: id)
            }
        } else {
            selectedIDs = selection.baseline.subtracting(range)
        }
    }
    #endif

    private func visibleGroups(from result: DuplicateMediaScan.Result) -> [(id: UUID, items: [VaultItem], isApproximate: Bool)] {
        let itemsByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        return result.groups.compactMap { group in
            let items = group.ids.compactMap { itemsByID[$0] }
            guard let id = group.ids.first, items.count > 1 else { return nil }
            return (id, items, group.isApproximate)
        }
    }

    private func exactCopiesToSelect() -> Set<UUID> {
        guard let result else { return [] }
        let itemsByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        return Set(result.exactGroups.flatMap { group -> [UUID] in
            let items = group.compactMap { itemsByID[$0] }
            guard let newest = items.max(by: {
                if $0.importedAt != $1.importedAt { return $0.importedAt < $1.importedAt }
                return $0.id.uuidString < $1.id.uuidString
            }) else { return [] }
            return items.lazy.filter { $0.id != newest.id }.map(\.id)
        })
    }

    private func scan(id: UUID) async {
        let snapshots = candidates
            .sorted { $0.importedAt < $1.importedAt }
            .map {
                DuplicateMediaScan.Candidate(
                    id: $0.id,
                    path: $0.relativePath,
                    companionPath: $0.livePhotoCompanionRelativePath,
                    isLivePhoto: $0.mediaKind == .livePhoto,
                    isPhoto: $0.mediaKind == .photo
                )
            }
        let space = library.space
        let includeNearPhotos = includeNearPhotos
        let worker = Task.detached(priority: .utility) {
            let scanned = try DuplicateMediaScan.scan(snapshots, space: space, includeNearPhotos: includeNearPhotos)
            let pathsByID = Dictionary(snapshots.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
            var counts: [UUID: Int64] = [:]
            for group in scanned.groups {
                try Task.checkCancellation()
                for candidateID in group.ids {
                    try Task.checkCancellation()
                    if let path = pathsByID[candidateID] {
                        counts[candidateID] = VaultFileStorageService.shared.byteCount(for: path)
                    }
                }
            }
            return (scanned, counts)
        }
        defer {
            if scanID == id { scanID = nil }
        }
        do {
            let (scanned, counts) = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, scanID == id else { return }
            itemByteCounts = counts
            result = scanned
        } catch {
            guard !Task.isCancelled, scanID == id else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func moveSelectedToTrash() {
        guard let result else { return }
        let removableIDs = Set(visibleGroups(from: result).flatMap { group in
            let ids = group.items.map(\.id)
            return ids.allSatisfy { selectedIDs.contains($0) } ? [] : ids.filter { selectedIDs.contains($0) }
        })
        selectedIDs.removeAll()
        guard !removableIDs.isEmpty else { return }
        library.lastErrorMessage = nil
        library.moveDuplicateItemsToTrash(removableIDs)
        errorMessage = library.lastErrorMessage
    }
}

#if !targetEnvironment(macCatalyst)
private struct DuplicateTwoFingerPan: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onChange: (UIGestureRecognizer.State, CGPoint, CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.minimumNumberOfTouches = 2
        recognizer.maximumNumberOfTouches = 2
        recognizer.allowedScrollTypesMask = []
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        onChange(
            recognizer.state,
            context.converter.location(in: .global),
            context.converter.translation(in: .global) ?? .zero
        )
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let scrollView = otherGestureRecognizer.view as? UIScrollView,
                  otherGestureRecognizer === scrollView.panGestureRecognizer else {
                return false
            }
            return gestureRecognizer.numberOfTouches >= 2 || otherGestureRecognizer.numberOfTouches >= 2
        }
    }
}
#endif
