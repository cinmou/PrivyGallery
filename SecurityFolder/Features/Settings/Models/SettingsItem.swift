import Foundation

struct SettingsItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let isEnabled: Bool
}
