import CommonCrypto
import Compression
import CryptoKit
import Foundation

enum VaultImportError: LocalizedError {
    case emptyPassword
    case invalidBackupFile
    case unsupportedVersion
    case unsupportedKDF
    case unsupportedLegacyEncryptedMediaBackup
    case invalidPasswordOrCorruptedBackup
    case failedToDeriveImportKey
    case missingBlob(String)
    case invalidManifest
    case invalidPasswordEncoding
    case cancelled
    case exceedsFreeMediaLimit
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return String(localized: "请先输入导入密码。")
        case .invalidBackupFile:
            return String(localized: "备份文件无效或已损坏，无法恢复。")
        case .unsupportedVersion:
            return String(localized: "当前版本暂不支持这个备份文件。")
        case .unsupportedKDF:
            return String(localized: "备份文件使用了当前版本不支持的密钥派生算法。")
        case .unsupportedLegacyEncryptedMediaBackup:
            return String(localized: "这个备份来自旧版本导出格式，测试版已不再兼容。请使用新版本重新导出后再恢复。")
        case .invalidPasswordOrCorruptedBackup:
            return String(localized: "密码不正确，无法解密此备份文件。请检查后重试。")
        case .failedToDeriveImportKey:
            return String(localized: "无法生成导入密钥，请重试。")
        case let .missingBlob(path):
            return String.localizedStringWithFormat(String(localized: "备份中缺少文件数据：%@"), path)
        case .invalidManifest:
            return String(localized: "备份文件无效或已损坏，无法恢复。")
        case .invalidPasswordEncoding:
            return String(localized: "导入密码编码失败。")
        case .cancelled:
            return String(localized: "恢复已停止。")
        case .exceedsFreeMediaLimit:
            return String(localized: "当前备份会超过免费版 20 个媒体项目上限，请开通会员后再恢复。")
        case let .insufficientDiskSpace(requiredBytes, availableBytes):
            let requiredText = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            let availableText = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            return String.localizedStringWithFormat(
                String(localized: "设备可用存储空间不足（需要约 %1$@，当前可用 %2$@），请清理空间后重试。"),
                requiredText,
                availableText
            )
        }
    }
}

struct VaultImportResult {
    let importedMediaCount: Int
    let importedAlbumCount: Int
    let importedStrongProtectedMediaCount: Int
    let importedStrongProtectedAlbumCount: Int
    let importedRegularPhotoCount: Int
    let importedRegularVideoCount: Int
    let skippedItemCount: Int
    let failedItemCount: Int

    static let empty = VaultImportResult(
        importedMediaCount: 0,
        importedAlbumCount: 0,
        importedStrongProtectedMediaCount: 0,
        importedStrongProtectedAlbumCount: 0,
        importedRegularPhotoCount: 0,
        importedRegularVideoCount: 0,
        skippedItemCount: 0,
        failedItemCount: 0
    )

    func combined(with other: VaultImportResult) -> VaultImportResult {
        VaultImportResult(
            importedMediaCount: importedMediaCount + other.importedMediaCount,
            importedAlbumCount: importedAlbumCount + other.importedAlbumCount,
            importedStrongProtectedMediaCount: importedStrongProtectedMediaCount + other.importedStrongProtectedMediaCount,
            importedStrongProtectedAlbumCount: importedStrongProtectedAlbumCount + other.importedStrongProtectedAlbumCount,
            importedRegularPhotoCount: importedRegularPhotoCount + other.importedRegularPhotoCount,
            importedRegularVideoCount: importedRegularVideoCount + other.importedRegularVideoCount,
            skippedItemCount: skippedItemCount + other.skippedItemCount,
            failedItemCount: failedItemCount + other.failedItemCount
        )
    }
}

nonisolated struct VaultImportInspectionResult {
    let mediaItemCount: Int

    static let empty = VaultImportInspectionResult(mediaItemCount: 0)

    func combined(with other: VaultImportInspectionResult) -> VaultImportInspectionResult {
        VaultImportInspectionResult(mediaItemCount: mediaItemCount + other.mediaItemCount)
    }
}

