import SwiftUI

/// Full-cover overlay shown while a drag session hovers over a droppable region.
/// Provides consistent "drop to import" feedback across macOS Catalyst and iPad.
struct DropImportOverlayView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.white)

                Text(String(localized: "拖入以导入"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .allowsHitTesting(false)
    }
}
