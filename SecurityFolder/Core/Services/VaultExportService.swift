import CommonCrypto
import Compression
import CryptoKit
import Darwin
import Foundation
import Security

enum VaultExportError: LocalizedError {
    case emptyPassword
    case failedToDeriveExportKey
    case missingSourceFile(String)
    case invalidPasswordEncoding
    case cancelled
    case invalidArchive
    case failedToCreateBackupFile

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return String(localized: "请先输入导出密码。")
        case .failedToDeriveExportKey:
            return String(localized: "无法生成导出密钥，请重试。")
        case let .missingSourceFile(path):
            return String.localizedStringWithFormat(String(localized: "导出时找不到文件：%@"), path)
        case .invalidPasswordEncoding:
            return String(localized: "导出密码编码失败。")
        case .cancelled:
            return String(localized: "导出已停止。")
        case .invalidArchive:
            return String(localized: "无法生成备份文件，请重试。")
        case .failedToCreateBackupFile:
            return String(localized: "备份文件生成失败，请重试。")
        }
    }
}

struct VaultExportResult {
    let fileURLs: [URL]
    let fileNames: [String]

    var fileURL: URL { fileURLs[0] }
    var fileName: String { fileNames[0] }
}

nonisolated private final class VaultExportProgressEmitter: @unchecked Sendable {
    private let onProgress: ((VaultTransferProgress) -> Void)?
    private let minInterval: TimeInterval
    private let lock = NSLock()
    private var lastEmitTime: CFAbsoluteTime = 0
    private var pendingProgress: VaultTransferProgress?
    private var flushScheduled = false

    init(
        onProgress: ((VaultTransferProgress) -> Void)?,
        minInterval: TimeInterval = 0.15
    ) {
        self.onProgress = onProgress
        self.minInterval = minInterval
    }

    func emit(_ progress: VaultTransferProgress, force: Bool = false) {
        guard let onProgress else { return }

        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if force || now - lastEmitTime >= minInterval {
            lastEmitTime = now
            pendingProgress = nil
            lock.unlock()
            DispatchQueue.main.async {
                onProgress(progress)
            }
            return
        }

        pendingProgress = progress
        if flushScheduled {
            lock.unlock()
            return
        }
        flushScheduled = true
        let delay = max(0.02, minInterval - (now - lastEmitTime))
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        guard let onProgress else { return }
        lock.lock()
        guard let progress = pendingProgress else {
            flushScheduled = false
            lock.unlock()
            return
        }
        pendingProgress = nil
        flushScheduled = false
        lastEmitTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        onProgress(progress)
    }
}

