import Foundation

enum BiometricUnlockMode: String, CaseIterable, Identifiable {
    case manual
    case scheduled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: String(localized: "固定空间")
        case .scheduled: String(localized: "分时段")
        }
    }
}

struct BiometricUnlockSettings {
    var mode: BiometricUnlockMode
    var manualSpace: VaultSpaceKind
    var scheduledPrimarySpace: VaultSpaceKind
    var scheduleStartMinutes: Int
    var scheduleEndMinutes: Int

    func resolvedSpace(for date: Date = .now, calendar: Calendar = .current) -> VaultSpaceKind {
        switch mode {
        case .manual:
            return manualSpace
        case .scheduled:
            let active = scheduledPrimarySpace
            let inactive = scheduledPrimarySpace == .spaceA ? VaultSpaceKind.spaceB : .spaceA
            let nowMinutes = (calendar.dateComponents([.hour, .minute], from: date).hour ?? 0) * 60
                + (calendar.dateComponents([.hour, .minute], from: date).minute ?? 0)

            if isWithinSchedule(minutes: nowMinutes) {
                return active
            } else {
                return inactive
            }
        }
    }

    private func isWithinSchedule(minutes: Int) -> Bool {
        if scheduleStartMinutes == scheduleEndMinutes {
            return false
        }

        if scheduleStartMinutes < scheduleEndMinutes {
            return minutes >= scheduleStartMinutes && minutes < scheduleEndMinutes
        }

        return minutes >= scheduleStartMinutes || minutes < scheduleEndMinutes
    }
}

extension BiometricUnlockSettings {
    static func load(from defaults: UserDefaults = .standard) -> BiometricUnlockSettings {
        let mode = BiometricUnlockMode(
            rawValue: defaults.string(forKey: AppSettingsKey.biometricUnlockMode) ?? ""
        ) ?? .manual

        let manualSpace = VaultSpaceKind(
            rawValue: defaults.string(forKey: AppSettingsKey.biometricDefaultSpace) ?? ""
        ) ?? .spaceA

        let scheduledPrimarySpace = VaultSpaceKind(
            rawValue: defaults.string(forKey: AppSettingsKey.biometricScheduledPrimarySpace) ?? ""
        ) ?? .spaceB

        let hasStoredStart = defaults.object(forKey: AppSettingsKey.biometricScheduleStartMinutes) != nil
        let hasStoredEnd = defaults.object(forKey: AppSettingsKey.biometricScheduleEndMinutes) != nil

        return BiometricUnlockSettings(
            mode: mode,
            manualSpace: manualSpace,
            scheduledPrimarySpace: scheduledPrimarySpace,
            scheduleStartMinutes: hasStoredStart ? defaults.integer(forKey: AppSettingsKey.biometricScheduleStartMinutes) : 21 * 60,
            scheduleEndMinutes: hasStoredEnd ? defaults.integer(forKey: AppSettingsKey.biometricScheduleEndMinutes) : 8 * 60
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: AppSettingsKey.biometricUnlockMode)
        defaults.set(manualSpace.rawValue, forKey: AppSettingsKey.biometricDefaultSpace)
        defaults.set(scheduledPrimarySpace.rawValue, forKey: AppSettingsKey.biometricScheduledPrimarySpace)
        defaults.set(scheduleStartMinutes, forKey: AppSettingsKey.biometricScheduleStartMinutes)
        defaults.set(scheduleEndMinutes, forKey: AppSettingsKey.biometricScheduleEndMinutes)
    }
}
