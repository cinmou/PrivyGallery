import Foundation

enum AlbumSortOption: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst
    case nameAscending
    case nameDescending
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newestFirst: String(localized: "最新在前")
        case .oldestFirst: String(localized: "最早在前")
        case .nameAscending: String(localized: "名称 A-Z")
        case .nameDescending: String(localized: "名称 Z-A")
        case .custom: String(localized: "自由排序")
        }
    }
}
