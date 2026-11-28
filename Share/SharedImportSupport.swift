import Darwin
import Foundation
import UniformTypeIdentifiers

enum SharedImportConstants {
    static let appGroupIdentifier = "group.com.cinmouice.MediaVault"
    static let freeMediaLimit = 20
    static let shareExtensionBatchLimit = 10
}

enum SharedImportSpace: String, Codable, CaseIterable, Identifiable {
    case spaceA
    case spaceB

    var id: String { rawValue }
}

struct SharedImportAppState: Codable {
    var currentTierRawValue: Int
    var spaceACount: Int
    var spaceBCount: Int
    var isSpaceBConfigured: Bool
    var spaceADisplayName: String
    var spaceBDisplayName: String

    static let fallback = SharedImportAppState(
        currentTierRawValue: 0,
        spaceACount: 0,
        spaceBCount: 0,
        isSpaceBConfigured: false,
        spaceADisplayName: String(localized: "主要空间"),
        spaceBDisplayName: String(localized: "副空间")
    )

    var isFullMember: Bool {
        currentTierRawValue >= 1
    }

    func count(for space: SharedImportSpace) -> Int {
        switch space {
        case .spaceA: return spaceACount
        case .spaceB: return spaceBCount
        }
    }

    func displayName(for space: SharedImportSpace) -> String {
        switch space {
        case .spaceA: return spaceADisplayName
        case .spaceB: return spaceBDisplayName
        }
    }

    var availableSpaces: [SharedImportSpace] {
        isSpaceBConfigured ? [.spaceA, .spaceB] : [.spaceA]
    }

    func canUse(_ space: SharedImportSpace) -> Bool {
        availableSpaces.contains(space)
    }
}

struct SharedImportQueueEntry: Codable, Identifiable {
    let id: UUID
    let spaceRawValue: String
    let relativePath: String
    let companionRelativePath: String?
    let originalFilename: String
    let contentTypeIdentifier: String
    let createdAt: Date

    init(
        id: UUID,
        spaceRawValue: String,
        relativePath: String,
        companionRelativePath: String? = nil,
        originalFilename: String,
        contentTypeIdentifier: String,
        createdAt: Date
    ) {
        self.id = id
        self.spaceRawValue = spaceRawValue
        self.relativePath = relativePath
        self.companionRelativePath = companionRelativePath
        self.originalFilename = originalFilename
        self.contentTypeIdentifier = contentTypeIdentifier
        self.createdAt = createdAt
    }
}

enum SharedImportError: LocalizedError {
    case appGroupUnavailable
    case unsupportedType
    case tooManyItems(limit: Int)
    case freeLimitExceeded(limit: Int)
    case noReadableItems
    case unavailableSpace

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return String(localized: "共享存储不可用，请检查 App Groups 配置。")
        case .unsupportedType:
            return String(localized: "只能接收照片和视频。")
        case let .tooManyItems(limit):
            return String.localizedStringWithFormat(String(localized: "一次最多只能导入 %lld 张照片或视频。"), Int64(limit))
        case let .freeLimitExceeded(limit):
            return String.localizedStringWithFormat(String(localized: "普通用户最多保存 %lld 个照片和视频，请开通会员后继续导入。"), Int64(limit))
        case .noReadableItems:
            return String(localized: "没有读取到可导入的照片或视频。")
        case .unavailableSpace:
            return String(localized: "第二空间尚未创建，不能保存到第二空间。")
        }
    }
}

final class SharedImportStore {
    static let shared = SharedImportStore()

    private let fileManager = FileManager.default

    private init() {}

    var appState: SharedImportAppState {
        get {
            guard let data = defaults?.data(forKey: Keys.appState),
                  let state = try? JSONDecoder.sharedImportDecoder.decode(SharedImportAppState.self, from: data) else {
                return .fallback
            }
            return state
        }
        set {
            guard let data = try? JSONEncoder.sharedImportEncoder.encode(newValue) else { return }
            defaults?.set(data, forKey: Keys.appState)
        }
    }

