import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case media
    case lock
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .media: String(localized: "媒体库")
        case .lock: String(localized: "锁定")
        case .settings: String(localized: "设置")
        }
    }

    var systemImage: String {
        switch self {
        case .media:
            if #available(iOS 18.0, *) {
                "photo.on.rectangle.angled.fill"
            } else {
                "photo.on.rectangle.fill"
            }
        case .lock: "lock.circle.fill"
        case .settings: "gearshape.fill"
        }
    }
}