nonisolated struct VaultImportService: Sendable {
    private static let vaultMagic = Data("SVEX".utf8)
    private static let vaultVersion: UInt8 = 2
    private static let archiveMagic = Data("SVAR".utf8)
    private static let archiveVersion: UInt8 = 1
    private static let maxHeaderBytes = 2 * 1_024 * 1_024
    private static let maxManifestBytes = 64 * 1_024 * 1_024
    private static let maxPathBytes = 4_096
    private static let minOuterChunkBytes = 1_024
    private static let maxOuterChunkBytes = 32 * 1_024 * 1_024
    private static let maxBlobChunkBytes = 16 * 1_024 * 1_024

    private var fileManager: FileManager { FileManager() }
    private let mediaStorage = VaultFileStorageService.shared
    private let metadataStore = EncryptedMetadataStore.shared

    nonisolated func inspectBackupsForImport(
        from backupURLs: [URL],
        password: String,
        onProgress: ((VaultTransferProgress) -> Void)? = nil
    ) async throws -> VaultImportInspectionResult {
        guard !backupURLs.isEmpty else {
            throw VaultImportError.invalidBackupFile
        }

        let importWorker = Task.detached(priority: .userInitiated) { [self] in
            let parts = try orderAndValidateBackupParts(backupURLs)
            #if DEBUG
            VaultTransferLog.mark("import.inspect.start", "fileCount=\(parts.count)")
            #endif
            var combined = VaultImportInspectionResult.empty
            for (index, part) in parts.enumerated() {
                let result = try inspectBackupForImportSync(
                    from: part.url,
                    password: password,
                    onProgress: { progress in
                        let overall = progress.fractionCompleted.map { (Double(index) + $0) / Double(parts.count) }
                        onProgress?(VaultTransferProgress(
                            phase: progress.phase,
                            currentPart: index + 1,
                            totalParts: parts.count,
                            currentItem: progress.currentItem,
                            totalItems: progress.totalItems,
                            currentBytes: progress.currentBytes,
                            totalBytes: progress.totalBytes,
                            message: progress.message,
                            fractionCompleted: overall
                        ))
                    }
                )
                combined = combined.combined(with: result)
            }
            #if DEBUG
            VaultTransferLog.mark("import.inspect.complete", "mediaCount=\(combined.mediaItemCount)")
            #endif
            return combined
        }
        return try await withTaskCancellationHandler {
            try await importWorker.value
        } onCancel: {
            importWorker.cancel()
        }
    }

    nonisolated func importBackups(
        from backupURLs: [URL],
        into targetSpace: VaultSpaceKind,
        password: String,
        maxAllowedTotalMediaCount: Int? = nil,
        currentMediaCount: Int = 0,
        onProgress: ((VaultTransferProgress) -> Void)? = nil
    ) async throws -> VaultImportResult {
        guard !backupURLs.isEmpty else {
            throw VaultImportError.invalidBackupFile
        }

        let importWorker = Task.detached(priority: .userInitiated) { [self] in
            let parts = try orderAndValidateBackupParts(backupURLs)
            let urls = parts.map(\.url)
            try checkAvailableDiskSpaceForImport(backupURLs: urls)

            let stagingRootDirectory = try makeTemporaryImportDirectory()
            BackupOperationRecoveryService.shared.beginImport(stagingDirectoryURL: stagingRootDirectory)
            var importFinishedSuccessfully = false
            defer {
                try? fileManager.removeItem(at: stagingRootDirectory)
                if importFinishedSuccessfully {
                    BackupOperationRecoveryService.shared.complete()
                } else {
                    BackupOperationRecoveryService.shared.abortAndCleanup()
                }
            }

            #if DEBUG
            VaultTransferLog.mark("import.start", "fileCount=\(urls.count)")
            #endif

            var preparedParts: [VaultPreparedImportPart] = []
            var accumulatedIncomingItems = 0
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                #if DEBUG
                VaultTransferLog.mark("import.file.open", "index=\(index + 1) total=\(parts.count) ext=\(part.url.pathExtension)")
                #endif
                let partStagingDirectory = stagingRootDirectory.appendingPathComponent("part-\(index)", isDirectory: true)
                try fileManager.createDirectory(at: partStagingDirectory, withIntermediateDirectories: true)
                defer {
                    try? fileManager.removeItem(at: partStagingDirectory)
                }

                let prepared = try prepareImportPart(
                    from: part.url,
                    into: targetSpace,
                    password: password,
                    stagingDirectory: partStagingDirectory,
                    expectedPartIndex: part.header.partIndex,
                    expectedTotalParts: part.header.totalParts,
                    maxAllowedTotalMediaCount: maxAllowedTotalMediaCount,
                    currentAccumulatedCount: currentMediaCount + accumulatedIncomingItems,
                    onProgress: { progress in
                        let overall = progress.fractionCompleted.map { (Double(index) + $0) / Double(parts.count) * 0.90 }
                        onProgress?(VaultTransferProgress(
                            phase: progress.phase,
                            currentPart: index + 1,
                            totalParts: parts.count,
                            currentItem: progress.currentItem,
                            totalItems: progress.totalItems,
                            currentBytes: progress.currentBytes,
                            totalBytes: progress.totalBytes,
                            message: progress.message,
                            fractionCompleted: overall
                        ))
                    }
                )
                accumulatedIncomingItems += prepared.manifest.items.count
                preparedParts.append(prepared)
                #if DEBUG
                VaultTransferLog.mark("import.file.finish", "index=\(index + 1) total=\(parts.count)")
                #endif
            }

            emitImportProgress(
                VaultTransferProgress(
                    phase: .refreshing,
                    currentPart: urls.count,
                    totalParts: urls.count,
                    message: String(localized: "正在刷新媒体库"),
                    fractionCompleted: 0.94
                ),
                to: onProgress
            )

            let committedParts = preparedParts
            let combined = try await MainActor.run {
                try commitPreparedParts(committedParts, targetSpace: targetSpace)
            }

            importFinishedSuccessfully = true

            emitImportProgress(
                VaultTransferProgress(
                    phase: .completed,
                    currentPart: urls.count,
                    totalParts: urls.count,
                    message: String(localized: "恢复完成"),
                    fractionCompleted: 1
                ),
                to: onProgress
            )

            #if DEBUG
            VaultTransferLog.mark("import.complete", "media=\(combined.importedMediaCount) photos=\(combined.importedRegularPhotoCount) videos=\(combined.importedRegularVideoCount) secure=\(combined.importedStrongProtectedMediaCount)")
            #endif
            return combined
        }
        return try await withTaskCancellationHandler {
            try await importWorker.value
        } onCancel: {
            importWorker.cancel()
        }
    }

    nonisolated func inspectBackupForImport(
        from backupURL: URL,
        password: String,
        onProgress: ((VaultTransferProgress) -> Void)? = nil
    ) async throws -> VaultImportInspectionResult {
        try await Task.detached(priority: .userInitiated) { [self] in
            try inspectBackupForImportSync(from: backupURL, password: password, onProgress: onProgress)
        }.value
    }

    nonisolated private func inspectBackupForImportSync(
        from backupURL: URL,
        password: String,
        onProgress: ((VaultTransferProgress) -> Void)? = nil
    ) throws -> VaultImportInspectionResult {
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassword.isEmpty else {
            throw VaultImportError.emptyPassword
        }

        emitImportProgress(
            VaultTransferProgress(
                phase: .reading,
                message: String(localized: "正在读取备份文件"),
                fractionCompleted: nil
            ),
            to: onProgress
        )
        let didAccess = backupURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                backupURL.stopAccessingSecurityScopedResource()
            }
        }

        let tempImportDirectory = try makeTemporaryImportDirectory()
        defer {
            try? fileManager.removeItem(at: tempImportDirectory)
        }

        let archiveURL = tempImportDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("archive")
        try decryptVaultFile(
            backupURL,
            password: trimmedPassword,
            toArchiveURL: archiveURL,
            onValidationStarted: {
                emitImportProgress(
                    VaultTransferProgress(
                        phase: .validating,
                        message: String(localized: "正在验证备份"),
                        fractionCompleted: nil
                    ),
                    to: onProgress
                )
            },
            onProgress: { completedBytes, totalBytes, completedChunks, totalChunks in
                let progress = totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 1
                let message = String.localizedStringWithFormat(
                    String(localized: "正在解密备份文件（%1$lld / %2$lld）"),
                    Int64(completedChunks),
                    Int64(totalChunks)
                )
                emitImportProgress(
                    VaultTransferProgress(
                        phase: .decrypting,
                        currentItem: completedChunks,
                        totalItems: totalChunks,
                        currentBytes: completedBytes,
                        totalBytes: totalBytes,
                        message: message,
                        fractionCompleted: min(0.06 + progress * 0.34, 0.40)
                    ),
                    to: onProgress
                )
            }
        )

        emitImportProgress(
            VaultTransferProgress(
                phase: .extracting,
                message: String(localized: "正在解压备份"),
                fractionCompleted: nil
            ),
            to: onProgress
        )
        let archive = try readArchiveHeader(from: archiveURL)
        let mediaCount = archive.manifest.items.count
        #if DEBUG
        VaultTransferLog.mark("import.inspect.manifest", "mediaCount=\(mediaCount) albums=\(archive.manifest.albums.count)")
        #endif
        return VaultImportInspectionResult(mediaItemCount: mediaCount)
    }

    nonisolated private func prepareImportPart(
        from backupURL: URL,
        into targetSpace: VaultSpaceKind,
        password: String,
        stagingDirectory: URL,
        expectedPartIndex: Int,
        expectedTotalParts: Int,
        maxAllowedTotalMediaCount: Int?,
        currentAccumulatedCount: Int,
        onProgress: ((VaultTransferProgress) -> Void)? = nil
    ) throws -> VaultPreparedImportPart {
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassword.isEmpty else {
            throw VaultImportError.emptyPassword
        }

        emitImportProgress(
            VaultTransferProgress(
                phase: .reading,
                message: String(localized: "正在读取备份文件"),
                fractionCompleted: nil
            ),
            to: onProgress
        )
        let didAccess = backupURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                backupURL.stopAccessingSecurityScopedResource()
            }
        }

        let archiveURL = stagingDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("archive")
        try decryptVaultFile(
            backupURL,
            password: trimmedPassword,
            toArchiveURL: archiveURL,
            onValidationStarted: {
                emitImportProgress(
                    VaultTransferProgress(
                        phase: .validating,
                        message: String(localized: "正在验证备份"),
                        fractionCompleted: nil
                    ),
                    to: onProgress
                )
            },
            onProgress: { completedBytes, totalBytes, completedChunks, totalChunks in
                let progress = totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 1
                let message = String.localizedStringWithFormat(
                    String(localized: "正在解密备份文件（%1$lld / %2$lld）"),
                    Int64(completedChunks),
                    Int64(totalChunks)
                )
                emitImportProgress(
                    VaultTransferProgress(
                        phase: .decrypting,
                        currentItem: completedChunks,
                        totalItems: totalChunks,
                        currentBytes: completedBytes,
                        totalBytes: totalBytes,
                        message: message,
                        fractionCompleted: min(0.06 + progress * 0.34, 0.40)
                    ),
                    to: onProgress
                )
            }
        )

        emitImportProgress(
            VaultTransferProgress(
                phase: .extracting,
                message: String(localized: "正在解压备份"),
                fractionCompleted: nil
            ),
            to: onProgress
        )
        let archive = try readArchiveHeader(from: archiveURL)
        let manifest = archive.manifest
        guard manifest.partIndex == expectedPartIndex,
              manifest.totalParts == expectedTotalParts else {
            throw VaultImportError.invalidManifest
        }
        if let maxAllowedTotalMediaCount,
           currentAccumulatedCount + manifest.items.count > maxAllowedTotalMediaCount {
            throw VaultImportError.exceedsFreeMediaLimit
        }

        emitImportProgress(
            VaultTransferProgress(
                phase: .extracting,
                currentItem: manifest.blobEntries.count,
                totalItems: manifest.blobEntries.count,
                message: String(localized: "备份索引已读取，正在准备恢复媒体"),
                fractionCompleted: nil
            ),
            to: onProgress
        )

        let manifestBlobMap = Dictionary(
            manifest.blobEntries.map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let manifestItemsByRelativePath = Dictionary(
            manifest.items.map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let manifestItemsByCompanionPath = Dictionary(
            manifest.items.compactMap { item in item.livePhotoCompanionRelativePath.map { ($0, item) } },
            uniquingKeysWith: { first, _ in first }
        )
        var restoredMediaRelativePaths: [String: String] = [:]
        var restoredCompanionPaths: [String: String] = [:]
        var restoredCoverPaths: [String: String] = [:]

        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer {
            try? handle.close()
        }
        try handle.seek(toOffset: archive.blobsOffset)

        guard let blobCount = Int(exactly: try readUInt32(from: handle)),
              blobCount == manifest.blobEntries.count else {
            throw VaultImportError.invalidManifest
        }
        var restoredBlobCount = 0
        for _ in 0..<blobCount {
            try Task.checkCancellation()
            let entryPath = try readString(from: handle)
            let domain = try readSourceDomain(from: handle)
            guard let expectedByteCount = Int64(exactly: try readUInt64(from: handle)),
                  expectedByteCount >= 0 else {
                throw VaultImportError.invalidBackupFile
            }

            guard let manifestBlob = manifestBlobMap[entryPath],
                  manifestBlob.sourceDomain == domain,
                  manifestBlob.byteCount == expectedByteCount else {
                throw VaultImportError.invalidManifest
            }

            switch domain {
            case .media:
                guard let itemRecord = manifestItemsByRelativePath[entryPath] else {
                    throw VaultImportError.invalidManifest
                }
                restoredMediaRelativePaths[entryPath] = try restoreEncryptedBlob(
                    from: handle,
                    expectedByteCount: expectedByteCount,
                    to: restoredRelativePath(bucket: itemRecord.isInTrash ? "Trash" : "Active", extensionSource: itemRecord.originalFilename, targetSpace: targetSpace),
                    targetSpace: targetSpace
                )
            case .livePhotoCompanion:
                guard let itemRecord = manifestItemsByCompanionPath[entryPath] else {
                    throw VaultImportError.invalidManifest
                }
                restoredCompanionPaths[entryPath] = try restoreEncryptedBlob(
                    from: handle,
                    expectedByteCount: expectedByteCount,
                    to: restoredRelativePath(bucket: itemRecord.isInTrash ? "Trash" : "Active", extensionSource: entryPath, targetSpace: targetSpace),
                    targetSpace: targetSpace
                )
            case .albumCover:
                restoredCoverPaths[entryPath] = try restoreEncryptedBlob(
                    from: handle,
                    expectedByteCount: expectedByteCount,
                    to: restoredRelativePath(bucket: "AlbumCovers", extensionSource: entryPath, targetSpace: targetSpace),
                    targetSpace: targetSpace
                )
            }

            restoredBlobCount += 1
            let progress = blobCount > 0 ? Double(restoredBlobCount) / Double(blobCount) : 1
            emitImportProgress(
                VaultTransferProgress(
                    phase: .restoring,
                    currentItem: restoredBlobCount,
                    totalItems: blobCount,
                    message: String.localizedStringWithFormat(String(localized: "正在恢复项目 %1$lld / %2$lld"), restoredBlobCount, blobCount),
                    fractionCompleted: min(0.44 + progress * 0.50, 0.94)
                ),
                to: onProgress
            )
        }

        return VaultPreparedImportPart(
            manifest: manifest,
            restoredMediaRelativePaths: restoredMediaRelativePaths,
            restoredCompanionPaths: restoredCompanionPaths,
            restoredCoverPaths: restoredCoverPaths
        )
    }

    @MainActor
    private func commitPreparedParts(
        _ preparedParts: [VaultPreparedImportPart],
        targetSpace: VaultSpaceKind
    ) throws -> VaultImportResult {
        var session = VaultImportSession()
        let existingSnapshot = try metadataStore.loadSnapshot(for: targetSpace)
        var existingAlbums = existingSnapshot.albums
        var existingItems = existingSnapshot.items
        var combined = VaultImportResult.empty

        for part in preparedParts {
            for (oldCoverPath, newCoverPath) in part.restoredCoverPaths {
                session.coverPaths[oldCoverPath] = newCoverPath
            }
            let result = try restoreMedia(
                manifest: part.manifest,
                restoredMediaRelativePaths: part.restoredMediaRelativePaths,
                restoredCompanionPaths: part.restoredCompanionPaths,
                session: &session,
                existingAlbums: &existingAlbums,
                existingItems: &existingItems,
                targetSpace: targetSpace
            )
            combined = combined.combined(with: result)
        }

        BackupOperationRecoveryService.shared.markImportEnteringMetadataSave()
        do {
            try metadataStore.saveSnapshot(space: targetSpace, albums: existingAlbums, items: existingItems)
        } catch {
            BackupOperationRecoveryService.shared.revertImportToRestoringFiles()
            throw error
        }
        return combined
    }

    nonisolated private func orderAndValidateBackupParts(_ backupURLs: [URL]) throws -> [(url: URL, header: VaultBackupHeader)] {
        guard !backupURLs.isEmpty else {
            throw VaultImportError.invalidBackupFile
        }
        var entries: [(url: URL, header: VaultBackupHeader)] = []
        entries.reserveCapacity(backupURLs.count)
        var seenSaltSet = Set<String>()
        var seenPartIndices = Set<Int>()
        var expectedTotalParts: Int?

        for url in backupURLs {
            let header = try readBackupHeader(from: url)
            guard header.totalParts >= 1,
                  header.partIndex >= 0,
                  header.partIndex < header.totalParts,
                  seenSaltSet.insert(header.kdf.saltBase64).inserted else {
                throw VaultImportError.invalidBackupFile
            }
            if backupURLs.count > 1 {
                if let expected = expectedTotalParts {
                    guard header.totalParts == expected else {
                        throw VaultImportError.invalidBackupFile
                    }
                } else {
                    expectedTotalParts = header.totalParts
                }
                guard seenPartIndices.insert(header.partIndex).inserted else {
                    throw VaultImportError.invalidBackupFile
                }
            }
            entries.append((url, header))
        }

        return entries.sorted { lhs, rhs in
            if lhs.header.partIndex != rhs.header.partIndex {
                return lhs.header.partIndex < rhs.header.partIndex
            }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
    }

    nonisolated private func readBackupHeader(from backupURL: URL) throws -> VaultBackupHeader {
        let didAccess = backupURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                backupURL.stopAccessingSecurityScopedResource()
            }
        }
        let inputHandle = try FileHandle(forReadingFrom: backupURL)
        defer {
            try? inputHandle.close()
        }
        guard try readData(count: Self.vaultMagic.count, from: inputHandle) == Self.vaultMagic else {
            throw VaultImportError.invalidBackupFile
        }
        let version = try readUInt8(from: inputHandle)
        guard version == Self.vaultVersion else {
            throw VaultImportError.unsupportedVersion
        }
        guard let headerLength = Int(exactly: try readUInt32(from: inputHandle)),
              headerLength > 0, headerLength <= Self.maxHeaderBytes else {
            throw VaultImportError.invalidBackupFile
        }
        let headerData = try readData(count: headerLength, from: inputHandle)
        let header = try JSONDecoder.vaultImportDecoder.decode(VaultBackupHeader.self, from: headerData)
        guard header.formatVersion == 2 || header.formatVersion == 3 else {
            throw VaultImportError.unsupportedVersion
        }
        return header
    }

    nonisolated private func checkAvailableDiskSpaceForImport(backupURLs: [URL]) throws {
        var totalBackupBytes: Int64 = 0
        var maxSinglePartBytes: Int64 = 0
        for url in backupURLs {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            let fileSize = Int64(values?.fileSize ?? 0)
            totalBackupBytes += fileSize
            maxSinglePartBytes = max(maxSinglePartBytes, fileSize)
        }
        let requiredSpace = totalBackupBytes + maxSinglePartBytes + 64 * 1_024 * 1_024
        if let availableSpace = VaultBackupCryptoHelper.availableDiskCapacity(at: fileManager.temporaryDirectory),
           availableSpace < requiredSpace {
            throw VaultImportError.insufficientDiskSpace(requiredBytes: requiredSpace, availableBytes: availableSpace)
        }
    }

    private func decryptVaultFile(
        _ backupURL: URL,
        password: String,
        toArchiveURL archiveURL: URL,
        onValidationStarted: (() -> Void)? = nil,
        onProgress: ((_ completedBytes: Int64, _ totalBytes: Int64, _ completedChunks: Int, _ totalChunks: Int) -> Void)? = nil
    ) throws {
        let inputHandle = try FileHandle(forReadingFrom: backupURL)
        defer {
            try? inputHandle.close()
        }

        onValidationStarted?()
        guard try readData(count: Self.vaultMagic.count, from: inputHandle) == Self.vaultMagic else {
            throw VaultImportError.invalidBackupFile
        }
        let version = try readUInt8(from: inputHandle)
        guard version == Self.vaultVersion else {
            throw VaultImportError.unsupportedVersion
        }

        guard let headerLength = Int(exactly: try readUInt32(from: inputHandle)),
              headerLength > 0, headerLength <= Self.maxHeaderBytes else {
            throw VaultImportError.invalidBackupFile
        }
        let headerData = try readData(count: headerLength, from: inputHandle)
        let header = try JSONDecoder.vaultImportDecoder.decode(VaultBackupHeader.self, from: headerData)
        #if DEBUG
        VaultTransferLog.mark("import.header", "version=\(header.formatVersion) partIndex=\(header.partIndex + 1) totalParts=\(header.totalParts) archiveBytes=\(header.archiveByteCount)")
        #endif
        guard header.formatVersion == 2 || header.formatVersion == 3 else {
            throw VaultImportError.unsupportedVersion
        }
        guard header.archiveEncoding == "chunked-lzfse-v1",
              header.cipher == "aes-gcm-chunked-archive" else {
            throw VaultImportError.unsupportedLegacyEncryptedMediaBackup
        }
        guard header.kdf.algorithm == "pbkdf2-sha256",
              let salt = Data(base64Encoded: header.kdf.saltBase64),
              salt.count >= VaultBackupCryptoHelper.minSaltBytes,
              salt.count <= VaultBackupCryptoHelper.maxSaltBytes,
              header.kdf.rounds >= VaultBackupCryptoHelper.minPBKDF2Rounds,
              header.kdf.rounds <= VaultBackupCryptoHelper.maxPBKDF2Rounds else {
            throw VaultImportError.unsupportedKDF
        }
        guard header.chunkSize >= Self.minOuterChunkBytes,
              header.chunkSize <= Self.maxOuterChunkBytes,
              header.archiveByteCount >= 0 else {
            throw VaultImportError.invalidBackupFile
        }

        let importKey = try deriveImportKey(password: password, salt: salt, rounds: header.kdf.rounds)

        fileManager.createFile(atPath: archiveURL.path(), contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: archiveURL.path())
        let outputHandle = try FileHandle(forWritingTo: archiveURL)
        defer {
            try? outputHandle.close()
        }

        var completedBytes: Int64 = 0
        var expectedChunkIndex = 0
        let importChunkSize = header.chunkSize
        let maxCiphertextBytes = importChunkSize + 4_096
        let (chunkNumerator, numeratorOverflow) = header.archiveByteCount.addingReportingOverflow(Int64(importChunkSize) - 1)
        let estimatedTotalChunks = numeratorOverflow
            ? Int.max
            : max(1, Int(clamping: chunkNumerator / Int64(importChunkSize)))
        while true {
            try Task.checkCancellation()
            let chunkIndexData = try inputHandle.read(upToCount: MemoryLayout<UInt32>.size) ?? Data()
            if chunkIndexData.isEmpty {
                break
            }
            guard chunkIndexData.count == MemoryLayout<UInt32>.size else {
                throw VaultImportError.invalidBackupFile
            }
            let chunkIndex = Int(chunkIndexData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard chunkIndex == expectedChunkIndex else {
                throw VaultImportError.invalidBackupFile
            }
            guard let plaintextLength = Int(exactly: try readUInt64(from: inputHandle)),
                  let ciphertextLength = Int(exactly: try readUInt64(from: inputHandle)),
                  plaintextLength >= 0, plaintextLength <= importChunkSize else {
                throw VaultImportError.invalidBackupFile
            }
            guard let nonceLength = Int(exactly: try readUInt32(from: inputHandle)),
                  nonceLength > 0, nonceLength <= 64 else {
                throw VaultImportError.invalidBackupFile
            }
            let nonceData = try readData(count: nonceLength, from: inputHandle)
            guard let tagLength = Int(exactly: try readUInt32(from: inputHandle)),
                  tagLength > 0, tagLength <= 64 else {
                throw VaultImportError.invalidBackupFile
            }
            let tagData = try readData(count: tagLength, from: inputHandle)
            guard ciphertextLength >= 0, ciphertextLength <= maxCiphertextBytes else {
                throw VaultImportError.invalidBackupFile
            }
            let ciphertext = try readData(count: ciphertextLength, from: inputHandle)

            do {
                let nonce = try AES.GCM.Nonce(data: nonceData)
                let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagData)
                let aad = authenticatedData(for: header, chunkIndex: chunkIndex)
                let plaintext = try AES.GCM.open(sealedBox, using: importKey, authenticating: aad)
                guard plaintext.count == plaintextLength else {
                    throw VaultImportError.invalidBackupFile
                }
                let (nextCompletedBytes, completedOverflow) = completedBytes.addingReportingOverflow(Int64(plaintext.count))
                guard !completedOverflow, nextCompletedBytes <= header.archiveByteCount else {
                    throw VaultImportError.invalidBackupFile
                }
                try outputHandle.write(contentsOf: plaintext)
                completedBytes = nextCompletedBytes
                expectedChunkIndex += 1
                #if DEBUG
                VaultTransferLog.mark(
                    "import.decrypt.chunk",
                    "index=\(expectedChunkIndex) total=\(estimatedTotalChunks) bytes=\(completedBytes)/\(header.archiveByteCount)"
                )
                #endif
                onProgress?(completedBytes, max(header.archiveByteCount, 1), expectedChunkIndex, estimatedTotalChunks)
            } catch let error as VaultImportError {
                throw error
            } catch {
                throw VaultImportError.invalidPasswordOrCorruptedBackup
            }
        }

        guard completedBytes == header.archiveByteCount else {
            throw VaultImportError.invalidBackupFile
        }
    }

    private func emitImportProgress(
        _ progress: VaultTransferProgress,
        to onProgress: ((VaultTransferProgress) -> Void)?
    ) {
        #if DEBUG
        let fractionDescription = progress.fractionCompleted.map { String(format: "%.4f", $0) } ?? "indeterminate"
        VaultTransferLog.mark(
            "import.progress.update",
            "phase=\(progress.phase.rawValue) fraction=\(fractionDescription) item=\(progress.currentItem)/\(progress.totalItems) bytes=\(progress.currentBytes)/\(progress.totalBytes)"
        )
        #endif
        onProgress?(progress)
    }

    private func readArchiveHeader(from archiveURL: URL) throws -> VaultArchiveReadState {
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer {
            try? handle.close()
        }

        guard try readData(count: Self.archiveMagic.count, from: handle) == Self.archiveMagic else {
            throw VaultImportError.invalidBackupFile
        }
        let version = try readUInt8(from: handle)
        guard version == Self.archiveVersion else {
            throw VaultImportError.unsupportedVersion
        }
        guard let manifestLength = Int(exactly: try readUInt64(from: handle)),
              manifestLength > 0, manifestLength <= Self.maxManifestBytes else {
            throw VaultImportError.invalidBackupFile
        }
        let manifestData = try readData(count: manifestLength, from: handle)
        let manifest = try JSONDecoder.vaultImportDecoder.decode(VaultBackupPartManifest.self, from: manifestData)
        #if DEBUG
        VaultTransferLog.mark("import.archive.read", "itemCount=\(manifest.items.count) blobCount=\(manifest.blobEntries.count)")
        #endif
        let offset = try handle.offset()
        return VaultArchiveReadState(manifest: manifest, blobsOffset: offset)
    }

    @MainActor
    private func restoreMedia(
        manifest: VaultBackupPartManifest,
        restoredMediaRelativePaths: [String: String],
        restoredCompanionPaths: [String: String],
        session: inout VaultImportSession,
        existingAlbums: inout [VaultAlbum],
        existingItems: inout [VaultItem],
        targetSpace: VaultSpaceKind
    ) throws -> VaultImportResult {
        var usedAlbumNames = Set(existingAlbums.map(\.name))
        var importedAlbumsByOldID: [String: VaultAlbum] = [:]
        var newAlbumIDs = Set<UUID>()

        for albumRecord in manifest.albums {
            guard let albumKind = MediaAlbumKind(rawValue: albumRecord.kindRawValue),
                  albumKind == .custom || albumKind == .secureCustom else {
                continue
            }
            // An album spanning several backup parts is created once and reused by later parts.
            if let restoredID = session.albumIDs[albumRecord.id],
               let restoredAlbum = existingAlbums.first(where: { $0.id == restoredID }) {
                importedAlbumsByOldID[albumRecord.id] = restoredAlbum
                continue
            }
            let albumName = availableName(from: albumRecord.name, usedNames: &usedAlbumNames)
            let album = VaultAlbum(
                name: albumName,
                kind: albumKind,
                space: targetSpace,
                coverImageRelativePath: albumRecord.coverImageRelativePath.flatMap { session.coverPaths[$0] },
                coverSymbolName: albumRecord.coverSymbolName,
                sortOption: AlbumSortOption(rawValue: albumRecord.sortOptionRawValue) ?? .newestFirst,
                showsCover: albumRecord.showsCover,
                libraryOrderIndex: nextLibraryOrderIndex(existingAlbums: existingAlbums, importedCount: importedAlbumsByOldID.count),
                colorRawValue: albumRecord.colorRawValue
            )
            existingAlbums.append(album)
            importedAlbumsByOldID[albumRecord.id] = album
            session.albumIDs[albumRecord.id] = album.id
            newAlbumIDs.insert(album.id)
        }

        var importedItemsByOldID: [String: VaultItem] = [:]

        for itemRecord in manifest.items {
            guard let storedPath = restoredMediaRelativePaths[itemRecord.relativePath] else {
                throw VaultImportError.missingBlob(itemRecord.relativePath)
            }

            let itemAlbums = itemRecord.albumIDs.compactMap { importedAlbumsByOldID[$0] }
            let item = VaultItem(
                name: itemRecord.name,
                createdAt: itemRecord.createdAt,
                importedAt: itemRecord.importedAt ?? itemRecord.createdAt,
                lastExportedAt: itemRecord.lastExportedAt,
                originalCapturedAt: itemRecord.originalCapturedAt,
                updatedAt: itemRecord.updatedAt,
                mediaKind: MediaKind(rawValue: itemRecord.mediaKindRawValue) ?? .photo,
                space: targetSpace,
                isInTrash: itemRecord.isInTrash,
                isArchived: itemRecord.isArchived,
                isStrongProtected: itemRecord.isStrongProtected,
                relativePath: storedPath,
                originalFilename: itemRecord.originalFilename,
                contentTypeIdentifier: itemRecord.contentTypeIdentifier,
                locationLatitude: itemRecord.locationLatitude,
                locationLongitude: itemRecord.locationLongitude,
                albums: itemAlbums,
                livePhotoCompanionRelativePath: itemRecord.livePhotoCompanionRelativePath.flatMap { restoredCompanionPaths[$0] },
                videoDuration: itemRecord.videoDuration,
                trashedAt: itemRecord.trashedAt ?? (itemRecord.isInTrash ? itemRecord.updatedAt : nil)
            )
            existingItems.append(item)
            importedItemsByOldID[itemRecord.id] = item
        }

        for albumRecord in manifest.albums {
            guard let importedAlbum = importedAlbumsByOldID[albumRecord.id] else { continue }
            if let coverItemID = albumRecord.coverItemIDRawValue.flatMap({ importedItemsByOldID[$0]?.id }) {
                importedAlbum.coverItemID = coverItemID
            }
            if importedAlbum.coverImageRelativePath == nil {
                importedAlbum.coverImageRelativePath = albumRecord.coverImageRelativePath.flatMap { session.coverPaths[$0] }
            }
            let orderedIDs = albumRecord.customOrderedItemIDs.compactMap { importedItemsByOldID[$0]?.id }
            if newAlbumIDs.contains(importedAlbum.id) {
                importedAlbum.customOrderedUUIDs = orderedIDs
            } else {
                importedAlbum.customOrderedUUIDs += orderedIDs
            }
        }

        for album in existingAlbums {
            album.items = []
        }
        for item in existingItems {
            for album in item.albums {
                if let targetAlbum = existingAlbums.first(where: { $0.id == album.id }) {
                    targetAlbum.items.append(item)
                }
            }
        }

        let importedItems = Array(importedItemsByOldID.values)
        let newAlbums = existingAlbums.filter { newAlbumIDs.contains($0.id) }
        return VaultImportResult(
            importedMediaCount: importedItems.count,
            importedAlbumCount: newAlbums.count,
            importedStrongProtectedMediaCount: importedItems.filter(\.isStrongProtected).count,
            importedStrongProtectedAlbumCount: newAlbums.filter(\.isSecureAlbum).count,
            // Live Photos are photos from the user's perspective; count them with photos,
            // not as a separate category, and never count the paired companion video.
            importedRegularPhotoCount: importedItems.filter { !$0.isStrongProtected && ($0.mediaKind == .photo || $0.mediaKind == .livePhoto) }.count,
            importedRegularVideoCount: importedItems.filter { !$0.isStrongProtected && $0.mediaKind == .video }.count,
            skippedItemCount: 0,
            failedItemCount: 0
        )
    }

    private func restoredRelativePath(bucket: String, extensionSource: String, targetSpace: VaultSpaceKind) -> String {
        let rawExtension = URL(fileURLWithPath: extensionSource).pathExtension
        let pathExtension = String(rawExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(16))
        let directoryName = targetSpace == .spaceA ? "Space_A" : "Space_B"
        let filename = pathExtension.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(pathExtension)"
        return "VaultStorage/\(directoryName)/\(bucket)/\(filename)"
    }

    private func restoreEncryptedBlob(
        from handle: FileHandle,
        expectedByteCount: Int64,
        to relativePath: String,
        targetSpace: VaultSpaceKind
    ) throws -> String {
        #if DEBUG
        VaultTransferLog.mark("import.restore.blob", "bytes=\(expectedByteCount)")
        #endif
        let destinationURL = mediaStorage.fileURL(for: relativePath)

        let writer = try VaultCryptoService.shared.makeEncryptedFileWriter(to: destinationURL, space: targetSpace)
        var remaining = expectedByteCount

        do {
            while remaining > 0 {
                try Task.checkCancellation()
                let codecRawValue = try readUInt8(from: handle)
                guard let codec = VaultArchiveChunkCodec(rawValue: codecRawValue) else {
                    throw VaultImportError.invalidBackupFile
                }
                guard let plaintextLength = Int(exactly: try readUInt32(from: handle)),
                      let payloadLength = Int(exactly: try readUInt32(from: handle)),
                      plaintextLength > 0,
                      plaintextLength <= Self.maxBlobChunkBytes,
                      Int64(plaintextLength) <= remaining,
                      payloadLength > 0,
                      payloadLength <= Self.maxBlobChunkBytes else {
                    throw VaultImportError.invalidBackupFile
                }
                let payload = try readData(count: payloadLength, from: handle)
                let chunk = try decompressedArchivePayload(payload, codec: codec, plaintextLength: plaintextLength)
                try writer.append(plaintextChunk: chunk)
                remaining -= Int64(chunk.count)
            }
            guard remaining == 0 else {
                throw VaultImportError.invalidBackupFile
            }

            try writer.finish()
            BackupOperationRecoveryService.shared.registerImportedFileForCleanup(destinationURL)
            return relativePath
        } catch is CancellationError {
            writer.abort()
            throw VaultImportError.cancelled
        } catch let error as VaultImportError {
            writer.abort()
            throw error
        } catch {
            writer.abort()
            throw VaultImportError.invalidBackupFile
        }
    }

    nonisolated private func deriveImportKey(password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        try VaultBackupCryptoHelper.derivePBKDF2Key(
            password: password,
            salt: salt,
            rounds: rounds,
            encodingError: VaultImportError.invalidPasswordEncoding,
            derivationError: VaultImportError.failedToDeriveImportKey
        )
    }

    nonisolated private func authenticatedData(for header: VaultBackupHeader, chunkIndex: Int) -> Data {
        VaultBackupCryptoHelper.authenticatedData(for: header, chunkIndex: chunkIndex)
    }

    private func decompressedArchivePayload(_ payload: Data, codec: VaultArchiveChunkCodec, plaintextLength: Int) throws -> Data {
        switch codec {
        case .raw:
            guard payload.count == plaintextLength else {
                throw VaultImportError.invalidBackupFile
            }
            return payload
        case .lzfse:
            guard plaintextLength > 0, plaintextLength <= Self.maxBlobChunkBytes, !payload.isEmpty else {
                throw VaultImportError.invalidBackupFile
            }
            var output = Data(count: plaintextLength + 1)
            let decodedCount = output.withUnsafeMutableBytes { destinationBuffer -> Int in
                guard let dstBase = destinationBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return payload.withUnsafeBytes { sourceBuffer -> Int in
                    guard let srcBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return compression_decode_buffer(
                        dstBase,
                        plaintextLength + 1,
                        srcBase,
                        payload.count,
                        nil,
                        COMPRESSION_LZFSE
                    )
                }
            }
            guard decodedCount == plaintextLength else {
                throw VaultImportError.invalidBackupFile
            }
            output.removeSubrange(plaintextLength..<output.count)
            return output
        }
    }

    private func makeTemporaryImportDirectory() throws -> URL {
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("VaultImports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func readData(count: Int, from handle: FileHandle) throws -> Data {
        guard count >= 0 else {
            throw VaultImportError.invalidBackupFile
        }
        if count == 0 {
            return Data()
        }
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else {
            throw VaultImportError.invalidBackupFile
        }
        return data
    }

    private func readUInt8(from handle: FileHandle) throws -> UInt8 {
        let data = try readData(count: 1, from: handle)
        return data[0]
    }

    private func readUInt32(from handle: FileHandle) throws -> UInt32 {
        let data = try readData(count: MemoryLayout<UInt32>.size, from: handle)
        return data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    private func readUInt64(from handle: FileHandle) throws -> UInt64 {
        let data = try readData(count: MemoryLayout<UInt64>.size, from: handle)
        return data.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
    }

    private func readString(from handle: FileHandle) throws -> String {
        guard let byteCount = Int(exactly: try readUInt32(from: handle)),
              byteCount >= 0, byteCount <= Self.maxPathBytes else {
            throw VaultImportError.invalidBackupFile
        }
        let data = try readData(count: byteCount, from: handle)
        guard let string = String(data: data, encoding: .utf8) else {
            throw VaultImportError.invalidBackupFile
        }
        return string
    }

    private func readSourceDomain(from handle: FileHandle) throws -> VaultBackupSourceDomain {
        let rawValue = try readUInt8(from: handle)
        guard let domain = VaultBackupSourceDomain(rawValue: rawValue) else {
            throw VaultImportError.invalidBackupFile
        }
        return domain
    }

    private func skipBytes(_ byteCount: Int64, from handle: FileHandle) throws {
        var remaining = byteCount
        while remaining > 0 {
            let readLength = Int(min(1 * 1_024 * 1_024, remaining))
            _ = try readData(count: readLength, from: handle)
            remaining -= Int64(readLength)
        }
    }

    private func availableName(from originalName: String, usedNames: inout Set<String>) -> String {
        guard usedNames.contains(originalName) else {
            usedNames.insert(originalName)
            return originalName
        }

        var index = 2
        while true {
            let candidate = "\(originalName) \(index)"
            if !usedNames.contains(candidate) {
                usedNames.insert(candidate)
                return candidate
            }
            index += 1
        }
    }

    @MainActor
    private func nextLibraryOrderIndex(existingAlbums: [VaultAlbum], importedCount: Int) -> Int {
        let currentMax = existingAlbums.map(\.libraryOrderIndex).max() ?? -1
        return currentMax + importedCount + 1
    }
}

nonisolated private struct VaultPreparedImportPart {
    let manifest: VaultBackupPartManifest
    let restoredMediaRelativePaths: [String: String]
    let restoredCompanionPaths: [String: String]
    let restoredCoverPaths: [String: String]
}

nonisolated private struct VaultArchiveReadState {
    let manifest: VaultBackupPartManifest
    let blobsOffset: UInt64
}

/// State shared across the parts of one multi-file restore.
private struct VaultImportSession {
    /// Backup album ID → album created by this restore.
    var albumIDs: [String: UUID] = [:]
    /// Cover path inside the backup → restored cover path.
    var coverPaths: [String: String] = [:]
}

nonisolated private extension JSONDecoder {
    static var vaultImportDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
