import Foundation
import CoreGraphics

/// Geometry is based on the viewer's current safe area, including asymmetric insets.
nonisolated struct MediaViewerOverlayLayout {
    let top: CGRect
    let rate: CGRect
    let scrubber: CGRect
    let playback: CGRect
    let centerButtonSide: CGFloat
    let skipButtonSide: CGFloat
    let buttonSpacing: CGFloat
    let detail: CGRect

    init(safeArea: CGRect, topHeight: CGFloat, rateSize: CGSize, scrubberHeight: CGFloat,
         showsPlayback: Bool, allowsSeeking: Bool) {
        let area = safeArea.insetBy(dx: min(12, safeArea.width / 4), dy: min(8, safeArea.height / 4))
        top = CGRect(x: area.minX, y: area.minY, width: area.width, height: max(44, topHeight))
        let rateWidth = min(area.width, max(64, rateSize.width))
        let rateHeight = max(44, rateSize.height)
        let timelineWidth = area.width - rateWidth - 10
        if timelineWidth >= 120 {
            let footerHeight = max(rateHeight, scrubberHeight)
            rate = CGRect(x: area.minX, y: area.maxY - (footerHeight + rateHeight) / 2,
                          width: rateWidth, height: rateHeight)
            scrubber = CGRect(x: rate.maxX + 10, y: area.maxY - (footerHeight + scrubberHeight) / 2,
                              width: timelineWidth, height: scrubberHeight)
        } else {
            scrubber = CGRect(x: area.minX, y: area.maxY - scrubberHeight,
                              width: area.width, height: scrubberHeight)
            rate = CGRect(x: area.minX, y: scrubber.minY - rateHeight - 8,
                          width: rateWidth, height: rateHeight)
        }
        let lower = showsPlayback ? min(rate.minY, scrubber.minY) - 8 : area.maxY
        let upper = top.maxY + 8
        centerButtonSide = min(92, max(44, lower - upper), allowsSeeking ? max(44, (area.width - 16) / 2.5) : area.width)
        skipButtonSide = max(44, min(64, centerButtonSide * 64 / 92))
        buttonSpacing = min(30, max(8, (area.width - centerButtonSide - skipButtonSide * 2) / 2))
        let controlsWidth = allowsSeeking ? centerButtonSide + skipButtonSide * 2 + buttonSpacing * 2 : centerButtonSide
        let centerY = min(lower - centerButtonSide / 2,
                          max(upper + centerButtonSide / 2, safeArea.midY))
        playback = CGRect(x: area.midX - controlsWidth / 2, y: centerY - centerButtonSide / 2,
                          width: controlsWidth, height: centerButtonSide)
        let panelWidth = min(area.width, 430)
        let panelHeight = max(0, area.maxY - top.maxY - 16)
        detail = CGRect(x: area.midX - panelWidth / 2, y: area.maxY - min(460, panelHeight),
                        width: panelWidth, height: min(460, panelHeight))
    }
}
