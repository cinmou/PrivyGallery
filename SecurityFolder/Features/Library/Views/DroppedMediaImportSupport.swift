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

    static let stagingDirectoryName = "DroppedMediaImport"

    private static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(stagingDirectoryName, isDirectory: true)
    }

    static func cleanupTemporaryFiles(_ urls: [URL]) {
        let fileManager = FileManager.default
        let stagingRoot = stagingDirectory.standardizedFileURL.path(percentEncoded: false)
        let rootPrefix = stagingRoot.hasSuffix("/") ? stagingRoot : stagingRoot + "/"
        for url in urls {
            let standardized = url.standardizedFileURL
            guard standardized.path(percentEncoded: false).hasPrefix(rootPrefix) else { continue }
            try? fileManager.removeItem(at: standardized)
        }
    }

    static func cleanupAllTemporaryDirectories() {
        let fileManager = FileManager.default
        let dir = stagingDirectory
        if fileManager.fileExists(atPath: dir.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: dir)
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
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let destination = stagingDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension ?? (contentType.conforms(to: .movie) ? "mov" : "jpg"))
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
            return destination
        } catch {
            return nil
        }
    }

    private static func copyToTemporaryLocation(sourceURL: URL, preferredExtension: String?) -> URL? {
        let fileManager = FileManager.default
        let pathExtension = sourceURL.pathExtension.isEmpty ? (preferredExtension ?? "") : sourceURL.pathExtension
        let filename = pathExtension.isEmpty ? UUID().uuidString : UUID().uuidString + "." + pathExtension
        let destinationURL = stagingDirectory.appendingPathComponent(filename)

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
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destinationURL.path(percentEncoded: false))
            return destinationURL
        } catch {
            return nil
        }
    }
}

fileprivate struct PresentedImportResult: Identifiable {
    var id: UUID { summary.id }
    let summary: MediaImportResultSummary
    let importedSystemAssetIdentifiers: [String]
}

@MainActor
final class MediaImportFlowController: ObservableObject {
    @Published var showingManagedPhotoImporter = false
    @Published var showingFileImporter = false
    @Published var isDropTargeted = false
    @Published fileprivate var importedSystemAssetsDeletionPrompt: ImportedSystemAssetsDeletionPrompt?
    @Published fileprivate var presentedImportResult: PresentedImportResult?

    private var activeDropLoadTask: Task<Void, Never>?
    private var dropOverlayResetToken = UUID()
    private var lockGeneration = 0

    func handleVaultDidLock() {
        lockGeneration &+= 1
        activeDropLoadTask?.cancel()
        activeDropLoadTask = nil
        showingManagedPhotoImporter = false
        showingFileImporter = false
        isDropTargeted = false
        presentedImportResult = nil
        importedSystemAssetsDeletionPrompt = nil
        DroppedMediaImportSupport.cleanupAllTemporaryDirectories()
        SystemPhotoImporterSheet.cleanupAllTemporaryDirectories()
    }

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
        activeDropLoadTask?.cancel()
        activeDropLoadTask = Task { [weak self] in
            var urls: [URL] = []
            for request in requests {
                for await url in request {
                    urls.append(url)
                }
            }
            guard !Task.isCancelled else {
                DroppedMediaImportSupport.cleanupTemporaryFiles(urls)
                return
            }
            self?.activeDropLoadTask = nil
            guard !urls.isEmpty else { return }
            viewModel.importFiles(urls, directlyInto: targetAlbumID, deleteSourceFilesAfterImport: true)
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
        guard let targetAlbumID else {
            SystemPhotoImporterSheet.cleanupTemporaryFiles(for: importedAssets)
            return
        }
        viewModel.importPickerAssets(importedAssets, directlyInto: targetAlbumID)
    }

    fileprivate func presentImportResultIfNeeded(
        viewModel: MediaLibraryViewModel,
        canPresent: @escaping () -> Bool
    ) {
        guard canPresent(),
              !viewModel.isImportingMedia,
              viewModel.importResultSummary != nil,
              presentedImportResult == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self,
                  canPresent(),
                  !viewModel.isImportingMedia,
                  let latestSummary = viewModel.importResultSummary,
                  self.presentedImportResult == nil else { return }
            let assetIdentifiers = viewModel.consumeImportedSystemAssetIdentifiers(for: latestSummary.id)
            self.presentedImportResult = PresentedImportResult(
                summary: latestSummary,
                importedSystemAssetIdentifiers: assetIdentifiers
            )
            viewModel.dismissImportResult()
        }
    }

    fileprivate func scheduleDeletePromptAfterImport(
        assetIdentifiers: [String],
        deleteOriginalAfterImport: Bool
    ) {
        guard deleteOriginalAfterImport else { return }
        let uniqueIdentifiers = Array(Set(assetIdentifiers.filter { !$0.isEmpty }))
        guard !uniqueIdentifiers.isEmpty else { return }
        let generation = lockGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.lockGeneration == generation else { return }
            self.importedSystemAssetsDeletionPrompt = ImportedSystemAssetsDeletionPrompt(
                assetIdentifiers: uniqueIdentifiers,
                importedCount: uniqueIdentifiers.count
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
            .onReceive(NotificationCenter.default.publisher(for: .vaultDidLock)) { _ in
                controller.handleVaultDidLock()
            }
            .onChange(of: viewModel.importResultSummary?.id) { _, _ in
                controller.presentImportResultIfNeeded(
                    viewModel: viewModel,
                    canPresent: canPresentImportResult
                )
            }
            .sheet(item: $controller.presentedImportResult, onDismiss: {
                controller.presentedImportResult = nil
            }) { presented in
                let summary = presented.summary
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
                                let assetIdentifiers = presented.importedSystemAssetIdentifiers
                                controller.showingManagedPhotoImporter = false
                                controller.presentedImportResult = nil
                                controller.scheduleDeletePromptAfterImport(
                                    assetIdentifiers: assetIdentifiers,
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
