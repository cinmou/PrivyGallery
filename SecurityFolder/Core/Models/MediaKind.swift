import Foundation

enum MediaKind: String, CaseIterable, Identifiable {
    case photo
    case video
    case livePhoto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: String(localized: "照片")
        case .video: String(localized: "视频")
        case .livePhoto: String(localized: "Live Photo")
        }
    }

    var symbolName: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .livePhoto: "livephoto"
        }
    }
}
