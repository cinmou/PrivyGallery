#!/usr/bin/env python3
"""Exercise the player's real geometry against safe areas and large control metrics."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[2]
checks = r'''
import Foundation
import CoreGraphics

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
let areas = [
    CGRect(x: 0, y: 59, width: 390, height: 751),
    CGRect(x: 59, y: 0, width: 726, height: 369),
    CGRect(x: 0, y: 24, width: 1024, height: 724),
    CGRect(x: 48, y: 20, width: 352, height: 330),
    CGRect(x: 0, y: 0, width: 320, height: 568)
]
for area in areas {
    for largeText in [false, true] {
        for seeking in [false, true] {
            let layout = MediaViewerOverlayLayout(safeArea: area, topHeight: largeText ? 106 : 48,
                rateSize: CGSize(width: largeText ? 94 : 64, height: largeText ? 62 : 44),
                scrubberHeight: largeText ? 110 : 44, showsPlayback: true, allowsSeeking: seeking)
            for rect in [layout.top, layout.rate, layout.scrubber, layout.playback, layout.detail] {
                check(rect.width >= 0 && rect.height >= 0, "No negative frames")
                check(area.insetBy(dx: -0.01, dy: -0.01).contains(rect), "Controls must remain inside asymmetric safe areas: \(area) / \(rect)")
            }
            check(layout.rate.height >= 44 && layout.rate.width >= 44, "Rate button must have a 44-point target")
            check(layout.centerButtonSide >= 44 && layout.skipButtonSide >= 44, "Playback targets must remain tappable")
            check(!layout.top.intersects(layout.playback), "Header and playback controls must not overlap")
            check(!layout.rate.intersects(layout.playback) && !layout.scrubber.intersects(layout.playback), "Playback and footer controls must not overlap")
            check(!layout.rate.intersects(layout.scrubber), "Rate and timeline must not overlap")
        }
    }
}
let narrow = MediaViewerOverlayLayout(safeArea: CGRect(x: 0, y: 0, width: 240, height: 568),
    topHeight: 48, rateSize: CGSize(width: 100, height: 60), scrubberHeight: 80,
    showsPlayback: true, allowsSeeking: true)
check(narrow.scrubber.width == 216 && narrow.rate.maxY < narrow.scrubber.minY, "Narrow footers must stack")
check(narrow.playback.minX >= 0 && narrow.playback.maxX <= 240, "Three playback targets must fit narrow windows")
let portraitArea = CGRect(x: 0, y: 59, width: 390, height: 751)
for seeking in [false, true] {
    let layout = MediaViewerOverlayLayout(safeArea: portraitArea, topHeight: 48,
        rateSize: CGSize(width: 64, height: 44), scrubberHeight: 44,
        showsPlayback: true, allowsSeeking: seeking)
    check(layout.playback.midX == portraitArea.midX && layout.playback.midY == portraitArea.midY,
          "Playback stays centred with or without seek buttons")
    if !seeking {
        check(layout.playback.width == layout.centerButtonSide, "Secure playback reserves no empty seek-button space")
    }
}
print("PASS: player safe areas, portrait/landscape, large text, narrow footer, 44-point targets and control separation")
'''
with tempfile.TemporaryDirectory(prefix='privygallery-player-layout-') as directory:
    folder=Path(directory)
    (folder/'main.swift').write_text(checks)
    subprocess.run(['xcrun','swiftc',str(ROOT/'SecurityFolder/Features/MediaViewer/MediaViewerOverlayLayout.swift'),str(folder/'main.swift'),'-o',str(folder/'checks')],check=True)
    subprocess.run([str(folder/'checks')],check=True)