nonisolated struct VaultExportService {
    private static let vaultMagic = Data("SVEX".utf8)
    private static let vaultVersion: UInt8 = 2
    private static let archiveMagic = Data("SVAR".utf8)
    private static let archiveVersion: UInt8 = 1

    private let fileManager = FileManager.default
    private let mediaStorage = VaultFileStorageService.shared
    private let cryptoService = VaultCryptoService.shared
    private let metadataStore = EncryptedMetadataStore.shared

    private let vaultChunkSize = 8 * 1_024 * 1_024
    private let archiveCopyChunkSize = 1 * 1_024 * 1_024
    private let pbkdfRounds = 600_000
    private let maxItemsPerPart = 700
    private let targetPartBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    nonisolated func exportCurrentSpace(
        space: VaultSpaceKind,
        password: String,
        onProgress: ((VaultTransferProgress) -> Void)? = nil
    ) async throws -> VaultExportResult {
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassword.isEmpty else {
            throw VaultExportError.emptyPassword
        }

        let progressEmitter = VaultExportProgressEmitter(onProgress: onProgress)
        progressEmitter.emit(VaultTransferProgress(phase: .scanning, message: String(localized: "正在整理当前空间索引"), fractionCompleted: 0.02), force: true)
        #if DEBUG
        VaultTransferLog.mark("export.start", "space=\(space.rawValue)")
        #endif
        let plan = try await MainActor.run {
            try buildExportPlan(for: space)
        }
        guard !plan.parts.isEmpty else {
            throw VaultExportError.invalidArchive
        }

        let exportDirectory = try makeExportDirectory()
        BackupOperationRecoveryService.shared.beginExport(partialArchiveURL: exportDirectory)
        #if DEBUG
        let estimatedBytes = plan.parts.reduce(Int64(0)) { $0 + $1.estimatedPlaintextBytes }
        let itemCount = plan.parts.reduce(0) { $0 + $1.manifest.items.count }
        VaultTransferLog.mark("export.plan", "parts=\(plan.parts.count) itemCount=\(itemCount) estimatedBytes=\(estimatedBytes) maxItemsPerPart=\(maxItemsPerPart) maxBytesPerPart=\(targetPartBytes)")
        #endif
        var finishedSuccessfully = false
        defer {
            if finishedSuccessfully {
                BackupOperationRecoveryService.shared.complete()
            } else {
                BackupOperationRecoveryService.shared.abortAndCleanup()
            }
        }

        // exportPlannedParts saves each part to BackupFiles immediately after finalizing,
        // so the returned URLs are already stored BackupFiles paths.
        let storedResultURLs = try await Task.detached(priority: .userInitiated) { [self] in
            try exportPlannedParts(
                plan: plan,
                sourceSpace: space,
                password: trimmedPassword,
                exportDirectory: exportDirectory,
                progressEmitter: progressEmitter
            )
        }.value
        try? fileManager.removeItem(at: exportDirectory)

        finishedSuccessfully = true
        progressEmitter.emit(VaultTransferProgress(
            phase: .completed,
            currentPart: storedResultURLs.count,
            totalParts: storedResultURLs.count,
            message: String.localizedStringWithFormat(String(localized: "备份已保存，已生成 %lld 个备份文件。"), storedResultURLs.count),
            fractionCompleted: 1
        ), force: true)

        return VaultExportResult(fileURLs: storedResultURLs, fileNames: storedResultURLs.map(\.lastPathComponent))
    }

    nonisolated private func exportPlannedParts(
        plan: VaultBackupPlan,
        sourceSpace: VaultSpaceKind,
        password: String,
        exportDirectory: URL,
        progressEmitter: VaultExportProgressEmitter
    ) throws -> [URL] {
        var storedResultURLs: [URL] = []
        for part in plan.parts {
            try Task.checkCancellation()

            let archiveURL = exportDirectory.appendingPathComponent(".\(UUID().uuidString).archive")
            defer {
                // Safety net: encryptArchive unlinks the archive after opening its fd,
                // but clean up here if it throws before reaching that point.
                try? fileManager.removeItem(at: archiveURL)
            }

            try writePlainArchive(
                part: part,
                sourceSpace: sourceSpace,
                to: archiveURL,
                onProgress: { completedBytes, totalBytes in
                    let partProgress = totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 1
                    let overall = progressBase(for: part, totalParts: plan.parts.count) + partProgress * progressSpan(totalParts: plan.parts.count) * 0.45
                    progressEmitter.emit(VaultTransferProgress(
                        phase: .compressing,
                        currentPart: part.partIndex + 1,
                        totalParts: plan.parts.count,
                        currentBytes: completedBytes,
                        totalBytes: totalBytes,
                        message: String.localizedStringWithFormat(String(localized: "正在写入第 %1$lld / %2$lld 个备份文件"), part.partIndex + 1, plan.parts.count),
                        fractionCompleted: min(overall, 0.86)
                    ))
                }
            )

            let archiveSize = sourceFileSize(at: archiveURL)
            #if DEBUG
            VaultTransferLog.mark("export.archive.finish", "index=\(part.partIndex + 1) exists=\(hasFile(at: archiveURL)) bytes=\(archiveSize)")
            if archiveSize <= 0 {
                VaultTransferLog.mark("export.error", "stage=archiveFinish index=\(part.partIndex + 1) reason=missingOrEmptyArchive")
            }
            #endif
            guard archiveSize > 0 else {
                throw VaultExportError.failedToCreateBackupFile
            }

            let outputURL = try makeVaultURL(for: part, totalParts: plan.parts.count, in: exportDirectory)
            let preferredPartialOutputURL = outputURL.appendingPathExtension("partial")
            var encryptedPartialURL: URL?
            defer {
                // Safety net for partial file if encryptArchive or finalize throws
                if let encryptedPartialURL {
                    try? fileManager.removeItem(at: encryptedPartialURL)
                }
            }
            #if DEBUG
            VaultTransferLog.mark("export.encrypt.begin", "index=\(part.partIndex + 1) archiveBytes=\(archiveSize)")
            #endif
            encryptedPartialURL = try encryptArchive(
                archiveURL: archiveURL,
                preferredOutputURL: preferredPartialOutputURL,
                part: part,
                totalParts: plan.parts.count,
                password: password,
                onProgress: { completedBytes, totalBytes in
                    let partProgress = totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 1
                    let overall = progressBase(for: part, totalParts: plan.parts.count)
                        + progressSpan(totalParts: plan.parts.count) * (0.45 + partProgress * 0.50)
                    progressEmitter.emit(VaultTransferProgress(
                        phase: .encrypting,
                        currentPart: part.partIndex + 1,
                        totalParts: plan.parts.count,
                        currentBytes: completedBytes,
                        totalBytes: totalBytes,
                        message: String.localizedStringWithFormat(String(localized: "正在写入第 %1$lld / %2$lld 个备份文件"), part.partIndex + 1, plan.parts.count),
                        fractionCompleted: min(overall, 0.98)
                    ))
                }
            )

            guard let partialURL = encryptedPartialURL else {
                #if DEBUG
                VaultTransferLog.mark("export.error", "stage=postEncryptPartialMissing index=\(part.partIndex + 1)")
                #endif
                throw VaultExportError.failedToCreateBackupFile
            }
            #if DEBUG
            VaultTransferLog.mark("export.part.finalize.begin", "index=\(part.partIndex + 1) partialBytes=\(sourceFileSize(at: partialURL))")
            #endif
            do {
                try finalizeVaultPart(partialURL: partialURL, finalURL: outputURL, partIndex: part.partIndex)
            } catch {
                #if DEBUG
                VaultTransferLog.mark("export.error", "stage=finalizePartCall index=\(part.partIndex + 1) \(debugErrorDetails(error))")
                #endif
                throw error
            }
            encryptedPartialURL = nil

            #if DEBUG
            VaultTransferLog.mark("export.backupStore.save.begin", "index=\(part.partIndex + 1) bytes=\(sourceFileSize(at: outputURL))")
            #endif
            let savedURLs: [URL]
            do {
                savedURLs = try VaultBackupFileStore.shared.saveGeneratedVaultFiles([outputURL])
            } catch {
                #if DEBUG
                VaultTransferLog.mark("export.error", "stage=backupStoreSavePart index=\(part.partIndex + 1) \(debugErrorDetails(error))")
                #endif
                throw error
            }
            #if DEBUG
            let savedBytes = savedURLs.reduce(Int64(0)) { $0 + sourceFileSize(at: $1) }
            VaultTransferLog.mark("export.backupStore.save.finish", "index=\(part.partIndex + 1) savedCount=\(savedURLs.count) bytes=\(savedBytes)")
            #endif
            #if DEBUG
            VaultTransferLog.mark("export.result.append", "index=\(part.partIndex + 1) before=\(storedResultURLs.count) append=\(savedURLs.count)")
            #endif
            storedResultURLs.append(contentsOf: savedURLs)

            // .vault in temp was moved/copied to BackupFiles; remove the temp copy
            #if DEBUG
            VaultTransferLog.mark("export.part.cleanup.begin", "index=\(part.partIndex + 1)")
            #endif
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: archiveURL)
            #if DEBUG
            VaultTransferLog.mark("export.part.cleanup.finish", "index=\(part.partIndex + 1)")
            VaultTransferLog.mark("export.part.complete", "index=\(part.partIndex + 1) storedTotal=\(storedResultURLs.count)")
            if part.partIndex + 1 < plan.parts.count {
                VaultTransferLog.mark("export.nextPart.begin", "index=\(part.partIndex + 2)")
            }
            #endif
        }
        #if DEBUG
        VaultTransferLog.mark("export.complete", "fileCount=\(storedResultURLs.count)")
        #endif
        return storedResultURLs
    }

    @MainActor
    private func buildExportPlan(for space: VaultSpaceKind) throws -> VaultBackupPlan {
        let snapshot = try metadataStore.loadSnapshot(for: space)
        let albums = snapshot.albums
        let items = snapshot.items

        let itemRecords = try items.map { item -> VaultBackupItemPayload in
            let sourceURL = mediaStorage.fileURL(for: item.relativePath)
            guard fileManager.fileExists(atPath: sourceURL.path()) else {
                throw VaultExportError.missingSourceFile(item.relativePath)
            }
            let byteCount = try cryptoService.plaintextByteCount(forEncryptedFileAt: sourceURL)
            let record = VaultBackupItemRecord(
                id: item.id.uuidString,
                name: item.name,
                createdAt: item.createdAt,
                importedAt: item.importedAt,
                lastExportedAt: item.lastExportedAt,
                originalCapturedAt: item.originalCapturedAt,
                updatedAt: item.updatedAt,
                mediaKindRawValue: item.mediaKindRawValue,
                isInTrash: item.isInTrash,
                isArchived: item.isArchived,
                isStrongProtected: item.isStrongProtected,
                relativePath: item.relativePath,
                originalFilename: item.originalFilename,
                contentTypeIdentifier: item.contentTypeIdentifier,
                locationLatitude: item.locationLatitude,
                locationLongitude: item.locationLongitude,
                albumIDs: item.albums.map(\.id).map(\.uuidString)
            )
            let blobEntry = VaultBackupBlobEntry(
                relativePath: item.relativePath,
                sourceDomain: .media,
                byteCount: byteCount
            )
            return VaultBackupItemPayload(record: record, blobEntry: blobEntry)
        }

        let albumRecords = albums.map {
            VaultBackupAlbumRecord(
                id: $0.id.uuidString,
                name: $0.name,
                kindRawValue: $0.kindRawValue,
                coverItemIDRawValue: $0.coverItemIDRawValue,
                coverImageRelativePath: $0.coverImageRelativePath,
                coverSymbolName: $0.coverSymbolName,
                sortOptionRawValue: $0.sortOptionRawValue,
                customOrderedItemIDs: $0.customOrderedItemIDs,
                showsCover: $0.showsCover,
                libraryOrderIndex: $0.libraryOrderIndex
            )
        }

        var parts: [VaultBackupPartPlan] = []
        var currentPayloads: [VaultBackupItemPayload] = []
        var currentBytes: Int64 = 0

        func flushCurrentPart() {
            guard !currentPayloads.isEmpty else { return }
            let partIndex = parts.count
            let itemIDSet = Set(currentPayloads.map(\.record.id))
            let albumIDSet = Set(currentPayloads.flatMap(\.record.albumIDs))
            let partAlbums = albumRecords
                .filter { albumIDSet.contains($0.id) || isSystemAlbum(kindRawValue: $0.kindRawValue) }
                .map { album -> VaultBackupAlbumRecord in
                    VaultBackupAlbumRecord(
                        id: album.id,
                        name: album.name,
                        kindRawValue: album.kindRawValue,
                        coverItemIDRawValue: album.coverItemIDRawValue.flatMap { itemIDSet.contains($0) ? $0 : nil },
                        coverImageRelativePath: album.coverImageRelativePath,
                        coverSymbolName: album.coverSymbolName,
                        sortOptionRawValue: album.sortOptionRawValue,
                        customOrderedItemIDs: album.customOrderedItemIDs.filter { itemIDSet.contains($0) },
                        showsCover: album.showsCover,
                        libraryOrderIndex: album.libraryOrderIndex
                    )
                }
            let manifest = VaultBackupPartManifest(
                exportedAt: .now,
                spaceRawValue: space.rawValue,
                partIndex: partIndex,
                totalParts: 0,
                albums: partAlbums,
                items: currentPayloads.map(\.record),
                blobEntries: currentPayloads.map(\.blobEntry)
            )
            parts.append(VaultBackupPartPlan(partIndex: partIndex, manifest: manifest, estimatedPlaintextBytes: currentBytes))
            currentPayloads.removeAll(keepingCapacity: true)
            currentBytes = 0
        }

        for payload in itemRecords {
            let itemWouldExceedCount = currentPayloads.count >= maxItemsPerPart
            let itemWouldExceedBytes = !currentPayloads.isEmpty && currentBytes + payload.blobEntry.byteCount > targetPartBytes
            if itemWouldExceedCount || itemWouldExceedBytes {
                flushCurrentPart()
            }
            currentPayloads.append(payload)
            currentBytes += max(payload.blobEntry.byteCount, 1)
        }
        flushCurrentPart()

        let totalParts = max(parts.count, 1)
        let finalizedParts = parts.map { part in
            let manifest = VaultBackupPartManifest(
                exportedAt: part.manifest.exportedAt,
                spaceRawValue: part.manifest.spaceRawValue,
                partIndex: part.partIndex,
                totalParts: totalParts,
                albums: part.manifest.albums,
                items: part.manifest.items,
                blobEntries: part.manifest.blobEntries
            )
            return VaultBackupPartPlan(partIndex: part.partIndex, manifest: manifest, estimatedPlaintextBytes: part.estimatedPlaintextBytes)
        }

        #if DEBUG
        let itemCount = finalizedParts.reduce(0) { $0 + $1.manifest.items.count }
        let estimatedBytes = finalizedParts.reduce(Int64(0)) { $0 + $1.estimatedPlaintextBytes }
        VaultTransferLog.mark("export.plan.ready", "parts=\(finalizedParts.count) itemCount=\(itemCount) estimatedBytes=\(estimatedBytes)")
        #endif
        return VaultBackupPlan(parts: finalizedParts)
    }

    nonisolated private func writePlainArchive(
        part: VaultBackupPartPlan,
        sourceSpace: VaultSpaceKind,
        to archiveURL: URL,
        onProgress: ((_ completedBytes: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) throws {
        if fileManager.fileExists(atPath: archiveURL.path()) {
            try fileManager.removeItem(at: archiveURL)
        }
        guard fileManager.createFile(atPath: archiveURL.path(), contents: nil) else {
            throw VaultExportError.failedToCreateBackupFile
        }
        let outputHandle = try FileHandle(forWritingTo: archiveURL)
        defer {
            try? outputHandle.close()
        }

        try outputHandle.write(contentsOf: Self.archiveMagic)
        try outputHandle.write(contentsOf: data(from: Self.archiveVersion))
        let manifestData = try JSONEncoder.vaultBackupEncoder.encode(part.manifest)
        try outputHandle.write(contentsOf: data(from: UInt64(manifestData.count)))
        try outputHandle.write(contentsOf: manifestData)
        try outputHandle.write(contentsOf: data(from: UInt32(part.manifest.blobEntries.count)))

        #if DEBUG
        VaultTransferLog.mark("export.part.start", "index=\(part.partIndex + 1) total=\(part.manifest.totalParts) itemCount=\(part.manifest.items.count)")
        #endif

        let totalBytes = max(part.estimatedPlaintextBytes, 1)
        var completedBytes: Int64 = 0
        for (itemIndex, blobEntry) in part.manifest.blobEntries.enumerated() {
            try Task.checkCancellation()
            let pathData = Data(blobEntry.relativePath.utf8)
            try outputHandle.write(contentsOf: data(from: UInt32(pathData.count)))
            try outputHandle.write(contentsOf: pathData)
            try outputHandle.write(contentsOf: data(from: blobEntry.sourceDomain.rawValue))
            try outputHandle.write(contentsOf: data(from: UInt64(blobEntry.byteCount)))

            let sourceURL = mediaStorage.fileURL(for: blobEntry.relativePath)
            guard fileManager.fileExists(atPath: sourceURL.path()) else {
                throw VaultExportError.missingSourceFile(blobEntry.relativePath)
            }
            #if DEBUG
            let itemRecord = part.manifest.items.first(where: { $0.relativePath == blobEntry.relativePath })
            let kind = itemRecord?.mediaKindRawValue ?? "unknown"
            let secure = itemRecord?.isStrongProtected == true
            VaultTransferLog.mark("export.archive.item", "index=\(itemIndex + 1) total=\(part.manifest.blobEntries.count) kind=\(kind) secure=\(secure) bytes=\(blobEntry.byteCount)")
            #endif

            try cryptoService.streamPlaintextChunks(fromEncryptedFileAt: sourceURL, space: sourceSpace) { chunk in
                try Task.checkCancellation()
                let compressed = compressedArchivePayload(for: chunk)
                try outputHandle.write(contentsOf: data(from: compressed.codec.rawValue))
                try outputHandle.write(contentsOf: data(from: UInt32(chunk.count)))
                try outputHandle.write(contentsOf: data(from: UInt32(compressed.payload.count)))
                try outputHandle.write(contentsOf: compressed.payload)
                completedBytes += Int64(chunk.count)
                onProgress?(completedBytes, totalBytes)
            }
        }
    }

    nonisolated private func encryptArchive(
        archiveURL: URL,
        preferredOutputURL: URL,
        part: VaultBackupPartPlan,
        totalParts: Int,
        password: String,
        onProgress: ((_ completedBytes: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) throws -> URL {
        #if DEBUG
        VaultTransferLog.mark("export.encrypt.kdf.begin", "index=\(part.partIndex + 1) rounds=\(pbkdfRounds)")
        #endif
        let salt = randomData(count: 32)
        let exportKey = try deriveExportKey(password: password, salt: salt)
        #if DEBUG
        VaultTransferLog.mark("export.encrypt.kdf.done", "index=\(part.partIndex + 1)")
        #endif

        let archiveByteCount = sourceFileSize(at: archiveURL)
        let header = VaultBackupHeader(
            exportedAt: .now,
            appName: "PrivyGallery",
            formatVersion: 2,
            partIndex: part.partIndex,
            totalParts: totalParts,
            archiveEncoding: "chunked-lzfse-v1",
            kdf: .init(algorithm: "pbkdf2-sha256", rounds: pbkdfRounds, saltBase64: salt.base64EncodedString()),
            cipher: "aes-gcm-chunked-archive",
            chunkSize: vaultChunkSize,
            archiveByteCount: archiveByteCount
        )
        let headerData = try JSONEncoder.vaultBackupEncoder.encode(header)

        let inputHandle: FileHandle
        do {
            inputHandle = try FileHandle(forReadingFrom: archiveURL)
        } catch {
            #if DEBUG
            VaultTransferLog.mark("export.error", "stage=encryptOpenInput index=\(part.partIndex + 1) \(debugErrorDetails(error))")
            #endif
            throw error
        }
        defer { try? inputHandle.close() }

        let outputDirectory = preferredOutputURL.deletingLastPathComponent()
        #if DEBUG
        VaultTransferLog.mark("export.encrypt.partial.parent.exists", "index=\(part.partIndex + 1) exists=\(fileManager.fileExists(atPath: outputDirectory.path()))")
        #endif
        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            #if DEBUG
            VaultTransferLog.mark("export.error", "stage=createPartialParent index=\(part.partIndex + 1) \(debugErrorDetails(error))")
            #endif
            throw error
        }

        var output: PartialOutputHandle?
        var finishedSuccessfully = false
        defer {
            if !finishedSuccessfully, let output {
                try? fileManager.removeItem(at: output.url)
            }
        }
        #if DEBUG
        VaultTransferLog.mark(
            "export.encrypt.output.open.begin",
            "index=\(part.partIndex + 1) parentExists=\(fileManager.fileExists(atPath: outputDirectory.path())) parentItems=\(debugDirectoryItemCount(outputDirectory))"
        )
        #endif
        do {
            output = try openPartialOutputHandle(preferredOutputURL, partIndex: part.partIndex)
        } catch {
            #if DEBUG
            VaultTransferLog.mark(
                "export.error",
                "stage=encryptOpenOutput index=\(part.partIndex + 1) parentExists=\(fileManager.fileExists(atPath: outputDirectory.path())) parentItems=\(debugDirectoryItemCount(outputDirectory)) \(debugErrorDetails(error))"
            )
            #endif
            throw error
        }
        defer {
            if let output {
                try? output.handle.close()
            }
        }
        #if DEBUG
        VaultTransferLog.mark(
            "export.encrypt.output.open.done",
            "index=\(part.partIndex + 1) parentExists=\(fileManager.fileExists(atPath: outputDirectory.path())) partialExists=\(fileManager.fileExists(atPath: output?.url.path ?? "")) identity=\(debugIdentityComparison(for: output))"
        )
        #endif

        guard let openedOutput = output else {
            throw VaultExportError.failedToCreateBackupFile
        }
        let outputHandle = openedOutput.handle

        // Only unlink the large archive after both input and output file
        // handles are open. If output creation/opening fails, keeping the
        // archive on disk makes the failure recoverable and easier to inspect.
        #if DEBUG
        VaultTransferLog.mark("export.encrypt.archive.unlink.begin", "index=\(part.partIndex + 1) bytes=\(archiveByteCount)")
        #endif
        do {
            try fileManager.removeItem(at: archiveURL)
            #if DEBUG
            VaultTransferLog.mark("export.encrypt.archive.unlinked", "index=\(part.partIndex + 1) freedBytes=\(archiveByteCount)")
            #endif
        } catch {
            #if DEBUG
            VaultTransferLog.mark("export.error", "stage=encryptArchiveUnlink index=\(part.partIndex + 1) \(debugErrorDetails(error))")
            #endif
            // Continue: freeing the archive early is an optimization, not part
            // of the encrypted file format.
        }

        do {
            try outputHandle.write(contentsOf: Self.vaultMagic)
            try outputHandle.write(contentsOf: data(from: Self.vaultVersion))
            try outputHandle.write(contentsOf: data(from: UInt32(headerData.count)))
            try outputHandle.write(contentsOf: headerData)
        } catch {
            #if DEBUG
            VaultTransferLog.mark("export.error", "stage=encryptWriteHeader index=\(part.partIndex + 1) \(debugErrorDetails(error))")
            #endif
            throw error
        }
        #if DEBUG
        VaultTransferLog.mark("export.encrypt.header.written", "index=\(part.partIndex + 1) headerBytes=\(4 + 1 + 4 + headerData.count)")
        #endif

        var chunkIndex = 0
        var completedBytes: Int64 = 0
        let totalChunks = Int((archiveByteCount + Int64(vaultChunkSize) - 1) / Int64(vaultChunkSize))
        var chunkDone = false
        while !chunkDone {
            try autoreleasepool {
                try Task.checkCancellation()
                let chunk = (try inputHandle.read(upToCount: vaultChunkSize)) ?? Data()
                guard !chunk.isEmpty else {
                    chunkDone = true
                    return
                }

                let nonceData = randomData(count: 12)
                let nonce = try AES.GCM.Nonce(data: nonceData)
                let aad = authenticatedData(for: header, chunkIndex: chunkIndex)
                let sealed: AES.GCM.SealedBox
                do {
                    sealed = try AES.GCM.seal(chunk, using: exportKey, nonce: nonce, authenticating: aad)
                } catch {
                    #if DEBUG
                    VaultTransferLog.mark("export.error", "stage=encryptSeal index=\(part.partIndex + 1) chunk=\(chunkIndex) \(debugErrorDetails(error))")
                    #endif
                    throw error
                }

                let record = VaultBackupChunkRecord(
                    chunkIndex: chunkIndex,
                    plaintextLength: chunk.count,
                    ciphertextLength: sealed.ciphertext.count,
                    nonce: nonceData,
                    tag: sealed.tag
                )
                do {
                    try writeChunkRecord(record, ciphertext: sealed.ciphertext, to: outputHandle)
                } catch {
                    #if DEBUG
                    VaultTransferLog.mark("export.error", "stage=encryptWriteChunk index=\(part.partIndex + 1) chunk=\(chunkIndex) \(debugErrorDetails(error))")
                    #endif
                    throw error
                }

                #if DEBUG
                VaultTransferLog.mark("export.encrypt.chunk", "index=\(chunkIndex + 1) total=\(totalChunks) plaintextBytes=\(chunk.count) ciphertextBytes=\(sealed.ciphertext.count)")
                #endif

                completedBytes += Int64(chunk.count)
                chunkIndex += 1
                onProgress?(completedBytes, max(archiveByteCount, 1))
            }
        }

        do {
            try outputHandle.synchronize()
        } catch {
            #if DEBUG
            VaultTransferLog.mark("export.error", "stage=encryptSync index=\(part.partIndex + 1) \(debugErrorDetails(error))")
            #endif
            throw error
        }

        let outputDescriptor = openedOutput.descriptor
        if Darwin.fsync(outputDescriptor) != 0 {
            let code = errno
            #if DEBUG
            VaultTransferLog.mark(
                "export.error",
                "stage=encryptFsync index=\(part.partIndex + 1) errno=\(code) message=\(posixErrorMessage(code))"
            )
            #endif
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: posixErrorMessage(code)]
            )
        }

        let fdSizeBeforeClose = fileSize(forDescriptor: outputDescriptor)
        let pathSizeBeforeClose = sourceFileSize(at: openedOutput.url)
        #if DEBUG
        VaultTransferLog.mark(
            "export.encrypt.sync.done",
            "index=\(part.partIndex + 1) fdBytes=\(fdSizeBeforeClose) pathBytes=\(pathSizeBeforeClose) identity=\(debugIdentityComparison(for: openedOutput))"
        )
        #endif

        do {
            try outputHandle.close()
            output = nil
        } catch {
            #if DEBUG
            VaultTransferLog.mark("export.error", "stage=encryptCloseOutput index=\(part.partIndex + 1) \(debugErrorDetails(error))")
            #endif
            throw error
        }

        let fdSizeAfterClose = fileSize(forDescriptor: outputDescriptor)
        let partialSize = sourceFileSize(at: openedOutput.url)
        #if DEBUG
        VaultTransferLog.mark(
            "export.encrypt.finish",
            "index=\(part.partIndex + 1) chunks=\(chunkIndex) fdBytesBeforeClose=\(fdSizeBeforeClose) fdBytesAfterClose=\(fdSizeAfterClose) pathBytesBeforeClose=\(pathSizeBeforeClose) partialBytes=\(partialSize) identity=\(debugIdentityComparison(forURL: openedOutput.url, fdIdentity: openedOutput.identity))"
        )
        #endif
        guard partialSize > 0 else {
            #if DEBUG
            VaultTransferLog.mark(
                "export.error",
                "stage=encryptFinish index=\(part.partIndex + 1) reason=missingOrEmptyPartial fdBytesBeforeClose=\(fdSizeBeforeClose) fdBytesAfterClose=\(fdSizeAfterClose) pathBytesBeforeClose=\(pathSizeBeforeClose) bytes=\(partialSize) identity=\(debugIdentityComparison(forURL: openedOutput.url, fdIdentity: openedOutput.identity))"
            )
            #endif
            throw VaultExportError.failedToCreateBackupFile
        }
        finishedSuccessfully = true
        return openedOutput.url
    }

    nonisolated private func finalizeVaultPart(partialURL: URL, finalURL: URL, partIndex: Int) throws {
        let partialSize = sourceFileSize(at: partialURL)
        #if DEBUG
        VaultTransferLog.mark("export.part.partial.exists", "index=\(partIndex + 1) exists=\(hasFile(at: partialURL)) bytes=\(partialSize)")
        #endif
        guard partialSize > 0 else {
            #if DEBUG
            VaultTransferLog.mark("export.error", "stage=finalizePart index=\(partIndex + 1) reason=missingOrEmptyPartial")
            #endif
            throw VaultExportError.failedToCreateBackupFile
        }
        try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: finalURL.path()) {
            try fileManager.removeItem(at: finalURL)
        }
        #if DEBUG
        VaultTransferLog.mark("export.part.finalize.move", "index=\(partIndex + 1)")
        #endif
        try fileManager.moveItem(at: partialURL, to: finalURL)
        let finalSize = sourceFileSize(at: finalURL)
        #if DEBUG
        VaultTransferLog.mark("export.part.final.exists", "index=\(partIndex + 1) exists=\(hasFile(at: finalURL)) bytes=\(finalSize)")
        #endif
        guard finalSize > 0 else {
            #if DEBUG
            VaultTransferLog.mark("export.error", "stage=finalizePart index=\(partIndex + 1) reason=missingOrEmptyFinal")
            #endif
            throw VaultExportError.failedToCreateBackupFile
        }
        #if DEBUG
        VaultTransferLog.mark("export.part.protection.begin", "index=\(partIndex + 1)")
        #endif
        do {
            try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: finalURL.path())
            #if DEBUG
            VaultTransferLog.mark("export.part.protection.finish", "index=\(partIndex + 1)")
            #endif
        } catch {
            #if DEBUG
            VaultTransferLog.mark("export.error", "stage=finalizeProtection index=\(partIndex + 1) \(debugErrorDetails(error))")
            #endif
            // The .vault has already been fully written and verified. File
            // protection is desirable, but it should not turn a valid backup
            // into a failed export on devices/filesystems that reject the
            // attribute for a temporary location.
        }
        #if DEBUG
        VaultTransferLog.mark("export.part.finalize.finish", "index=\(partIndex + 1) bytes=\(sourceFileSize(at: finalURL))")
        #endif
    }

    nonisolated private struct PartialOutputHandle {
        let handle: FileHandle
        let descriptor: Int32
        let url: URL
        let identity: FileIdentity
    }

    nonisolated private struct FileIdentity {
        let device: UInt64
        let inode: UInt64
        let size: Int64
    }

    nonisolated private func openPartialOutputHandle(_ preferredOutputURL: URL, partIndex: Int) throws -> PartialOutputHandle {
        let parentURL = preferredOutputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        var template = Array(parentURL.appendingPathComponent(".\(preferredOutputURL.lastPathComponent).XXXXXX").path.utf8CString)
        #if DEBUG
        VaultTransferLog.mark("export.encrypt.partial.create.begin", "index=\(partIndex + 1) mode=mkstemp")
        #endif
        let descriptor = template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return mkstemp(baseAddress)
        }

        guard descriptor >= 0 else {
            let code = errno
            #if DEBUG
            VaultTransferLog.mark(
                "export.error",
                "stage=encryptOpenOutputPOSIX index=\(partIndex + 1) errno=\(code) message=\(posixErrorMessage(code))"
            )
            #endif
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: posixErrorMessage(code)]
            )
        }

        let actualPath = String(cString: template)
        let actualURL = URL(fileURLWithPath: actualPath)
        _ = actualPath.withCString { pointer in
            chmod(pointer, S_IRUSR | S_IWUSR)
        }
        guard let fdIdentity = fileIdentity(forDescriptor: descriptor) else {
            Darwin.close(descriptor)
            #if DEBUG
            VaultTransferLog.mark("export.error", "stage=partialIdentity index=\(partIndex + 1) reason=missingFdIdentity")
            #endif
            throw VaultExportError.failedToCreateBackupFile
        }
        #if DEBUG
        VaultTransferLog.mark(
            "export.encrypt.partial.create.result",
            "index=\(partIndex + 1) success=true exists=\(fileManager.fileExists(atPath: actualURL.path)) identity=\(debugIdentityComparison(forURL: actualURL, fdIdentity: fdIdentity))"
        )
        VaultTransferLog.mark("export.encrypt.output.open.posix", "index=\(partIndex + 1) descriptor=\(descriptor)")
        #endif
        return PartialOutputHandle(
            handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            descriptor: descriptor,
            url: actualURL,
            identity: fdIdentity
        )
    }

    nonisolated private func writeChunkRecord(_ record: VaultBackupChunkRecord, ciphertext: Data, to handle: FileHandle) throws {
        try handle.write(contentsOf: data(from: UInt32(record.chunkIndex)))
        try handle.write(contentsOf: data(from: UInt64(record.plaintextLength)))
        try handle.write(contentsOf: data(from: UInt64(record.ciphertextLength)))
        try handle.write(contentsOf: data(from: UInt32(record.nonce.count)))
        try handle.write(contentsOf: record.nonce)
        try handle.write(contentsOf: data(from: UInt32(record.tag.count)))
        try handle.write(contentsOf: record.tag)
        try handle.write(contentsOf: ciphertext)
    }

    nonisolated private func deriveExportKey(password: String, salt: Data) throws -> SymmetricKey {
        guard let passwordData = password.data(using: .utf8) else {
            throw VaultExportError.invalidPasswordEncoding
        }

        var derivedKey = Data(count: 32)
        let derivedKeyCount = derivedKey.count
        let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(pbkdfRounds),
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        derivedKeyCount
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw VaultExportError.failedToDeriveExportKey
        }
        return SymmetricKey(data: derivedKey)
    }

    nonisolated private func makeExportDirectory() throws -> URL {
        let exportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("VaultExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        return exportDirectory
    }

    nonisolated private func makeVaultURL(for part: VaultBackupPartPlan, totalParts: Int, in directory: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let base = "PrivyGallery Backup \(formatter.string(from: .now))"
        let fileName = totalParts == 1
            ? "\(base).vault"
            : "\(base) (\(part.partIndex + 1) of \(totalParts)).vault"
        return availableURL(for: fileName, in: directory)
    }

    nonisolated private func progressBase(for part: VaultBackupPartPlan, totalParts: Int) -> Double {
        guard totalParts > 0 else { return 0.05 }
        return 0.05 + (Double(part.partIndex) / Double(totalParts)) * 0.90
    }

    nonisolated private func progressSpan(totalParts: Int) -> Double {
        guard totalParts > 0 else { return 0.90 }
        return 0.90 / Double(totalParts)
    }

    nonisolated private func authenticatedData(for header: VaultBackupHeader, chunkIndex: Int) -> Data {
        Data("SVEX-v2|\(header.partIndex)|\(header.totalParts)|\(chunkIndex)|\(header.archiveByteCount)".utf8)
    }

    nonisolated private func compressedArchivePayload(for chunk: Data) -> VaultCompressedArchivePayload {
        guard !chunk.isEmpty else {
            return VaultCompressedArchivePayload(codec: .raw, payload: chunk)
        }

        let destinationCapacity = max(chunk.count + 1024, 1024)
        var compressed = Data(count: destinationCapacity)
        let compressedCount = compressed.withUnsafeMutableBytes { destinationBuffer in
            chunk.withUnsafeBytes { sourceBuffer in
                compression_encode_buffer(
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    destinationCapacity,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    chunk.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }

        guard compressedCount > 0, compressedCount < chunk.count else {
            #if DEBUG
            VaultTransferLog.mark("export.compress.chunk", "rawBytes=\(chunk.count) compressedBytes=\(chunk.count) usedCompressed=false")
            #endif
            return VaultCompressedArchivePayload(codec: .raw, payload: chunk)
        }

        compressed.removeSubrange(compressedCount..<compressed.count)
        #if DEBUG
        VaultTransferLog.mark("export.compress.chunk", "rawBytes=\(chunk.count) compressedBytes=\(compressedCount) usedCompressed=true")
        #endif
        return VaultCompressedArchivePayload(codec: .lzfse, payload: compressed)
    }

    nonisolated private func isSystemAlbum(kindRawValue: String) -> Bool {
        guard let kind = MediaAlbumKind(rawValue: kindRawValue) else { return false }
        return kind != .custom && kind != .secureCustom
    }

    nonisolated private func sourceFileSize(at url: URL) -> Int64 {
        fileIdentity(forURL: url)?.size ?? 0
    }

    nonisolated private func hasFile(at url: URL) -> Bool {
        fileIdentity(forURL: url) != nil
    }

    nonisolated private func fileSize(forDescriptor descriptor: Int32) -> Int64 {
        var fileStat = stat()
        guard fstat(descriptor, &fileStat) == 0 else {
            return -1
        }
        return Int64(fileStat.st_size)
    }

    nonisolated private func fileIdentity(forDescriptor descriptor: Int32) -> FileIdentity? {
        var fileStat = stat()
        guard fstat(descriptor, &fileStat) == 0 else {
            return nil
        }
        return FileIdentity(
            device: UInt64(fileStat.st_dev),
            inode: UInt64(fileStat.st_ino),
            size: Int64(fileStat.st_size)
        )
    }

    nonisolated private func fileIdentity(forURL url: URL) -> FileIdentity? {
        var fileStat = stat()
        guard url.path.withCString({ Darwin.lstat($0, &fileStat) }) == 0 else {
            return nil
        }
        return FileIdentity(
            device: UInt64(fileStat.st_dev),
            inode: UInt64(fileStat.st_ino),
            size: Int64(fileStat.st_size)
        )
    }

    nonisolated private func debugIdentityComparison(for output: PartialOutputHandle?) -> String {
        guard let output else { return "fd=missing path=missing match=false" }
        return debugIdentityComparison(forURL: output.url, fdIdentity: output.identity)
    }

    nonisolated private func debugIdentityComparison(forURL url: URL, fdIdentity: FileIdentity) -> String {
        guard let pathIdentity = fileIdentity(forURL: url) else {
            return "fdDev=\(fdIdentity.device) fdInode=\(fdIdentity.inode) fdSize=\(fdIdentity.size) path=missing match=false"
        }
        let matches = pathIdentity.device == fdIdentity.device && pathIdentity.inode == fdIdentity.inode
        return "fdDev=\(fdIdentity.device) fdInode=\(fdIdentity.inode) fdSize=\(fdIdentity.size) pathDev=\(pathIdentity.device) pathInode=\(pathIdentity.inode) pathSize=\(pathIdentity.size) match=\(matches)"
    }

    nonisolated private func posixErrorMessage(_ code: Int32) -> String {
        guard let message = strerror(code) else {
            return "Unknown POSIX error"
        }
        return sanitizedDebugMessage(String(cString: message))
    }

    nonisolated private func debugDirectoryItemCount(_ directoryURL: URL) -> Int {
        ((try? fileManager.contentsOfDirectory(atPath: directoryURL.path())) ?? []).count
    }

    nonisolated private func debugErrorDetails(_ error: Error) -> String {
        let nsError = error as NSError
        var components = [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "message=\(sanitizedDebugMessage(nsError.localizedDescription))"
        ]

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            components.append("underlyingDomain=\(underlying.domain)")
            components.append("underlyingCode=\(underlying.code)")
            components.append("underlyingMessage=\(sanitizedDebugMessage(underlying.localizedDescription))")
        }

        return components.joined(separator: " ")
    }

    nonisolated private func sanitizedDebugMessage(_ message: String) -> String {
        message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    nonisolated private func randomData(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        return data
    }

    nonisolated private func data<T>(from value: T) -> Data where T: FixedWidthInteger {
        var bigEndianValue = value.bigEndian
        return Data(bytes: &bigEndianValue, count: MemoryLayout<T>.size)
    }

    nonisolated private func data(from value: UInt8) -> Data {
        Data([value])
    }

    private func availableURL(for filename: String, in directoryURL: URL) -> URL {
        let baseURL = directoryURL.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: baseURL.path()) else {
            return baseURL
        }

        let baseName = baseURL.deletingPathExtension().lastPathComponent
        let pathExtension = baseURL.pathExtension
        var index = 2
        while true {
            let candidateName = "\(baseName) \(index).\(pathExtension)"
            let candidateURL = directoryURL.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path()) {
                return candidateURL
            }
            index += 1
        }
    }
}

