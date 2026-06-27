import SwiftUI
import UIKit

private let albumCoverCornerRadius: CGFloat = 8

struct AlbumCellView: View {
    let album: AlbumCellModel
    var accentSelection = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: albumCoverCornerRadius, style: .continuous)
                    .fill(platformCardBackground)

                if let coverImageRelativePath = album.coverImageRelativePath {
                    AlbumCoverImageView(relativePath: coverImageRelativePath)
                } else if let coverItem = album.coverItem {
                    AlbumCoverThumbnailView(item: coverItem)
                } else {
                    Image(systemName: album.systemImage)
                        .font(.title2)
                        .foregroundStyle(accentSelection ? Color.accentColor : .secondary)
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: albumCoverCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: albumCoverCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .foregroundStyle(accentSelection ? Color.accentColor : .primary)
                Text(album.subtitle)
                    .font(.footnote)
                    .foregroundStyle(accentSelection ? Color.accentColor : .secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(accentSelection ? Color.accentColor : Color.secondary.opacity(0.65))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var platformCardBackground: Color {
        #if targetEnvironment(macCatalyst)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }
}

private struct AlbumCoverThumbnailView: View {
    let item: VaultItem
    @State private var image: UIImage?
    @State private var loadedItemID: UUID?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                platformCardBackground
                    .overlay {
                        Image(systemName: item.mediaKind.symbolName)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: item.id) {
            await loadCoverThumbnail(for: item)
        }
    }

    private var platformCardBackground: Color {
        #if targetEnvironment(macCatalyst)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }

    private func loadCoverThumbnail(for item: VaultItem) async {
        let side = MediaThumbnailService.gridThumbnailSide
        let targetSize = CGSize(width: side, height: side)

        if loadedItemID != item.id {
            await MainActor.run {
                loadedItemID = item.id
                image = nil
            }
        }

        if let cached = MediaThumbnailService.shared.cachedThumbnail(for: item, size: targetSize) {
            await MainActor.run {
                guard loadedItemID == item.id else { return }
                image = cached
            }
            return
        }

        let thumbnail = await MediaThumbnailService.shared.thumbnail(for: item, size: targetSize, priority: .userInitiated)
        await MainActor.run {
            guard loadedItemID == item.id else { return }
            image = thumbnail
        }
    }
}

private struct AlbumCoverImageView: View {
    let relativePath: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                platformCardBackground
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: relativePath) {
            image = VaultFileStorageService.shared.albumCoverImage(for: relativePath)
        }
    }

    private var platformCardBackground: Color {
        #if targetEnvironment(macCatalyst)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }
}
