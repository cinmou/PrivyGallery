import SwiftUI

struct MediaItemInfoView: View {
    let detail: MediaItemDetailInfo

    var body: some View {
        List {
            Section {
                detailRow(title: String(localized: "名称"), value: detail.title)
                detailRow(title: String(localized: "类型"), value: detail.mediaKindTitle)
                detailRow(title: String(localized: "原始文件名"), value: detail.originalFilename)
                detailRow(title: String(localized: "内容类型"), value: detail.contentTypeIdentifier)
                detailRow(title: String(localized: "文件大小"), value: ByteCountFormatter.string(fromByteCount: detail.byteCount, countStyle: .file))
            }

            Section {
                detailRow(title: String(localized: "导入时间"), value: formattedDate(detail.importedAt))
                if let originalCapturedAt = detail.originalCapturedAt {
                    detailRow(title: String(localized: "拍摄时间"), value: formattedDate(originalCapturedAt))
                }
                if let lastExportedAt = detail.lastExportedAt {
                    detailRow(title: String(localized: "上次导出"), value: formattedDate(lastExportedAt))
                }
            }

            if let latitude = detail.locationLatitude, let longitude = detail.locationLongitude {
                Section {
                    detailRow(title: String(localized: "纬度"), value: String(format: "%.6f", latitude))
                    detailRow(title: String(localized: "经度"), value: String(format: "%.6f", longitude))
                }
            }
        }
        .navigationTitle(String(localized: "媒体信息"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
