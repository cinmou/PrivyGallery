import SwiftUI

struct AlbumSelectionSheet: View {
    @ObservedObject var viewModel: MediaLibraryViewModel
    let currentAlbumID: UUID
    let selectedItemIDs: Set<UUID>

    @Environment(\.dismiss) private var dismiss
    @State private var draftSelectedAlbumIDs = Set<UUID>()

    var body: some View {
        NavigationStack {
            List(viewModel.albumSelectionOptions(for: selectedItemIDs, currentAlbumID: currentAlbumID)) { option in
                Button {
                    toggleDraftSelection(for: option.id)
                } label: {
                    HStack {
                        Text(option.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if draftSelectedAlbumIDs.contains(option.id) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "添加到相册"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                draftSelectedAlbumIDs = Set(
                    viewModel.albumSelectionOptions(for: selectedItemIDs, currentAlbumID: currentAlbumID)
                        .filter(\.isSelected)
                        .map(\.id)
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.setMembership(of: selectedItemIDs, selectedAlbumIDs: draftSelectedAlbumIDs, currentAlbumID: currentAlbumID)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    private func toggleDraftSelection(for albumID: UUID) {
        if draftSelectedAlbumIDs.contains(albumID) {
            draftSelectedAlbumIDs.remove(albumID)
        } else {
            draftSelectedAlbumIDs.insert(albumID)
        }
    }
}

#Preview {
    AlbumSelectionSheet(
        viewModel: PreviewSupport.mediaLibraryViewModel(),
        currentAlbumID: UUID(),
        selectedItemIDs: []
    )
}
