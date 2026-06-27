import Foundation
import Combine
import SwiftUI
import StoreKit

enum MembershipTier: Int, Comparable, CaseIterable, Identifiable {
    case free = 0
    case fullMember = 1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .free: return String(localized: "普通用户")
        case .fullMember: return String(localized: "会员用户")
        }
    }

    var shortSubtitle: String {
        switch self {
        case .free: return String(localized: "有限储存数量")
        case .fullMember: return String(localized: "无限储存数量")
        }
    }

    var accentColor: Color {
        switch self {
        case .free: return .secondary
        case .fullMember: return .red
        }
    }

    static func < (lhs: MembershipTier, rhs: MembershipTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum MembershipProductKind: String, CaseIterable, Identifiable {
    case fullMember = "com.cinmouice.MediaVault.Pro"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullMember: return String(localized: "购买私影相册完整版")
        }
    }

    var subtitle: String {
        switch self {
        case .fullMember: return String(localized: "永久解锁无限储存数量")
        }
    }

    var associatedTier: MembershipTier {
        switch self {
        case .fullMember: return .fullMember
        }
    }
}

@MainActor
class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    @Published private(set) var purchasedTier: MembershipTier = .free

    var currentTier: MembershipTier {
        return purchasedTier
    }

    var entitlementSummary: [String] {
        switch currentTier {
        case .free:
            return [
                String(localized: "最多可导入 20 个照片和视频")
            ]
        case .fullMember:
            return [
                String(localized: "无限制导入照片和视频")
            ]
        }
    }

    private init() {}

    func refreshFromStore() {
        Task {
            var highestTier: MembershipTier = .free
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result else { continue }
                if let kind = MembershipProductKind(rawValue: transaction.productID) {
                    if kind.associatedTier > highestTier {
                        highestTier = kind.associatedTier
                    }
                }
            }
            purchasedTier = highestTier
            syncSharedImportMembershipState()
        }
    }

    private func syncSharedImportMembershipState() {
        var state = SharedImportStore.shared.appState
        state.currentTierRawValue = currentTier.rawValue
        SharedImportStore.shared.appState = state
    }
}

struct PurchaseNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
class StoreKitManager: ObservableObject {
    static let shared = StoreKitManager()

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasingProductID: String?
    @Published private(set) var isRestoringPurchases = false
    @Published private(set) var isLoadingProducts = false
    @Published var currentNotice: PurchaseNotice?

    private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = Task {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                SubscriptionManager.shared.refreshFromStore()
            }
        }
        loadProducts()
        SubscriptionManager.shared.refreshFromStore()
    }

    func activate() {
        loadProducts()
        SubscriptionManager.shared.refreshFromStore()
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts() {
        isLoadingProducts = true
        Task {
            do {
                let identifiers = MembershipProductKind.allCases.map { $0.rawValue }
                let loadedProducts = try await Product.products(for: identifiers)
                products = loadedProducts.sorted { lhs, rhs in
                    let lhsIndex = identifiers.firstIndex(of: lhs.id) ?? Int.max
                    let rhsIndex = identifiers.firstIndex(of: rhs.id) ?? Int.max
                    return lhsIndex < rhsIndex
                }
            } catch {
                print("Failed to load products: \(error)")
            }
            isLoadingProducts = false
        }
    }

    func product(for kind: MembershipProductKind) -> Product? {
        products.first(where: { $0.id == kind.rawValue })
    }

    func purchase(_ kind: MembershipProductKind) async {
        guard let product = product(for: kind) else {
            currentNotice = PurchaseNotice(
                title: String(localized: "提示"),
                message: String(localized: "商品正在加载中，请稍后再试。")
            )
            return
        }
        purchasingProductID = kind.rawValue
        do {
            let result = try await product.purchase()
            switch result {
            case .success(.verified(let transaction)):
                await transaction.finish()
                SubscriptionManager.shared.refreshFromStore()
                currentNotice = PurchaseNotice(
                    title: String(localized: "购买成功"),
                    message: String(localized: "感谢你的支持，所有权益已解锁。")
                )
            case .success(.unverified):
                currentNotice = PurchaseNotice(
                    title: String(localized: "购买待确认"),
                    message: String(localized: "购买已受理，但未通过验证。")
                )
            case .pending:
                currentNotice = PurchaseNotice(
                    title: String(localized: "购买处理中"),
                    message: String(localized: "这笔交易正在等待授权或许可。")
                )
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            currentNotice = PurchaseNotice(title: String(localized: "购买失败"), message: error.localizedDescription)
        }
        purchasingProductID = nil
    }

    func restorePurchases() async {
        isRestoringPurchases = true
        do {
            try await AppStore.sync()
            SubscriptionManager.shared.refreshFromStore()
            currentNotice = PurchaseNotice(
                title: String(localized: "恢复成功"),
                message: String(localized: "感谢您，尊敬的会员用户")
            )
        } catch {
            currentNotice = PurchaseNotice(title: String(localized: "恢复失败"), message: error.localizedDescription)
        }
        isRestoringPurchases = false
    }
}
