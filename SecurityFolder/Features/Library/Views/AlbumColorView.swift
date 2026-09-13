import SwiftUI
import UIKit

extension AlbumColor {
    var uiColor: UIColor {
        let rgb = UInt32(rawValue.dropFirst(), radix: 16)!
        return UIColor(
            red: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255,
            alpha: 1
        )
    }

    init?(uiColor: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        let components = [red, green, blue].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        self.init(rawValue: String(format: "#%02X%02X%02X", components[0], components[1], components[2]))
    }
}

struct AlbumColorDot: View {
    let color: AlbumColor

    var body: some View {
        Circle()
            .fill(Color(uiColor: color.uiColor))
            .frame(width: 10, height: 10)
            .accessibilityLabel(String(localized: "相册颜色"))
    }
}

struct MediaAlbumColors: View {
    let item: VaultItem
    var currentAlbumID: UUID? = nil

    var body: some View {
        let colors = Array(item.albumColors(excluding: currentAlbumID).prefix(6))
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(Array(stride(from: 0, to: colors.count, by: 3)), id: \.self) { start in
                HStack(spacing: 2) {
                    ForEach(Array(colors[start..<min(start + 3, colors.count)])) { color in
                        Circle()
                            .fill(Color(uiColor: color.uiColor))
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.albumColorAccessibilityLabel(excluding: currentAlbumID))
        .allowsHitTesting(false)
    }
}

final class MediaAlbumColorsView: UIStackView {
    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = 2
        alignment = .trailing
        isUserInteractionEnabled = false
        isAccessibilityElement = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: VaultItem, currentAlbumID: UUID?, isSelecting: Bool) {
        arrangedSubviews.forEach { removeArrangedSubview($0); $0.removeFromSuperview() }
        let colors = Array(item.albumColors(excluding: currentAlbumID).prefix(6))
        isHidden = isSelecting || colors.isEmpty
        accessibilityLabel = item.albumColorAccessibilityLabel(excluding: currentAlbumID)
        guard !isHidden else { return }
        for start in stride(from: 0, to: colors.count, by: 3) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 2
            for color in colors[start..<min(start + 3, colors.count)] {
                let dot = UIView()
                dot.backgroundColor = color.uiColor
                dot.layer.cornerRadius = 4
                dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
                dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
                row.addArrangedSubview(dot)
            }
            addArrangedSubview(row)
        }
    }
}

struct AlbumColorPicker: View {
    @ObservedObject var viewModel: MediaLibraryViewModel
    let albumID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var selectedColor: AlbumColor?

    init(viewModel: MediaLibraryViewModel, albumID: UUID) {
        self.viewModel = viewModel
        self.albumID = albumID
        _selectedColor = State(initialValue: viewModel.album(for: albumID)?.color)
    }

    var body: some View {
        NativeAlbumColorPicker(
            initialColor: selectedColor?.uiColor ?? .systemBlue,
            onSelect: { selectedColor = AlbumColor(uiColor: $0) },
            onFinish: { dismiss() }
        )
        .onDisappear {
            viewModel.setAlbumColor(id: albumID, color: selectedColor)
        }
    }
}

private struct NativeAlbumColorPicker: UIViewControllerRepresentable {
    let initialColor: UIColor
    let onSelect: (UIColor) -> Void
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.selectedColor = initialColor
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var parent: NativeAlbumColorPicker
        init(parent: NativeAlbumColorPicker) { self.parent = parent }

        func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
            parent.onSelect(color)
        }

        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
            parent.onFinish()
        }
    }
}
