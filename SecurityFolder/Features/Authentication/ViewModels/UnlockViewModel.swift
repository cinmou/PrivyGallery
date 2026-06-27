import Foundation
import Combine

/// 锁定页当前所处的阶段。
/// 主空间还未初始化时，会强制进入 onboarding，而不是普通解锁态。
enum UnlockStage {
    case onboardingWelcome
    case onboardingPrivacy
    case onboardingPasscodeType
    case onboardingPasscodeEntry
    case onboardingPasscodeConfirmation
    case onboardingBiometrics
    case onboardingSecondSpace
    case onboardingComplete
    case locked

    var isOnboardingFlow: Bool {
        switch self {
        case .onboardingWelcome,
             .onboardingPrivacy,
             .onboardingPasscodeType,
             .onboardingPasscodeEntry,
             .onboardingPasscodeConfirmation,
             .onboardingBiometrics,
             .onboardingSecondSpace,
             .onboardingComplete:
            return true
        case .locked:
            return false
        }
    }
}

@MainActor
final class UnlockViewModel: ObservableObject {
    @Published var stage: UnlockStage = .locked
    @Published var onboardingBiometricsEnabled = AppSettingsKey.defaultBiometricUnlockEnabled
    @Published var errorMessage: String?
    @Published var hasAttemptedAutomaticBiometricUnlock = false

    private(set) var recentPrimaryPasscode = ""
    private(set) var recentPrimaryKind: AppPasscodeKind = .fourDigits

    /// 根据当前会话状态，决定显示首次引导还是普通锁定页。
    func prepare(using session: AppSessionViewModel) {
        hasAttemptedAutomaticBiometricUnlock = false
        print("[SecurityFolder][Unlock] prepare shouldRunPrimaryOnboarding=\(session.shouldRunPrimaryOnboarding) isSpaceAConfigured=\(session.isPasscodeConfigured(for: .spaceA)) isSpaceBConfigured=\(session.isPasscodeConfigured(for: .spaceB))")

        if session.shouldRunPrimaryOnboarding {
            stage = .onboardingWelcome
            onboardingBiometricsEnabled = session.isBiometricUnlockEnabled
            print("[SecurityFolder][Unlock] Entering onboarding flow.")
            return
        }

        stage = .locked
        print("[SecurityFolder][Unlock] Entering locked flow.")
    }

    func availableSpaces(using session: AppSessionViewModel) -> [VaultSpaceKind] {
        VaultSpaceKind.allCases.filter { session.isPasscodeConfigured(for: $0) }
    }

    func advanceOnboarding() {
        errorMessage = nil

        switch stage {
        case .onboardingWelcome:
            stage = .onboardingPrivacy
        case .onboardingPrivacy:
            stage = .onboardingPasscodeType
        case .onboardingPasscodeType, .onboardingPasscodeEntry, .onboardingPasscodeConfirmation, .onboardingBiometrics, .onboardingSecondSpace, .onboardingComplete, .locked:
            break
        }
    }

    func retreatOnboarding() {
        errorMessage = nil

        switch stage {
        case .onboardingPrivacy:
            stage = .onboardingWelcome
        case .onboardingPasscodeType:
            stage = .onboardingPrivacy
        case .onboardingPasscodeEntry:
            stage = .onboardingPasscodeType
        case .onboardingPasscodeConfirmation:
            stage = .onboardingPasscodeEntry
        case .onboardingBiometrics:
            stage = .onboardingPasscodeConfirmation
        case .onboardingSecondSpace:
            stage = .onboardingBiometrics
        case .onboardingWelcome, .onboardingComplete, .locked:
            break
        }
    }

    func continueFromPasscodeType(with draft: PasscodeDraftController) {
        draft.reset(kind: draft.kind)
        errorMessage = nil
        stage = .onboardingPasscodeEntry
    }

    func submitPrimaryOnboardingPasscodeEntry(draft: PasscodeDraftController) {
        draft.sanitize()
        let candidate = draft.normalizedPrimaryValue
        print("[SecurityFolder][Unlock] submitPrimaryOnboardingPasscodeEntry kind=\(draft.kind.rawValue) primaryLength=\(candidate.count)")

        guard draft.kind.isValid(candidate) else {
            errorMessage = String(localized: "密码格式不符合要求。")
            return
        }

        errorMessage = nil
        draft.confirmationValue = ""
        stage = .onboardingPasscodeConfirmation
    }

