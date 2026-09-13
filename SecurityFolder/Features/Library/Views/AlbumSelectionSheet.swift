import SwiftUI

struct AlbumSelectionSheet: View {
    @ObservedObject var viewModel: MediaLibraryViewModel
    let currentAlbumID: UUID
    let selectedItemIDs: Set<UUID>

    @Environment(\.dismiss) private var dismiss
    @State private var changes: [UUID: Bool] = [:]

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
                        if let color = option.color { AlbumColorDot(color: color) }
                        if changes[option.id] ?? option.isSelected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        } else if changes[option.id] == nil && option.isMixed {
                            Image(systemName: "minus").foregroundStyle(.secondary)
                                .accessibilityLabel(String(localized: "部分项目已加入"))
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "管理相册"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.setMembership(of: selectedItemIDs, changes: changes, currentAlbumID: currentAlbumID)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(String(localized: "完成"))
                }
            }
        }
    }

    private func toggleDraftSelection(for albumID: UUID) {
        let option = viewModel.albumSelectionOptions(for: selectedItemIDs, currentAlbumID: currentAlbumID).first { $0.id == albumID }
        changes[albumID] = !(changes[albumID] ?? option?.isSelected ?? false)
    }
}

#Preview {
    AlbumSelectionSheet(
        viewModel: PreviewSupport.mediaLibraryViewModel(),
        currentAlbumID: UUID(),
        selectedItemIDs: []
    )
}
