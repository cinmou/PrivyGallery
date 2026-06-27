import SwiftUI
import UniformTypeIdentifiers

struct AlbumCustomSortView: View {
    @ObservedObject var viewModel: MediaLibraryViewModel
    let albumID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var draggingItemID: UUID?

    private let columns = [
        GridItem(.adaptive(minimum: 104), spacing: 10)
    ]

    private var items: [VaultItem] {
        viewModel.mediaItems(for: albumID)
    }

    private var isSecureAlbum: Bool {
        viewModel.album(for: albumID)?.kind.isSecure == true
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSecureAlbum {
                    List {
                        ForEach(items) { item in
                            MediaItemTileView(
                                item: item,
                                isSelected: false,
                                isSelecting: false,
                                displayStyle: .secureRow
                            )
                        }
                        .onMove { source, destination in
                            viewModel.moveItems(in: albumID, from: source, to: destination)
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                    .listStyle(.plain)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(items) { item in
                                reorderTile(for: item)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .navigationTitle(String(localized: "自由排序"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "完成")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func reorderTile(for item: VaultItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaItemTileView(
                item: item,
                isSelected: false,
                isSelecting: false
            )

            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .opacity(draggingItemID == item.id ? 0.55 : 1)
        .onDrag {
            draggingItemID = item.id
            return NSItemProvider(object: item.id.uuidString as NSString)
        }
        .onDrop(
            of: [UTType.text],
            delegate: AlbumGridDropDelegate(
                item: item,
                items: items,
                draggingItemID: $draggingItemID,
                onMove: { from, to in
                    viewModel.moveItems(in: albumID, from: from, to: to)
                }
            )
        )
    }
}

private struct AlbumGridDropDelegate: DropDelegate {
    let item: VaultItem
    let items: [VaultItem]
    @Binding var draggingItemID: UUID?
    let onMove: (IndexSet, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingItemID,
              draggingItemID != item.id,
              let fromIndex = items.firstIndex(where: { $0.id == draggingItemID }),
              let toIndex = items.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        if fromIndex != toIndex {
            let destination = toIndex > fromIndex ? toIndex + 1 : toIndex
            onMove(IndexSet(integer: fromIndex), destination)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingItemID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

#Preview {
    AlbumCustomSortView(
        viewModel: PreviewSupport.mediaLibraryViewModel(),
        albumID: UUID()
    )
}