    func submitPrimaryOnboardingPasscode(
        draft: PasscodeDraftController,
        using session: AppSessionViewModel
    ) {
        draft.sanitize()
        print("[SecurityFolder][Unlock] submitPrimaryOnboardingPasscode kind=\(draft.kind.rawValue) primaryLength=\(draft.normalizedPrimaryValue.count) confirmationLength=\(draft.normalizedConfirmationValue.count)")

        guard draft.kind.isValid(draft.normalizedPrimaryValue) else {
            errorMessage = String(localized: "密码格式不符合要求。")
            return
        }

        guard draft.normalizedPrimaryValue == draft.normalizedConfirmationValue else {
            errorMessage = String(localized: "两次输入的密码不一致。")
            return
        }

        // 这里先只把密码暂存在内存里，不立刻创建空间密钥。
        // 否则用户从第 6/7 页返回再修改密码时，容易进入“空间已写入但流程未完成”的半初始化状态。
        recentPrimaryPasscode = draft.normalizedPrimaryValue
        recentPrimaryKind = draft.kind
        errorMessage = nil
        stage = .onboardingBiometrics
    }

    func finishOnboarding(using session: AppSessionViewModel) {
        guard !recentPrimaryPasscode.isEmpty else {
            errorMessage = String(localized: "请先设置主空间密码。")
            stage = .onboardingPasscodeEntry
            return
        }

        switch session.configureInitialPasscode(
            recentPrimaryPasscode,
            kind: recentPrimaryKind,
            for: .spaceA,
            unlockAfterSetup: false
        ) {
        case .success:
            print("[SecurityFolder][Unlock] Primary passcode configured at onboarding completion.")
        case let .failure(message):
            errorMessage = message
            stage = .onboardingPasscodeConfirmation
            print("[SecurityFolder][Unlock] Failed to configure primary passcode at onboarding completion: \(message)")
            return
        }

        session.setBiometricUnlockEnabled(onboardingBiometricsEnabled)
        stage = .onboardingComplete
        errorMessage = nil
    }

    func finishBiometricOnboarding(enabled: Bool, using session: AppSessionViewModel) {
        onboardingBiometricsEnabled = enabled
        session.setBiometricUnlockEnabled(enabled)
        stage = .onboardingSecondSpace
        errorMessage = nil
    }

    /// 首次设置完成后，沿用正常解锁链路进入主空间，避免出现特殊分支状态。
    func unlockPrimaryAfterOnboarding(using session: AppSessionViewModel) {
        guard !recentPrimaryPasscode.isEmpty else { return }
        _ = session.unlock(space: .spaceA, using: recentPrimaryPasscode)
    }

    func submitUnlock(passcode: String, using session: AppSessionViewModel) {
        let kind = preferredUnlockKind(using: session)
        let normalizedPasscode = kind.normalized(passcode)
        print("[SecurityFolder][Unlock] submitUnlock kind=\(kind.rawValue) inputLength=\(normalizedPasscode.count)")

        switch session.unlock(using: normalizedPasscode) {
        case .success:
            errorMessage = nil
            print("[SecurityFolder][Unlock] Unlock succeeded.")
        case let .failure(message):
            errorMessage = message
            print("[SecurityFolder][Unlock] Unlock failed: \(message)")
        }
    }

    func unlockWithBiometrics(using session: AppSessionViewModel) {
        unlockWithBiometrics(using: session, isAutomaticAttempt: false)
    }

    func unlockWithBiometrics(using session: AppSessionViewModel, isAutomaticAttempt: Bool) {
        switch session.unlockPrimaryWithBiometrics() {
        case .success:
            errorMessage = nil
            print("[SecurityFolder][Unlock] Biometric unlock succeeded. automatic=\(isAutomaticAttempt)")
        case let .failure(message):
            let shouldSuppress = isAutomaticAttempt
                && session.consumeSuppressAutomaticBiometricErrors()
                && isSilentBiometricFailureMessage(message)

            session.recordBiometricFailure(message: message)

            if shouldSuppress {
                errorMessage = nil
                print("[SecurityFolder][Unlock] Suppressed automatic biometric failure: \(message)")
            } else {
                errorMessage = session.consumePendingUnlockMessage() ?? message
                print("[SecurityFolder][Unlock] Biometric unlock failed. automatic=\(isAutomaticAttempt) message=\(message)")
            }
        }
    }

    func preferredUnlockKind(using session: AppSessionViewModel) -> AppPasscodeKind {
        if let primaryKind = session.configuredPasscodeKind(for: .spaceA) {
            return primaryKind
        }

        if let secondaryKind = session.configuredPasscodeKind(for: .spaceB) {
            return secondaryKind
        }

        return .fourDigits
    }

    private func isSilentBiometricFailureMessage(_ message: String) -> Bool {
        message == String(localized: "生物识别已取消。")
    }
}
