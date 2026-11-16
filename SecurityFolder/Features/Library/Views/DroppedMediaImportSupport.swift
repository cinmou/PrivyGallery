import Combine
import Foundation
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static let privyVaultItemTransfer = UTType(exportedAs: "com.cinmouice.mediavault.vault-items", conformingTo: .data)
}

nonisolated struct VaultItemDragPayload: Codable, Sendable {
    let space: VaultSpaceKind
    let sourceAlbumID: UUID?
    let itemID: UUID
}

extension MediaLibraryViewModel {
    var vaultDropTypeIdentifiers: [String] {
        isDraggingVaultItems
            ? [UTType.privyVaultItemTransfer.identifier]
            : DroppedMediaImportSupport.sidebarDropTypeIdentifiers
    }
}

enum DroppedMediaImportSupport {
    static let supportedTypeIdentifiers: [String] = [
        UTType.movie.identifier,
        UTType.image.identifier,
        UTType.fileURL.identifier
    ]

    static let sidebarDropTypeIdentifiers: [String] = [
        UTType.privyVaultItemTransfer.identifier
    ] + supportedTypeIdentifiers

    static func hasInternalVaultItems(in providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.privyVaultItemTransfer.identifier) }
    }

    static func beginLoadingVaultItemPayloads(from providers: [NSItemProvider]) -> [AsyncStream<VaultItemDragPayload>] {
        let type = UTType.privyVaultItemTransfer.identifier
        return providers.filter { $0.hasItemConformingToTypeIdentifier(type) }.map { provider in
            AsyncStream { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    if let data, let payload = try? JSONDecoder().decode(VaultItemDragPayload.self, from: data) {
                        continuation.yield(payload)
                    }
                    continuation.finish()
                }
            }
        }
    }

    static func beginLoadingURLs(from providers: [NSItemProvider]) -> [AsyncStream<URL>] {
        providers.compactMap { provider in
            let contentType: UTType?
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                contentType = .fileURL
            } else {
                contentType = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
                    .first { $0.conforms(to: .movie) || $0.conforms(to: .image) }
            }
            guard let contentType else { return nil }
            return AsyncStream { continuation in
                provider.loadItem(forTypeIdentifier: contentType.identifier, options: nil) { item, _ in
                    if let url = stageDroppedItem(item, contentType: contentType) {
                        continuation.yield(url)
                    }
                    continuation.finish()
                }
            }
        }
    }

    private static func stageDroppedItem(_ item: Any?, contentType: UTType) -> URL? {
        let url = (item as? URL) ?? (contentType == .fileURL ? (item as? Data).flatMap {
            URL(dataRepresentation: $0, relativeTo: nil)
        } : nil)
        let fileExtension = contentType.preferredFilenameExtension
        if let url {
            return copyToTemporaryLocation(sourceURL: url, preferredExtension: fileExtension)
        }
        guard contentType != .fileURL, let data = item as? Data else { return nil }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension ?? (contentType.conforms(to: .movie) ? "mov" : "jpg"))
        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    private static func copyToTemporaryLocation(sourceURL: URL, preferredExtension: String?) -> URL? {
        let fileManager = FileManager.default
        let pathExtension = sourceURL.pathExtension.isEmpty ? (preferredExtension ?? "") : sourceURL.pathExtension
        let filename = pathExtension.isEmpty ? UUID().uuidString : UUID().uuidString + "." + pathExtension
        let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(filename)

        var didStartSecurityScope = false
        if sourceURL.startAccessingSecurityScopedResource() {
            didStartSecurityScope = true
        }

        defer {
            if didStartSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            return nil
        }
    }
}

@MainActor
final class MediaImportFlowController: ObservableObject {
    @Published var showingManagedPhotoImporter = false
    @Published var showingFileImporter = false
    @Published var isDropTargeted = false
    @Published fileprivate var importedSystemAssetsDeletionPrompt: ImportedSystemAssetsDeletionPrompt?
    @Published fileprivate var presentedImportResultSummary: MediaImportResultSummary?

