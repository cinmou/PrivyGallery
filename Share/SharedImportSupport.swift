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
    let originalFilename: String
    let contentTypeIdentifier: String
    let createdAt: Date
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
        loadEntries()
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
        space: SharedImportSpace
    ) throws {
        guard contentType.conforms(to: .image) || contentType.conforms(to: .movie) else {
            throw SharedImportError.unsupportedType
        }
        guard appState.canUse(space) else {
            throw SharedImportError.unavailableSpace
        }

        let id = UUID()
        let extensionFromType = contentType.preferredFilenameExtension
        let extensionFromName = URL(fileURLWithPath: originalFilename).pathExtension
        let fileExtension = extensionFromName.isEmpty ? (extensionFromType ?? "dat") : extensionFromName
        let storedFilename = "\(id.uuidString).\(fileExtension)"
        let destinationURL = try filesDirectory().appendingPathComponent(storedFilename)

        if fileManager.fileExists(atPath: destinationURL.path()) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let entry = SharedImportQueueEntry(
            id: id,
            spaceRawValue: space.rawValue,
            relativePath: storedFilename,
            originalFilename: originalFilename,
            contentTypeIdentifier: contentType.identifier,
            createdAt: .now
        )
        appendEntry(entry)
    }

    func fileURL(for entry: SharedImportQueueEntry) throws -> URL {
        try filesDirectory().appendingPathComponent(entry.relativePath)
    }

    func removeEntries(_ entries: [SharedImportQueueEntry]) {
        let removingIDs = Set(entries.map(\.id))
        let remaining = loadEntries().filter { !removingIDs.contains($0.id) }
        saveEntries(remaining)

        for entry in entries {
            if let url = try? fileURL(for: entry),
               fileManager.fileExists(atPath: url.path()) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedImportConstants.appGroupIdentifier)
    }

    private func appendEntry(_ entry: SharedImportQueueEntry) {
        var entries = loadEntries()
        entries.append(entry)
        saveEntries(entries)
    }

    private func loadEntries() -> [SharedImportQueueEntry] {
        guard let data = try? Data(contentsOf: queueURL()),
              let entries = try? JSONDecoder.sharedImportDecoder.decode([SharedImportQueueEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func saveEntries(_ entries: [SharedImportQueueEntry]) {
        guard let data = try? JSONEncoder.sharedImportEncoder.encode(entries),
              let url = try? queueURL() else {
            return
        }
        try? data.write(to: url, options: .atomic)
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
        if !fileManager.fileExists(atPath: url.path()) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
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