    var pendingEntries: [SharedImportQueueEntry] {
        withQueueLock {
            loadEntriesUnlocked()
        } ?? []
    }

    func validateCanAccept(itemCount: Int, into space: SharedImportSpace) throws {
        guard itemCount > 0 else {
            throw SharedImportError.noReadableItems
        }
        guard itemCount <= SharedImportConstants.shareExtensionBatchLimit else {
            throw SharedImportError.tooManyItems(limit: SharedImportConstants.shareExtensionBatchLimit)
        }

        let state = appState
        guard state.canUse(space) else {
            throw SharedImportError.unavailableSpace
        }

        if !state.isFullMember {
            // Count across both spaces so that a free user who has items split
            // between space A and space B cannot exceed 20 total by using the
            // share extension into a space that still has headroom individually.
            let existingCount = state.spaceACount + state.spaceBCount
            guard existingCount < SharedImportConstants.freeMediaLimit,
                  existingCount + itemCount <= SharedImportConstants.freeMediaLimit else {
                throw SharedImportError.freeLimitExceeded(limit: SharedImportConstants.freeMediaLimit)
            }
        }
    }

    func enqueueFile(
        at sourceURL: URL,
        originalFilename: String,
        contentType: UTType,
        space: SharedImportSpace,
        companionFileURL: URL? = nil
    ) throws {
        guard contentType.conforms(to: .image) || contentType.conforms(to: .movie) else {
            throw SharedImportError.unsupportedType
        }
        guard appState.canUse(space) else {
            throw SharedImportError.unavailableSpace
        }

        let id = UUID()
        let fileExtension = resolvedFileExtension(for: contentType, originalFilename: originalFilename)
        let storedFilename = "\(id.uuidString).\(fileExtension)"
        let destinationURL = try filesDirectory().appendingPathComponent(storedFilename, isDirectory: false)

        if fileManager.fileExists(atPath: destinationURL.path()) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destinationURL.path()
        )

