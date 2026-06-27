import Foundation

enum MediaAlbumKind: String, CaseIterable {
    case allPhotos
    case allVideos
    case custom
    case secureLibrary
    case secureCustom
    case trash
    case archive

    var isSecure: Bool {
        switch self {
        case .secureLibrary, .secureCustom:
            return true
        default:
            return false
        }
    }

    var systemDisplayName: String? {
        switch self {
        case .allPhotos:
            return String(localized: "全部照片")
        case .allVideos:
            return String(localized: "全部视频")
        case .secureLibrary:
            return String(localized: "强加密媒体库")
        case .trash:
            return String(localized: "回收站")
        case .archive:
            return String(localized: "归档")
        case .custom, .secureCustom:
            return nil
        }
    }

    var defaultAlbumName: String? {
        switch self {
        case .custom:
            return String(localized: "新建相册")
        case .secureCustom:
            return String(localized: "新建强加密相册")
        default:
            return systemDisplayName
        }
    }
}
