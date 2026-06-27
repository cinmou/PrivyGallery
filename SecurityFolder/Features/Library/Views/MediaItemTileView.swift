import SwiftUI

struct MediaItemTileView: View {
    enum DisplayStyle {
        case grid
        case secureGrid
        case secureRow
    }

    let item: VaultItem
    let isSelected: Bool
    let isSelecting: Bool
    let footerText: String?
    let displayStyle: DisplayStyle

    init(
        item: VaultItem,
        isSelected: Bool,
        isSelecting: Bool,
        footerText: String? = nil,
        displayStyle: DisplayStyle = .grid
    ) {
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
            case .secureGrid:
                secureGridBody
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

                Image(systemName: item.mediaKind.symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    .padding(8)

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

    private var secureGridBody: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(platformCardBackground)

                VStack(spacing: 8) {
                    Image(systemName: item.mediaKind == .video ? "video" : item.mediaKind.symbolName)
                        .font(.system(size: max(proxy.size.width * 0.24, 20), weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(item.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isSelecting {
                    selectionIndicator(selectedFill: Color.accentColor, unselectedFill: Color(.tertiarySystemGroupedBackground), unselectedStroke: .secondary)
                        .padding(8)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            }
            .frame(width: proxy.size.width, height: proxy.size.width)
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
    }

    private var platformCardBackground: Color {
        #if targetEnvironment(macCatalyst)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }

    private var secureRowBody: some View {
        HStack(spacing: 12) {
            Image(systemName: item.mediaKind == .video ? "video" : item.mediaKind.symbolName)
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