        var storedCompanionFilename: String?
        var companionDestinationURL: URL?
        if let companionFileURL {
            let companionExt = resolvedFileExtension(for: .quickTimeMovie, originalFilename: companionFileURL.lastPathComponent)
            let companionName = "\(id.uuidString)-companion.\(companionExt)"
            let companionDest = try filesDirectory().appendingPathComponent(companionName, isDirectory: false)
            if fileManager.fileExists(atPath: companionDest.path()) {
                try fileManager.removeItem(at: companionDest)
            }
            do {
                try fileManager.copyItem(at: companionFileURL, to: companionDest)
                try? fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: companionDest.path()
                )
                storedCompanionFilename = companionName
                companionDestinationURL = companionDest
            } catch {
                try? fileManager.removeItem(at: destinationURL)
                throw error
            }
        }

        let entry = SharedImportQueueEntry(
            id: id,
            spaceRawValue: space.rawValue,
            relativePath: storedFilename,
            companionRelativePath: storedCompanionFilename,
            originalFilename: originalFilename,
            contentTypeIdentifier: contentType.identifier,
            createdAt: .now
        )
        do {
            try appendEntry(entry)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            if let companionDestinationURL {
                try? fileManager.removeItem(at: companionDestinationURL)
            }
            throw error
        }
    }

    func fileURL(for entry: SharedImportQueueEntry) throws -> URL {
        try validatedQueuedFileURL(filename: entry.relativePath)
    }

    func companionFileURL(for entry: SharedImportQueueEntry) throws -> URL? {
        guard let companionRelativePath = entry.companionRelativePath else { return nil }
        return try validatedQueuedFileURL(filename: companionRelativePath)
    }

    private func validatedQueuedFileURL(filename: String) throws -> URL {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.contains("/"),
              !filename.contains("\\"),
              !filename.contains("\0"),
              URL(fileURLWithPath: filename).lastPathComponent == filename else {
            throw SharedImportError.noReadableItems
        }
        return try filesDirectory().appendingPathComponent(filename, isDirectory: false)
    }

    func removeEntries(_ entries: [SharedImportQueueEntry]) {
        let removingIDs = Set(entries.map(\.id))
        _ = withQueueLock {
            let remaining = loadEntriesUnlocked().filter { !removingIDs.contains($0.id) }
            try? saveEntriesUnlocked(remaining)
        }

        for entry in entries {
            if let url = try? fileURL(for: entry),
               fileManager.fileExists(atPath: url.path()) {
                try? fileManager.removeItem(at: url)
            }
            if let companionURL = try? companionFileURL(for: entry),
               fileManager.fileExists(atPath: companionURL.path()) {
                try? fileManager.removeItem(at: companionURL)
            }
        }
    }

    /// Removes queued plaintext files and shared app state, e.g. during an emergency wipe.
    func wipeAll() {
        if let root = try? rootDirectory() {
            try? fileManager.removeItem(at: root)
        }
        defaults?.removePersistentDomain(forName: SharedImportConstants.appGroupIdentifier)
    }

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedImportConstants.appGroupIdentifier)
    }

    private func resolvedFileExtension(for contentType: UTType, originalFilename: String) -> String {
        if let extensionFromType = contentType.preferredFilenameExtension, !extensionFromType.isEmpty {
            return extensionFromType
        }
        let rawNameExtension = URL(fileURLWithPath: originalFilename).pathExtension
        let sanitized = String(rawNameExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(16))
        if !sanitized.isEmpty,
           let inferredType = UTType(filenameExtension: sanitized),
           inferredType.conforms(to: .image) || inferredType.conforms(to: .movie) {
            return sanitized
        }
        return contentType.conforms(to: .movie) ? "mov" : "jpg"
    }

    private func appendEntry(_ entry: SharedImportQueueEntry) throws {
        try withQueueLockThrowing {
            var entries = loadEntriesUnlocked()
            entries.append(entry)
            try saveEntriesUnlocked(entries)
        }
    }

    private func loadEntriesUnlocked() -> [SharedImportQueueEntry] {
        guard let url = try? queueURL(),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder.sharedImportDecoder.decode([SharedImportQueueEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func saveEntriesUnlocked(_ entries: [SharedImportQueueEntry]) throws {
        let data = try JSONEncoder.sharedImportEncoder.encode(entries)
        let url = try queueURL()
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func withQueueLock<T>(_ body: () -> T) -> T? {
        try? withQueueLockThrowing {
            body()
        }
    }

    private func withQueueLockThrowing<T>(_ body: () throws -> T) throws -> T {
        let lockURL = try rootDirectory().appendingPathComponent(".queue.lock", isDirectory: false)
        let fd = lockURL.path.withCString { pathPointer in
            Darwin.open(pathPointer, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else {
            return try body()
        }
        defer {
            _ = flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
        _ = flock(fd, LOCK_EX)
        return try body()
    }

    private func queueURL() throws -> URL {
        try rootDirectory().appendingPathComponent("queue.json")
    }

    private func filesDirectory() throws -> URL {
        try ensureDirectory(rootDirectory().appendingPathComponent("Files", isDirectory: true))
    }

    private func rootDirectory() throws -> URL {
        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SharedImportConstants.appGroupIdentifier) else {
            throw SharedImportError.appGroupUnavailable
        }
        return try ensureDirectory(containerURL.appendingPathComponent("SharedImports", isDirectory: true))
    }

    private func ensureDirectory(_ url: URL) throws -> URL {
        var directoryURL = url
        if !fileManager.fileExists(atPath: directoryURL.path()) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.path()
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? directoryURL.setResourceValues(resourceValues)
        return directoryURL
    }

    private enum Keys {
        static let appState = "SharedImportAppState"
    }
}

private extension JSONEncoder {
    static var sharedImportEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var sharedImportDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
