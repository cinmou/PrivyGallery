import SwiftUI

struct MediaItemTileView: View {
    enum DisplayStyle {
        case grid
        case secureRow
    }

    let item: VaultItem
    let isSelected: Bool
    let isSelecting: Bool
    let footerText: String?
    let displayStyle: DisplayStyle
    let currentAlbumID: UUID?

    init(
        item: VaultItem,
        isSelected: Bool,
        isSelecting: Bool,
        footerText: String? = nil,
        displayStyle: DisplayStyle = .grid,
        currentAlbumID: UUID? = nil
    ) {
        self.currentAlbumID = currentAlbumID
        self.item = item
        self.isSelected = isSelected
        self.isSelecting = isSelecting
        self.footerText = footerText
        self.displayStyle = displayStyle
    }

    var body: some View {
        Group {
            switch displayStyle {
            case .grid:
                gridBody
            case .secureRow:
                secureRowBody
            }
        }
    }

    private var gridBody: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                MediaThumbnailView(item: item)
                    .frame(width: proxy.size.width, height: proxy.size.width)

                Group {
                    if item.mediaKind == .video {
                        Text(item.videoDurationText)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    } else if item.mediaKind == .livePhoto {
                        Image(systemName: "livephoto")
                            .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(8)

                if !isSelecting {
                    MediaAlbumColors(item: item, currentAlbumID: currentAlbumID)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                if let footerText {
                    VStack {
                        Spacer()
                        Text(footerText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(8)
                            .padding(.bottom, 20)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                if isSelecting {
                    VStack {
                        HStack {
                            Spacer()
                            selectionIndicator(selectedFill: Color.accentColor, unselectedFill: Color.white.opacity(0.2), unselectedStroke: .white)
                                .padding(8)
                        }
                        Spacer()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            }
            .frame(width: proxy.size.width, height: proxy.size.width)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
    }

    private var secureRowBody: some View {
        HStack(spacing: 12) {
            Image(systemName: item.mediaKind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let footerText {
                    Text(footerText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isSelecting {
                selectionIndicator(selectedFill: Color.accentColor, unselectedFill: Color(.secondarySystemBackground), unselectedStroke: .secondary)
            } else {
                MediaAlbumColors(item: item, currentAlbumID: currentAlbumID)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func selectionIndicator(
        selectedFill: Color,
        unselectedFill: Color,
        unselectedStroke: Color
    ) -> some View {
        ZStack {
            Circle()
                .fill(isSelected ? selectedFill : unselectedFill)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle()
                    .strokeBorder(unselectedStroke, lineWidth: 1.5)
            }
        }
        .frame(width: 24, height: 24)
    }
}

#Preview("普通状态") {
    MediaItemTileView(
        item: PreviewSupport.sampleItem(),
        isSelected: false,
        isSelecting: false
    )
    .padding()
}

#Preview("选择状态") {
    MediaItemTileView(
        item: PreviewSupport.sampleItem(name: "示例视频", mediaKind: .video),
        isSelected: true,
        isSelecting: true,
        footerText: "还剩 12 天"
    )
    .padding()
}
