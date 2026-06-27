import Foundation
import Darwin

nonisolated struct StoredVaultBackupFile: Identifiable, Hashable {
    let url: URL
    let fileName: String
    let byteCount: Int64
    let createdAt: Date

    var id: String { url.path }
}

#if DEBUG
nonisolated enum VaultBackupFilesDebugLog {
    static func mark(_ action: String, _ details: String = "") {
        let suffix = details.isEmpty ? "" : " \(details)"
        print("[VaultBackupFiles] \(action)\(suffix)")
    }

    static func errorDetails(_ error: Error) -> String {
        let nsError = error as NSError
        var components = [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "message=\(sanitize(nsError.localizedDescription))"
        ]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            components.append("underlyingDomain=\(underlying.domain)")
            components.append("underlyingCode=\(underlying.code)")
            components.append("underlyingMessage=\(sanitize(underlying.localizedDescription))")
        }
        return components.joined(separator: " ")
    }

    static func sanitize(_ message: String) -> String {
        message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
#endif

nonisolated final class VaultBackupFileStore: @unchecked Sendable {
    static let shared = VaultBackupFileStore()

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func backupFilesDirectory() throws -> URL {
        guard let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw VaultExportError.failedToCreateBackupFile
        }

        let directoryURL = applicationSupportURL.appendingPathComponent("BackupFiles", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directoryURL.path())
        return directoryURL
    }

    func listBackupFiles() throws -> [StoredVaultBackupFile] {
        let directoryURL = try backupFilesDirectory()
        #if DEBUG
        VaultBackupFilesDebugLog.mark("list.begin")
        #endif
        let resourceKeys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        let files: [StoredVaultBackupFile] = urls
            .filter { $0.pathExtension.lowercased() == "vault" }
            .compactMap { url -> StoredVaultBackupFile? in
                guard let values = try? url.resourceValues(forKeys: resourceKeys),
                      values.isRegularFile == true
                else {
                    return nil
                }

                return StoredVaultBackupFile(
                    url: url,
                    fileName: url.lastPathComponent,
                    byteCount: Int64(values.fileSize ?? 0),
                    createdAt: values.creationDate ?? values.contentModificationDate ?? .distantPast
                )
            }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
                }
                return lhs.createdAt > rhs.createdAt
            }
        #if DEBUG
        VaultBackupFilesDebugLog.mark("list.finish", "fileCount=\(files.count)")
        files.enumerated().forEach { index, file in
            VaultBackupFilesDebugLog.mark(
                "list.file",
                "index=\(index + 1) name=\(file.fileName) ext=\(file.url.pathExtension) exists=\(hasFile(at: file.url)) bytes=\(sourceFileSize(at: file.url)) insideBackupFiles=\(isInsideBackupDirectory(file.url, backupDirectory: directoryURL))"
            )
        }
        #endif
        return files
    }

    func saveGeneratedVaultFiles(_ urls: [URL]) throws -> [URL] {
        let directoryURL = try backupFilesDirectory()
        var storedURLs: [URL] = []

        do {
            for (index, sourceURL) in urls.enumerated() {
                let sourceBytes = sourceFileSize(at: sourceURL)
                #if DEBUG
                VaultTransferLog.mark("export.backupStore.source.check", "index=\(index + 1) exists=\(hasFile(at: sourceURL)) bytes=\(sourceBytes)")
                #endif
                guard sourceBytes > 0 else {
                    #if DEBUG
                    VaultTransferLog.mark("export.error", "stage=backupStoreSource index=\(index + 1) reason=missingOrEmptySource bytes=\(sourceBytes)")
                    #endif
                    throw VaultExportError.failedToCreateBackupFile
                }

                let destinationURL = uniqueDestinationURL(
                    preferredName: sourceURL.lastPathComponent,
                    in: directoryURL
                )
                if fileManager.fileExists(atPath: destinationURL.path()) {
                    try fileManager.removeItem(at: destinationURL)
                }

                try moveOrCopyGeneratedVault(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceBytes: sourceBytes,
                    index: index
                )

                let storedBytes = sourceFileSize(at: destinationURL)
                guard storedBytes > 0 else {
                    #if DEBUG
                    VaultTransferLog.mark("export.error", "stage=backupStoreStored index=\(index + 1) reason=missingOrEmptyDestination bytes=\(storedBytes)")
                    #endif
                    throw VaultExportError.failedToCreateBackupFile
                }
                applyStoredFileProtectionIfPossible(destinationURL, index: index, bytes: storedBytes)
                storedURLs.append(destinationURL)
            }
        } catch {
            #if DEBUG
            VaultTransferLog.mark("export.error", "stage=backupStoreSave \(debugErrorDetails(error))")
            #endif
            storedURLs.forEach { try? fileManager.removeItem(at: $0) }
            throw error
        }

        return storedURLs
    }

    private func moveOrCopyGeneratedVault(
        sourceURL: URL,
        destinationURL: URL,
        sourceBytes: Int64,
        index: Int
    ) throws {
        #if DEBUG
        VaultTransferLog.mark("export.backupStore.move.begin", "index=\(index + 1) bytes=\(sourceBytes)")
        #endif
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            #if DEBUG
            VaultTransferLog.mark("export.backupStore.move.finish", "index=\(index + 1) bytes=\(sourceFileSize(at: destinationURL))")
            #endif
            return
        } catch {
            let destinationBytes = sourceFileSize(at: destinationURL)
            #if DEBUG
            VaultTransferLog.mark("export.error", "stage=backupStoreMove index=\(index + 1) destinationBytes=\(destinationBytes) \(debugErrorDetails(error))")
            #endif

            // Some filesystem APIs can report an error after the move has
            // already materialized the destination. Once the BackupFiles copy
            // is present and non-empty, the vanished source is expected and
            // must not be treated as a failed export.
            if destinationBytes > 0 {
                #if DEBUG
                VaultTransferLog.mark("export.backupStore.move.acceptExistingDestination", "index=\(index + 1) bytes=\(destinationBytes)")
                #endif
                return
            }

            let remainingSourceBytes = sourceFileSize(at: sourceURL)
            guard remainingSourceBytes > 0 else {
                throw error
            }

            #if DEBUG
            VaultTransferLog.mark("export.backupStore.copy.begin", "index=\(index + 1) bytes=\(remainingSourceBytes)")
            #endif
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try? fileManager.removeItem(at: sourceURL)
            #if DEBUG
            VaultTransferLog.mark("export.backupStore.copy.finish", "index=\(index + 1) bytes=\(sourceFileSize(at: destinationURL))")
            #endif
        }
    }

    private func applyStoredFileProtectionIfPossible(_ url: URL, index: Int, bytes: Int64) {
        #if DEBUG
        VaultTransferLog.mark("export.backupStore.protection.begin", "index=\(index + 1) bytes=\(bytes)")
        #endif
        do {
            try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path())
            #if DEBUG
            VaultTransferLog.mark("export.backupStore.protection.finish", "index=\(index + 1)")
            #endif
        } catch {
            #if DEBUG
            VaultTransferLog.mark("export.error", "stage=backupStoreProtection index=\(index + 1) bytes=\(sourceFileSize(at: url)) \(debugErrorDetails(error))")
            #endif
            // A valid .vault in BackupFiles must remain export-successful even
            // if the platform rejects a protection attribute update.
        }
    }

    func deleteBackupFiles(_ files: [StoredVaultBackupFile]) throws {
        try deleteBackupFileURLs(files.map(\.url))
    }

    func deleteBackupFileURLs(_ urls: [URL]) throws {
        let backupDirectory = try backupFilesDirectory().standardizedFileURL
        #if DEBUG
        VaultBackupFilesDebugLog.mark("delete.begin", "fileCount=\(urls.count)")
        #endif
        for url in urls {
            let standardizedURL = url.standardizedFileURL
            let insideBackupDirectory = isInsideBackupDirectory(standardizedURL, backupDirectory: backupDirectory)
            #if DEBUG
            VaultBackupFilesDebugLog.mark(
                "delete.file.check",
                "name=\(standardizedURL.lastPathComponent) ext=\(standardizedURL.pathExtension) exists=\(hasFile(at: standardizedURL)) bytes=\(sourceFileSize(at: standardizedURL)) insideBackupFiles=\(insideBackupDirectory)"
            )
            #endif
            guard standardizedURL.path.hasPrefix(backupDirectory.path + "/"),
                  standardizedURL.pathExtension.lowercased() == "vault"
            else {
                #if DEBUG
                VaultBackupFilesDebugLog.mark("delete.file.skip", "name=\(standardizedURL.lastPathComponent) insideBackupFiles=\(insideBackupDirectory) ext=\(standardizedURL.pathExtension)")
                #endif
                continue
            }

            if hasFile(at: standardizedURL) {
                do {
                    try fileManager.removeItem(at: standardizedURL)
                    #if DEBUG
                    VaultBackupFilesDebugLog.mark("delete.file.finish", "name=\(standardizedURL.lastPathComponent) deletionSucceeded=\(!hasFile(at: standardizedURL))")
                    #endif
                } catch {
                    #if DEBUG
                    VaultBackupFilesDebugLog.mark("delete.file.error", "name=\(standardizedURL.lastPathComponent) \(VaultBackupFilesDebugLog.errorDetails(error))")
                    #endif
                    throw error
                }
            } else {
                #if DEBUG
                VaultBackupFilesDebugLog.mark("delete.file.missing", "name=\(standardizedURL.lastPathComponent)")
                #endif
            }
        }
        #if DEBUG
        VaultBackupFilesDebugLog.mark("delete.finish", "fileCount=\(urls.count)")
        #endif
    }

    private func uniqueDestinationURL(preferredName: String, in directoryURL: URL) -> URL {
        let sanitizedName = preferredName.isEmpty ? "PrivyGallery Backup.vault" : preferredName
        let baseURL = directoryURL.appendingPathComponent(sanitizedName)
        guard fileManager.fileExists(atPath: baseURL.path()) else {
            return baseURL
        }

        let nameWithoutExtension = baseURL.deletingPathExtension().lastPathComponent
        let pathExtension = baseURL.pathExtension
        var suffix = 2
        while true {
            let candidateName = pathExtension.isEmpty
                ? "\(nameWithoutExtension) \(suffix)"
                : "\(nameWithoutExtension) \(suffix).\(pathExtension)"
            let candidateURL = directoryURL.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path()) {
                return candidateURL
            }
            suffix += 1
        }
    }

    private func sourceFileSize(at url: URL) -> Int64 {
        fileIdentity(for: url)?.size ?? 0
    }

    private func hasFile(at url: URL) -> Bool {
        fileIdentity(for: url) != nil
    }

    private func isInsideBackupDirectory(_ url: URL, backupDirectory: URL) -> Bool {
        let backupPath = backupDirectory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        return filePath.hasPrefix(backupPath + "/")
    }

    private func fileIdentity(for url: URL) -> (device: UInt64, inode: UInt64, size: Int64)? {
        var fileStat = stat()
        guard url.path.withCString({ Darwin.lstat($0, &fileStat) }) == 0 else {
            return nil
        }
        return (
            UInt64(fileStat.st_dev),
            UInt64(fileStat.st_ino),
            Int64(fileStat.st_size)
        )
    }

    private func debugErrorDetails(_ error: Error) -> String {
        let nsError = error as NSError
        var components = [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "message=\(nsError.localizedDescription.replacingOccurrences(of: "\n", with: " "))"
        ]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            components.append("underlyingDomain=\(underlying.domain)")
            components.append("underlyingCode=\(underlying.code)")
            components.append("underlyingMessage=\(underlying.localizedDescription.replacingOccurrences(of: "\n", with: " "))")
        }
        return components.joined(separator: " ")
    }
}
