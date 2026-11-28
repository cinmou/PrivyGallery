import Foundation
import SwiftUI

struct MediaViewerSecurePolicy: Equatable {
    let isSecure: Bool
    let allowsSeeking: Bool
    let protectsScreenCapture: Bool

    static let regular = MediaViewerSecurePolicy(isSecure: false, allowsSeeking: true, protectsScreenCapture: false)
    static let secure = MediaViewerSecurePolicy(isSecure: true, allowsSeeking: false, protectsScreenCapture: true)
}

struct MediaViewerActions<MenuContent: View> {
    let exportItem: ((VaultItem) -> ExportedMediaItem?)?
    let showDetails: (VaultItem) -> Void
    let detailInfo: (VaultItem) -> MediaItemDetailInfo?
    let menuContent: (VaultItem) -> MenuContent

    init(
        exportItem: ((VaultItem) -> ExportedMediaItem?)? = nil,
        showDetails: @escaping (VaultItem) -> Void,
        detailInfo: @escaping (VaultItem) -> MediaItemDetailInfo? = { _ in nil },
        @ViewBuilder menuContent: @escaping (VaultItem) -> MenuContent
    ) {
        self.exportItem = exportItem
        self.showDetails = showDetails
        self.detailInfo = detailInfo
        self.menuContent = menuContent
    }
}
