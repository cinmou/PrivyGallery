import Foundation

nonisolated struct AlbumColor: RawRepresentable, Hashable, Identifiable, Sendable {
    let rawValue: String
    var id: String { rawValue }

    init?(rawValue: String) {
        let legacyColors = [
            "red": "#E8383B", "orange": "#FF871F", "yellow": "#F7C921",
            "green": "#2EB35C", "blue": "#297DF2", "purple": "#A857E0"
        ]
        let value = legacyColors[rawValue] ?? rawValue.uppercased()
        guard value.count == 7, value.first == "#",
              value.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        self.rawValue = value
    }
}

extension VaultItem {
    func coloredAlbums(excluding albumID: UUID? = nil) -> [VaultAlbum] {
        albums.filter {
            $0.id != albumID && $0.space == space && $0.isSecureAlbum == isStrongProtected && $0.color != nil
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func albumColors(excluding albumID: UUID? = nil) -> [AlbumColor] {
        let colors = Set(coloredAlbums(excluding: albumID).compactMap(\.color))
        return colors.sorted { $0.rawValue < $1.rawValue }
    }

    func albumColorAccessibilityLabel(excluding albumID: UUID? = nil) -> String {
        coloredAlbums(excluding: albumID).map(\.displayName).joined(separator: "; ")
    }

    var videoDurationText: String {
        guard let videoDuration, videoDuration.isFinite, videoDuration > 0,
              videoDuration < Double(Int.max / 2) else { return "--:--" }
        let seconds = max(1, Int(videoDuration.rounded(.down)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