nonisolated private struct VaultBackupPlan {
    let parts: [VaultBackupPartPlan]
}

nonisolated private struct VaultBackupPartPlan {
    let partIndex: Int
    let manifest: VaultBackupPartManifest
    let estimatedPlaintextBytes: Int64
}

nonisolated private struct VaultBackupItemPayload {
    let record: VaultBackupItemRecord
    let blobEntry: VaultBackupBlobEntry
}

nonisolated private struct VaultBackupHeader: Codable {
    let exportedAt: Date
    let appName: String
    let formatVersion: Int
    let partIndex: Int
    let totalParts: Int
    let archiveEncoding: String
    let kdf: VaultBackupKDFInfo
    let cipher: String
    let chunkSize: Int
    let archiveByteCount: Int64
}

nonisolated private struct VaultBackupKDFInfo: Codable {
    let algorithm: String
    let rounds: Int
    let saltBase64: String
}

nonisolated private struct VaultBackupPartManifest: Codable {
    let exportedAt: Date
    let spaceRawValue: String
    let partIndex: Int
    let totalParts: Int
    let albums: [VaultBackupAlbumRecord]
    let items: [VaultBackupItemRecord]
    let blobEntries: [VaultBackupBlobEntry]
}

nonisolated private struct VaultBackupAlbumRecord: Codable {
    let id: String
    let name: String
    let kindRawValue: String
    let coverItemIDRawValue: String?
    let coverImageRelativePath: String?
    let coverSymbolName: String?
    let sortOptionRawValue: String
    let customOrderedItemIDs: [String]
    let showsCover: Bool
    let libraryOrderIndex: Int
}

