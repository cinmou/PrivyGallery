import Foundation

/// 空间展示名称只用于设置页里的记忆辅助，不参与密钥、路由或数据隔离逻辑。
enum SpaceDisplaySettings {
    static func displayName(
        for space: VaultSpaceKind,
        defaults: UserDefaults = .standard
    ) -> String {
        let key = nameKey(for: space)
        let storedValue = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let storedValue, !storedValue.isEmpty {
            if legacyDefaultNames(for: space).contains(storedValue) {
                defaults.removeObject(forKey: key)
            } else {
                return storedValue
            }
        }

        return defaultName(for: space)
    }

    static func updateDisplayName(
        _ name: String,
        for space: VaultSpaceKind,
        defaults: UserDefaults = .standard
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || legacyDefaultNames(for: space).contains(trimmed) {
            defaults.removeObject(forKey: nameKey(for: space))
        } else {
            defaults.set(trimmed, forKey: nameKey(for: space))
        }
    }

    static func defaultName(for space: VaultSpaceKind) -> String {
        switch space {
        case .spaceA:
            return String(localized: "主要空间")
        case .spaceB:
            return String(localized: "第二空间")
        }
    }

    private static func nameKey(for space: VaultSpaceKind) -> String {
        switch space {
        case .spaceA:
            return AppSettingsKey.spaceADisplayName
        case .spaceB:
            return AppSettingsKey.spaceBDisplayName
        }
    }

    private static func legacyDefaultNames(for space: VaultSpaceKind) -> Set<String> {
        switch space {
        case .spaceA:
            return [
                "主要空间",
                "主要空間",
                "Main Space",
                "Primary Space"
            ]
        case .spaceB:
            return [
                "第二空间",
                "第二空間",
                "Second Space"
            ]
        }
    }
}
