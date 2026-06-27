import SwiftUI

struct SecureMediaPreviewView: View {
    @ObservedObject var viewModel: MediaLibraryViewModel
    let albumID: UUID
    let item: VaultItem

    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: PendingSecurePreviewDeletion?
    @State private var detailItemID: UUID?

    var body: some View {
        MediaViewerView(
            items: [item],
            initialItemID: item.id,
            policy: .secure,
            actions: MediaViewerActions(
                exportURL: { item in viewModel.exportURL(for: item.id) },
                showDetails: { item in detailItemID = item.id },
                detailInfo: { item in viewModel.details(for: item.id) },
                menuContent: { item in menuContent(for: item) }
            ),
            onDismiss: { dismiss() }
        )
        .background(Color.black.ignoresSafeArea())
        .sheet(item: detailItemBinding) { detail in
            NavigationStack {
                MediaItemInfoView(detail: detail)
            }
        }
        .alert(item: $pendingDeletion) { pendingDeletion in
            Alert(
                title: Text(pendingDeletion.title),
                message: Text(pendingDeletion.message),
                primaryButton: .destructive(Text(String(localized: "确认"))) {
                    viewModel.handleDeletion(of: pendingDeletion.itemID, from: albumID)
                    dismiss()
                },
                secondaryButton: .cancel()
            )
        }
    }

    @ViewBuilder
    private func menuContent(for item: VaultItem) -> some View {
        Button {
            detailItemID = item.id
        } label: {
            Label(String(localized: "显示详情"), systemImage: "info.circle")
        }

        if currentAlbumKind == .secureLibrary {
            Button(role: .destructive) {
                requestDeletion(for: item)
            } label: {
                Label(String(localized: "移出强加密媒体库"), systemImage: "lock.open")
            }
        } else if currentAlbumKind == .secureCustom {
            Button(role: .destructive) {
                requestDeletion(for: item)
            } label: {
                Label(String(localized: "移出相册"), systemImage: "minus.circle")
            }
        }

        Button(role: .destructive) {
            viewModel.handleDeletion(of: item.id, from: trashAlbumID)
            dismiss()
        } label: {
            Label(String(localized: "永久删除"), systemImage: "trash")
        }
    }

    private var detailItemBinding: Binding<MediaItemDetailInfo?> {
        Binding(
            get: {
                guard let detailItemID else { return nil }
                return viewModel.details(for: detailItemID)
            },
            set: { newValue in
                if newValue == nil {
                    detailItemID = nil
                }
            }
        )
    }

    private var currentAlbumKind: MediaAlbumKind? {
        viewModel.album(for: albumID)?.kind
    }

    private var trashAlbumID: UUID {
        viewModel.trashAlbum?.id ?? albumID
    }

    private func requestDeletion(for item: VaultItem) {
        let title: String
        let message: String

        switch currentAlbumKind {
        case .secureLibrary:
            title = String(localized: "移出强加密媒体库？")
            message = String(localized: "这个项目会回到普通媒体库。")
        case .secureCustom:
            title = String(localized: "移出相册？")
            message = String(localized: "这个项目会从当前相册移出，但仍保留在强加密媒体库中。")
        default:
            title = String(localized: "删除？")
            message = String(localized: "这个项目会被删除。")
        }

        pendingDeletion = PendingSecurePreviewDeletion(itemID: item.id, title: title, message: message)
    }
}

private struct PendingSecurePreviewDeletion: Identifiable {
    let id = UUID()
    let itemID: UUID
    let title: String
    let message: String
}
