import Foundation

nonisolated enum MediaSearchType: String, CaseIterable, Sendable {
    case all, photos, videos
    var title: String {
        switch self {
        case .all: String(localized: "全部")
        case .photos: String(localized: "照片")
        case .videos: String(localized: "视频")
        }
    }
}

nonisolated enum MediaSearchDateField: String, CaseIterable, Sendable {
    case captured, imported
    var title: String {
        switch self {
        case .captured: String(localized: "拍摄日期")
        case .imported: String(localized: "导入日期")
        }
    }
}

nonisolated struct MediaSearchQuery: Equatable, Sendable {
    var text = ""
    var type: MediaSearchType = .all
    var usesDateRange = false
    var dateField: MediaSearchDateField = .captured
    var startDate = Calendar.current.startOfDay(for: Date())
    var endDate = Date()
    var normalizedText: String { Self.normalize(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var isActive: Bool { !normalizedText.isEmpty || type != .all || usesDateRange }
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    func matches(name: String, filename: String, kind: MediaKind, capturedAt: Date?, importedAt: Date) -> Bool {
        if type == .photos && kind == .video { return false }
        if type == .videos && kind != .video { return false }
        if usesDateRange {
            guard let date = dateField == .captured ? capturedAt : importedAt else { return false }
            let calendar = Calendar.current
            let lower = calendar.startOfDay(for: startDate)
            guard let upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)),
                  date >= lower && date < upper else { return false }
        }
        let text = normalizedText
        return text.isEmpty || Self.normalize(name).contains(text) || Self.normalize(filename).contains(text)
    }
}

// Only immutable values cross the actor boundary; VaultItem/VaultAlbum stay on MainActor.
nonisolated struct MediaSearchDocument: Sendable {
    let id: UUID
    let name: String
    let filename: String
    let kindRawValue: String
    let capturedAt: Date?
    let importedAt: Date

    static func matchingIDs(in documents: [Self], query: MediaSearchQuery, newestImportFirst: Bool) -> [UUID] {
        var matches: [Self] = []
        for document in documents {
            if Task.isCancelled { return [] }
            guard let kind = MediaKind(rawValue: document.kindRawValue),
                  query.matches(name: document.name, filename: document.filename, kind: kind,
                                capturedAt: document.capturedAt, importedAt: document.importedAt) else { continue }
            matches.append(document)
        }
        if newestImportFirst {
            matches.sort {
                if $0.importedAt != $1.importedAt { return $0.importedAt > $1.importedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        return matches.map(\.id)
    }
}

nonisolated struct MediaSearchRequest: Equatable {
    let query: MediaSearchQuery
    let albumID: UUID
    let wholeSpace: Bool
    let revision: Int
    let enabled: Bool
}
