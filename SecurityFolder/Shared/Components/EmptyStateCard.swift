import SwiftUI

struct EmptyStateCard: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.tint)

            Text(title)
                .font(.title3.bold())

            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}

#Preview {
    EmptyStateCard(
        title: "还没有内容",
        message: "这里会显示你导入到应用中的照片和视频。",
        systemImage: "photo.on.rectangle.angled"
    )
    .padding()
}