    private var pendingImportedSystemAssetIdentifiers: [String] = []
    private var dropOverlayResetToken = UUID()

    func beginSystemPhotoImport(
        deleteOriginalAfterImport: Bool,
        viewModel: MediaLibraryViewModel
    ) {
        guard deleteOriginalAfterImport else {
            showingManagedPhotoImporter = true
            return
        }

        Task {
            let status = await SystemPhotoLibraryCleanupService.shared.ensureReadWriteAuthorization()
            await MainActor.run {
                if status == .authorized || status == .limited {
                    showingManagedPhotoImporter = true
                } else {
                    viewModel.lastErrorMessage = String(localized: "如果你想在导入后删除系统图库原件，请先允许本应用访问\u{201C}照片\u{201D}。")
                }
            }
        }
    }

    func handleDroppedMedia(
        _ providers: [NSItemProvider],
        targetAlbumID: UUID?,
        viewModel: MediaLibraryViewModel
    ) -> Bool {
        isDropTargeted = false
        guard let targetAlbumID, viewModel.canShowRealData, !viewModel.isDraggingVaultItems,
              !DroppedMediaImportSupport.hasInternalVaultItems(in: providers) else {
            return false
        }
        if let albumKind = viewModel.album(for: targetAlbumID)?.kind,
           albumKind == .trash || albumKind == .archive {
            return false
        }
        guard viewModel.canImportAdditionalItems(providers.count) else {
            return false
        }

        // SwiftUI grants access to the providers while the onDrop action is on the stack.
        let requests = DroppedMediaImportSupport.beginLoadingURLs(from: providers)
        guard !requests.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for request in requests {
                for await url in request { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            pendingImportedSystemAssetIdentifiers = []
            viewModel.importFiles(urls, directlyInto: targetAlbumID)
        }

        return true
    }

    #if targetEnvironment(macCatalyst)
    func scheduleDropOverlayResetIfNeeded(_ isTargeted: Bool) {
        guard isTargeted else { return }
        let token = UUID()
        dropOverlayResetToken = token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard dropOverlayResetToken == token else { return }
            isDropTargeted = false
        }
    }
    #endif

    fileprivate func handleFileImportResult(
        _ result: Result<[URL], Error>,
        targetAlbumID: UUID?,
        viewModel: MediaLibraryViewModel
    ) {
        guard case let .success(urls) = result else { return }
        pendingImportedSystemAssetIdentifiers = []
        if let targetAlbumID {
            viewModel.importFiles(urls, directlyInto: targetAlbumID)
        }
    }

    fileprivate func handlePickerAssets(
        _ importedAssets: [ImportedPickerAsset],
        targetAlbumID: UUID?,
        viewModel: MediaLibraryViewModel
    ) {
        showingManagedPhotoImporter = false
        guard !importedAssets.isEmpty else { return }
        pendingImportedSystemAssetIdentifiers = importedAssets.compactMap(\.assetIdentifier)
        if let targetAlbumID {
            viewModel.importPickerAssets(importedAssets, directlyInto: targetAlbumID)
        }
    }

