import SwiftUI

struct MediaPreviewView: View {
    @ObservedObject var viewModel: MediaLibraryViewModel
    let albumID: UUID
    let items: [VaultItem]
    let initialItemID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: PendingPreviewDeletion?
    @State private var detailItemID: UUID?

    var body: some View {
        MediaViewerView(
            items: items,
            initialItemID: initialItemID,
            policy: .regular,
            actions: MediaViewerActions(
                exportURL: { item in viewModel.exportURL(for: item.id) },
                showDetails: { item in detailItemID = item.id },
                detailInfo: { item in viewModel.details(for: item.id) },
                menuContent: { item in menuContent(for: item) }
            ),
            onDismiss: { dismiss() }
        )
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

        if currentAlbumKind == .trash {
            Button {
                viewModel.restoreFromTrash(itemID: item.id)
                dismiss()
            } label: {
                Label(String(localized: "恢复"), systemImage: "arrow.uturn.backward")
            }

            Button(role: .destructive) {
                requestDeletion(for: item)
            } label: {
                Label(String(localized: "彻底删除"), systemImage: "trash")
            }
        } else {
            Button {
                viewModel.duplicate(itemIDs: Set([item.id]))
            } label: {
                Label(String(localized: "复制"), systemImage: "plus.square.on.square")
            }

            if currentAlbumKind == .archive {
                Button {
                    viewModel.unarchive(itemID: item.id)
                    dismiss()
                } label: {
                    Label(String(localized: "放回"), systemImage: "arrow.uturn.backward.circle")
                }
            } else if currentAlbumKind == .secureLibrary {
                Button {
                    viewModel.removeFromStrongProtection(itemIDs: Set([item.id]))
                    dismiss()
                } label: {
                    Label(String(localized: "移出强加密媒体库"), systemImage: "lock.open")
                }
            } else if currentAlbumKind != .secureCustom {
                Button {
                    viewModel.archive(itemIDs: Set([item.id]))
                    dismiss()
                } label: {
                    Label(String(localized: "归档"), systemImage: "archivebox")
                }
            }

            Button(role: .destructive) {
                requestDeletion(for: item)
            } label: {
                Label(deleteTitle, systemImage: "trash")
            }
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

    private var deleteTitle: String {
        switch currentAlbumKind {
        case .allPhotos, .allVideos, .archive:
            return String(localized: "移到回收站")
        case .custom:
            return String(localized: "移出相册")
        case .secureLibrary:
            return String(localized: "移出强加密媒体库")
        case .secureCustom:
            return String(localized: "移出相册")
        case .trash:
            return String(localized: "彻底删除")
        case .none:
            return String(localized: "删除")
        }
    }

    private func requestDeletion(for item: VaultItem) {
        let title: String
        let message: String

        switch currentAlbumKind {
        case .trash:
            title = String(localized: "彻底删除？")
            message = String(localized: "这个项目将被永久删除，无法从回收站恢复。")
        case .custom:
            title = String(localized: "移出相册？")
            message = String(localized: "这个项目只会从当前相册移出，不会删除原始媒体。")
        case .secureLibrary:
            title = String(localized: "移出强加密媒体库？")
            message = String(localized: "这个项目会关闭强加密保护，并回到普通媒体库。")
        case .secureCustom:
            title = String(localized: "移出相册？")
            message = String(localized: "这个项目只会从当前强加密相册移出，但仍保留在强加密媒体库中。")
        default:
            title = String(localized: "移到回收站？")
            message = String(localized: "这个项目会被放入回收站，可以稍后恢复。")
        }

        pendingDeletion = PendingPreviewDeletion(itemID: item.id, title: title, message: message)
    }
}

private struct PendingPreviewDeletion: Identifiable {
    let id = UUID()
    let itemID: UUID
    let title: String
    let message: String
}
