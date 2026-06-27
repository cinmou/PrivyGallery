import Foundation

enum VaultSpaceKind: String, Codable, CaseIterable, Identifiable {
    case spaceA
    case spaceB

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spaceA: String(localized: "空间 A")
        case .spaceB: String(localized: "空间 B")
        }
    }

    var subtitle: String {
        switch self {
        case .spaceA: String(localized: "独立数据与独立密钥")
        case .spaceB: String(localized: "独立数据与独立密钥")
        }
    }

    var supportsBiometrics: Bool {
        true
    }

    var allowsImport: Bool {
        true
    }

    var allowsFullBackup: Bool {
        true
    }
}
