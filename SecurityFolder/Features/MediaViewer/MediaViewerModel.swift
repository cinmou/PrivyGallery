import Foundation
import SwiftUI

enum MediaViewerOverlayState: Equatable {
    case visible
    case hidden
    case interacting
    case lockedVisible

    var showsFullOverlay: Bool {
        switch self {
        case .visible, .interacting, .lockedVisible:
            return true
        case .hidden:
            return false
        }
    }
}

struct MediaViewerSecurePolicy: Equatable {
    let isSecure: Bool
    let allowsSeeking: Bool
    let protectsScreenCapture: Bool

    static let regular = MediaViewerSecurePolicy(isSecure: false, allowsSeeking: true, protectsScreenCapture: false)
    static let secure = MediaViewerSecurePolicy(isSecure: true, allowsSeeking: false, protectsScreenCapture: true)
}

struct MediaViewerVideoState: Equatable {
    var isPlaying = false
    var didFinishPlayback = false
    var currentTime: Double = 0
    var duration: Double = 0
    var bufferedTime: Double = 0
    var playbackRate: Double = 1.0
    var isFastForwarding = false

    var hasKnownDuration: Bool {
        duration.isFinite && duration > 0
    }
}

struct MediaViewerActions<MenuContent: View> {
    let exportURL: (VaultItem) -> URL?
    let showDetails: (VaultItem) -> Void
    let detailInfo: (VaultItem) -> MediaItemDetailInfo?
    let menuContent: (VaultItem) -> MenuContent

    init(
        exportURL: @escaping (VaultItem) -> URL?,
        showDetails: @escaping (VaultItem) -> Void,
        detailInfo: @escaping (VaultItem) -> MediaItemDetailInfo? = { _ in nil },
        @ViewBuilder menuContent: @escaping (VaultItem) -> MenuContent
    ) {
        self.exportURL = exportURL
        self.showDetails = showDetails
        self.detailInfo = detailInfo
        self.menuContent = menuContent
    }
}
