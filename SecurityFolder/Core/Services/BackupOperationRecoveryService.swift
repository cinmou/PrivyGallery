import Foundation

/// 记录导出 / 导入过程中的“半成品”路径。
/// 如果应用在处理中意外退出、崩溃或被系统杀掉，下次启动时会优先清理这些残留。
nonisolated final class BackupOperationRecoveryService: @unchecked Sendable {
    static let shared = BackupOperationRecoveryService()

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.securityfolder.backup-recovery")
    private var cachedRecord: BackupOperationRecord?

    private init() {}

    func beginExport(partialArchiveURL: URL) {
        queue.sync {
            let record = BackupOperationRecord(
                kind: .export,
                phase: .writingArchive,
                cleanupPaths: [partialArchiveURL.path()],
                startedAt: .now
            )
            removeCleanupLog()
            persist(record)
        }
    }

    func beginImport(stagingDirectoryURL: URL) {
        queue.sync {
            let record = BackupOperationRecord(
                kind: .importOperation,
                phase: .restoringFiles,
                cleanupPaths: [stagingDirectoryURL.path()],
                startedAt: .now
            )
            removeCleanupLog()
            persist(record)
        }
    }

    func registerExportedFilesForCleanup(_ fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        queue.sync {
            guard let record = loadRecord(), record.kind == .export else { return }
            appendCleanupPaths(fileURLs.map { $0.path() })
        }
    }

    func registerImportedFileForCleanup(_ fileURL: URL) {
        queue.sync {
            guard let record = loadRecord(), record.kind == .importOperation else { return }
            appendCleanupPaths([fileURL.path()])
        }
    }

    func markImportEnteringMetadataSave() {
        queue.sync {
            guard var record = loadRecord(), record.kind == .importOperation else { return }
            record.phase = .savingMetadata
            persist(record)
        }
    }

    func revertImportToRestoringFiles() {
        queue.sync {
            guard var record = loadRecord(), record.kind == .importOperation else { return }
            record.phase = .restoringFiles
            persist(record)
        }
    }

    func complete() {
        queue.sync {
            removeRecord()
            removeCleanupLog()
            UserDefaults.standard.removeObject(forKey: AppSettingsKey.lastBackupRecoveryNotice)
        }
    }

    func abortAndCleanup() {
        queue.sync {
            guard let record = loadRecord() else {
                removeCleanupLog()
                return
            }
            cleanup(paths: allCleanupPaths(for: record))
            removeRecord()
            removeCleanupLog()
        }
    }

    /// 启动时调用。会清理明确安全的半成品，并返回一条适合展示给用户的说明。
    func recoverIfNeeded() -> String? {
        queue.sync {
            cleanupStaleTemporaryDirectories()

            guard let record = loadRecord() else {
                removeCleanupLog()
                return nil
            }
            let trackedPaths = allCleanupPaths(for: record)

            // 如果恢复记录指向的半成品已经不存在，说明这次操作大概率已经成功收尾，
            // 或者残留已经被系统/上次清理移除，这里静默丢弃旧记录即可。
            if shouldSilentlyDiscard(record, trackedPaths: trackedPaths) {
                removeRecord()
                removeCleanupLog()
                return nil
            }

            switch (record.kind, record.phase) {
            case (.export, _), (.importOperation, .restoringFiles):
                cleanup(paths: trackedPaths)
                removeRecord()
                removeCleanupLog()
                return nil

            case (.importOperation, .savingMetadata):
                // 当前实现里只有在准备或完成写回元数据后才会进入这个阶段，
                // 若异常中断后已进入该阶段，保留已落盘媒体文件并清理恢复记录。
                removeRecord()
                removeCleanupLog()
                return nil

            case (.importOperation, .writingArchive):
                cleanup(paths: trackedPaths)
                removeRecord()
                removeCleanupLog()
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

    private func shouldSilentlyDiscard(_ record: BackupOperationRecord, trackedPaths: [String]) -> Bool {
        switch (record.kind, record.phase) {
        case (.importOperation, .savingMetadata):
            return true
        case (.export, _), (.importOperation, .restoringFiles), (.importOperation, .writingArchive):
            return trackedPaths.allSatisfy { !fileManager.fileExists(atPath: $0) }
        }
    }

    private var recoveryDirectoryURL: URL? {
        guard let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directoryURL = applicationSupportURL.appendingPathComponent("BackupRecovery", isDirectory: true)
        if !fileManager.fileExists(atPath: directoryURL.path()) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        return directoryURL
    }

    private var recordURL: URL? {
        recoveryDirectoryURL?.appendingPathComponent("active-operation.json")
    }

    private var cleanupLogURL: URL? {
        recoveryDirectoryURL?.appendingPathComponent("cleanup-paths.log")
    }

    private func persist(_ record: BackupOperationRecord) {
        cachedRecord = record
        guard let recordURL else { return }
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: recordURL, options: .atomic)
        }
    }

    private func loadRecord() -> BackupOperationRecord? {
        if let cachedRecord {
            return cachedRecord
        }
        guard let recordURL, let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(BackupOperationRecord.self, from: data) else {
            return nil
        }
        cachedRecord = record
        return record
    }

    private func removeRecord() {
        cachedRecord = nil
        guard let recordURL, fileManager.fileExists(atPath: recordURL.path()) else { return }
        try? fileManager.removeItem(at: recordURL)
    }

    private func appendCleanupPaths(_ paths: [String]) {
        guard let cleanupLogURL else { return }
        let payload = paths.joined(separator: "\n") + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        if !fileManager.fileExists(atPath: cleanupLogURL.path()) {
            try? data.write(to: cleanupLogURL, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: cleanupLogURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func allCleanupPaths(for record: BackupOperationRecord) -> [String] {
        var paths = record.cleanupPaths
        if let cleanupLogURL,
           let content = try? String(contentsOf: cleanupLogURL, encoding: .utf8) {
            let logged = content.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            paths.append(contentsOf: logged)
        }
        return paths
    }

    private func removeCleanupLog() {
        guard let cleanupLogURL, fileManager.fileExists(atPath: cleanupLogURL.path()) else { return }
        try? fileManager.removeItem(at: cleanupLogURL)
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