nonisolated private struct VaultBackupItemRecord: Codable {
    let id: String
    let name: String
    let createdAt: Date
    let importedAt: Date
    let lastExportedAt: Date?
    let originalCapturedAt: Date?
    let updatedAt: Date
    let mediaKindRawValue: String
    let isInTrash: Bool
    let isArchived: Bool
    let isStrongProtected: Bool
    let relativePath: String
    let originalFilename: String
    let contentTypeIdentifier: String
    let locationLatitude: Double?
    let locationLongitude: Double?
    let albumIDs: [String]
}

nonisolated private struct VaultBackupBlobEntry: Codable {
    let relativePath: String
    let sourceDomain: VaultBackupSourceDomain
    let byteCount: Int64
}

nonisolated private enum VaultBackupSourceDomain: UInt8, Codable {
    case media = 1
}

nonisolated private struct VaultBackupChunkRecord {
    let chunkIndex: Int
    let plaintextLength: Int
    let ciphertextLength: Int
    let nonce: Data
    let tag: Data
}

nonisolated private struct VaultCompressedArchivePayload {
    let codec: VaultArchiveChunkCodec
    let payload: Data
}

nonisolated private enum VaultArchiveChunkCodec: UInt8 {
    case raw = 0
    case lzfse = 1
}

nonisolated private extension JSONEncoder {
    static var vaultBackupEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
