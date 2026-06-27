import SwiftUI

struct LibraryCustomSortView: View {
    @ObservedObject var viewModel: MediaLibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .active

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "拖动调整顺序")) {
                    ForEach(viewModel.mediaAlbums) { album in
                        librarySortRow(for: album)
                    }
                    .onMove { source, destination in
                        viewModel.moveLibraryAlbums(from: source, to: destination)
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(String(localized: "相册排序"))
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

    private func librarySortRow(for album: AlbumCellModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: album.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .foregroundStyle(.primary)
                Text(album.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    LibraryCustomSortView(viewModel: PreviewSupport.mediaLibraryViewModel())
}
