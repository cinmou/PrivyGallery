import Foundation

/// 记录导出 / 导入过程中的“半成品”路径。
/// 如果应用在处理中意外退出、崩溃或被系统杀掉，下次启动时会优先清理这些残留。
nonisolated final class BackupOperationRecoveryService: @unchecked Sendable {
    static let shared = BackupOperationRecoveryService()

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.securityfolder.backup-recovery")

    private init() {}

    func beginExport(partialArchiveURL: URL) {
        let record = BackupOperationRecord(
            kind: .export,
            phase: .writingArchive,
            cleanupPaths: [partialArchiveURL.path()],
            startedAt: .now
        )
        persist(record)
    }

    func beginImport(stagingDirectoryURL: URL) {
        let record = BackupOperationRecord(
            kind: .importOperation,
            phase: .restoringFiles,
            cleanupPaths: [stagingDirectoryURL.path()],
            startedAt: .now
        )
        persist(record)
    }

    func registerImportedFileForCleanup(_ fileURL: URL) {
        queue.sync {
            guard var record = loadRecord(), record.kind == .importOperation else { return }
            if !record.cleanupPaths.contains(fileURL.path()) {
                record.cleanupPaths.append(fileURL.path())
                persist(record)
            }
        }
    }

    func markImportEnteringMetadataSave() {
        queue.sync {
            guard var record = loadRecord(), record.kind == .importOperation else { return }
            record.phase = .savingMetadata
            persist(record)
        }
    }

    func complete() {
        queue.sync {
            removeRecord()
            UserDefaults.standard.removeObject(forKey: AppSettingsKey.lastBackupRecoveryNotice)
        }
    }

    func abortAndCleanup() {
        queue.sync {
            guard let record = loadRecord() else { return }
            cleanup(paths: record.cleanupPaths)
            removeRecord()
        }
    }

    /// 启动时调用。会清理明确安全的半成品，并返回一条适合展示给用户的说明。
    func recoverIfNeeded() -> String? {
        queue.sync {
            cleanupStaleTemporaryDirectories()

            guard let record = loadRecord() else { return nil }

            // 如果恢复记录指向的半成品已经不存在，说明这次操作大概率已经成功收尾，
            // 或者残留已经被系统/上次清理移除，这里静默丢弃旧记录即可。
            if shouldSilentlyDiscard(record) {
                removeRecord()
                return nil
            }

            switch (record.kind, record.phase) {
            case (.export, _), (.importOperation, .restoringFiles):
                cleanup(paths: record.cleanupPaths)
                removeRecord()
                return nil

            case (.importOperation, .savingMetadata):
                // 当前实现里只有在 `restoreMedia` 已经成功写回元数据后才会进入这个阶段，
                // 因此这里更像是“成功后未及时清理恢复记录”，不需要再打扰用户。
                removeRecord()
                return nil

            case (.importOperation, .writingArchive):
                cleanup(paths: record.cleanupPaths)
                removeRecord()
                return nil
            }
        }
    }

    private func cleanupStaleTemporaryDirectories() {
        let temporaryRoot = fileManager.temporaryDirectory
        let staleDirectories = [
            temporaryRoot.appendingPathComponent("VaultExports", isDirectory: true),
            temporaryRoot.appendingPathComponent("VaultImports", isDirectory: true)
        ]

        staleDirectories.forEach { directoryURL in
            guard fileManager.fileExists(atPath: directoryURL.path()) else { return }
            let contents = (try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? []
            for url in contents where url.lastPathComponent.hasSuffix(".partial") || directoryURL.lastPathComponent == "VaultImports" {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func cleanup(paths: [String]) {
        for path in Set(paths).sorted(by: { $0.count > $1.count }) {
            try? fileManager.removeItem(atPath: path)
        }
    }

    private func shouldSilentlyDiscard(_ record: BackupOperationRecord) -> Bool {
        switch (record.kind, record.phase) {
        case (.importOperation, .savingMetadata):
            return true
        case (.export, _), (.importOperation, .restoringFiles), (.importOperation, .writingArchive):
            return record.cleanupPaths.allSatisfy { !fileManager.fileExists(atPath: $0) }
        }
    }

    private var recordURL: URL? {
        guard let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directoryURL = applicationSupportURL.appendingPathComponent("BackupRecovery", isDirectory: true)
        if !fileManager.fileExists(atPath: directoryURL.path()) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        return directoryURL.appendingPathComponent("active-operation.json")
    }

    private func persist(_ record: BackupOperationRecord) {
        guard let recordURL else { return }
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: recordURL, options: .atomic)
        }
    }

    private func loadRecord() -> BackupOperationRecord? {
        guard let recordURL, let data = try? Data(contentsOf: recordURL) else { return nil }
        return try? JSONDecoder().decode(BackupOperationRecord.self, from: data)
    }

    private func removeRecord() {
        guard let recordURL, fileManager.fileExists(atPath: recordURL.path()) else { return }
        try? fileManager.removeItem(at: recordURL)
    }
}

nonisolated private struct BackupOperationRecord: Codable {
    let kind: BackupOperationKind
    var phase: BackupOperationPhase
    var cleanupPaths: [String]
    let startedAt: Date
}

nonisolated private enum BackupOperationKind: String, Codable {
    case export
    case importOperation
}

nonisolated private enum BackupOperationPhase: String, Codable {
    case writingArchive
    case restoringFiles
    case savingMetadata
}