    fileprivate func presentImportResultIfNeeded(
        viewModel: MediaLibraryViewModel,
        canPresent: @escaping () -> Bool
    ) {
        guard canPresent(),
              !viewModel.isImportingMedia,
              viewModel.importResultSummary != nil,
              presentedImportResultSummary == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self,
                  canPresent(),
                  !viewModel.isImportingMedia,
                  let latestSummary = viewModel.importResultSummary,
                  self.presentedImportResultSummary == nil else { return }
            self.presentedImportResultSummary = latestSummary
            viewModel.dismissImportResult()
        }
    }

    fileprivate func scheduleDeletePromptAfterImport(
        importedCount: Int,
        deleteOriginalAfterImport: Bool
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.maybePromptToDeleteImportedSystemAssets(
                afterImportCount: importedCount,
                deleteOriginalAfterImport: deleteOriginalAfterImport
            )
        }
    }

    fileprivate func deleteImportedSystemAssets(
        _ assetIdentifiers: [String],
        viewModel: MediaLibraryViewModel
    ) {
        Task {
            do {
                _ = try await SystemPhotoLibraryCleanupService.shared.deleteAssets(withLocalIdentifiers: assetIdentifiers)
            } catch {
                await MainActor.run {
                    viewModel.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func maybePromptToDeleteImportedSystemAssets(
        afterImportCount importedCount: Int,
        deleteOriginalAfterImport: Bool
    ) {
        defer { pendingImportedSystemAssetIdentifiers = [] }
        guard deleteOriginalAfterImport else { return }
        let assetIdentifiers = Array(Set(pendingImportedSystemAssetIdentifiers.filter { !$0.isEmpty }))
        guard !assetIdentifiers.isEmpty else { return }
        importedSystemAssetsDeletionPrompt = ImportedSystemAssetsDeletionPrompt(
            assetIdentifiers: assetIdentifiers,
            importedCount: importedCount
        )
    }
}

private struct MediaImportFlowModifier: ViewModifier {
    @ObservedObject var controller: MediaImportFlowController
    @ObservedObject var viewModel: MediaLibraryViewModel
    let deleteOriginalAfterImport: Bool
    let targetAlbumID: () -> UUID?
    let canPresentImportResult: () -> Bool

    func body(content: Content) -> some View {
        content
            #if targetEnvironment(macCatalyst)
            .onChange(of: controller.isDropTargeted) { _, isTargeted in
                controller.scheduleDropOverlayResetIfNeeded(isTargeted)
            }
            #endif
            .fileImporter(
                isPresented: $controller.showingFileImporter,
                allowedContentTypes: [.image, .movie],
                allowsMultipleSelection: true
            ) { result in
                controller.handleFileImportResult(
                    result,
                    targetAlbumID: targetAlbumID(),
                    viewModel: viewModel
                )
            }
            .sheet(isPresented: $controller.showingManagedPhotoImporter) {
                SystemPhotoImporterSheet(selectionLimit: MediaLibraryViewModel.maximumBatchImportCount) { importedAssets in
                    controller.handlePickerAssets(
                        importedAssets,
                        targetAlbumID: targetAlbumID(),
                        viewModel: viewModel
                    )
                }
            }
            .onChange(of: viewModel.importResultSummary?.id) { _, _ in
                controller.presentImportResultIfNeeded(
                    viewModel: viewModel,
                    canPresent: canPresentImportResult
                )
            }
            .sheet(item: $controller.presentedImportResultSummary) { summary in
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
                                controller.showingManagedPhotoImporter = false
                                controller.presentedImportResultSummary = nil
                                controller.scheduleDeletePromptAfterImport(
                                    importedCount: summary.photoCount + summary.videoCount,
                                    deleteOriginalAfterImport: deleteOriginalAfterImport
                                )
                            }
                        }
                    }
                    .navigationTitle(String(localized: "导入完成"))
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .sheet(item: $controller.importedSystemAssetsDeletionPrompt) { prompt in
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
                                controller.importedSystemAssetsDeletionPrompt = nil
                                controller.deleteImportedSystemAssets(assetIdentifiers, viewModel: viewModel)
                            }

                            Button(String(localized: "保留原件"), role: .cancel) {
                                controller.importedSystemAssetsDeletionPrompt = nil
                            }
                        }
                    }
                    .navigationTitle(String(localized: "从系统图库删除？"))
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
    }
}

extension View {
    func mediaImportFlow(
        controller: MediaImportFlowController,
        viewModel: MediaLibraryViewModel,
        deleteOriginalAfterImport: Bool,
        targetAlbumID: @escaping () -> UUID?,
        canPresentImportResult: @escaping () -> Bool = { true }
    ) -> some View {
        modifier(
            MediaImportFlowModifier(
                controller: controller,
                viewModel: viewModel,
                deleteOriginalAfterImport: deleteOriginalAfterImport,
                targetAlbumID: targetAlbumID,
                canPresentImportResult: canPresentImportResult
            )
        )
    }
}
