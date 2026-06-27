import SwiftUI
import StoreKit
import UIKit

struct MembershipCenterView: View {
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @ObservedObject private var storeKitManager = StoreKitManager.shared
    @Environment(\.dismiss) private var dismiss
    
    // 交互状态
    @State private var isPressing = false
    @State private var rotationAngle: Double = 0
    @State private var previousAngle: Double = 0
    
    // 礼花背景动画状态
    @State private var celebrationRotation: Double = 0
    @State private var celebrationScale: CGFloat = 1
    
    var isPresentedAsSheet: Bool
    
    init(isPresentedAsSheet: Bool = false) {
        self.isPresentedAsSheet = isPresentedAsSheet
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // MARK: - 头部徽标区域
                VStack(spacing: 18) {
                    HStack {
                        Spacer() // 推挤居中
                        
                        GeometryReader { proxy in
                            let size = proxy.size
                            let center = CGPoint(x: size.width / 2, y: size.height / 2)
                            
                            ZStack {
                                // 1. 礼花/点缀背景
                                CelebrationParticles(
                                    tier: subscriptionManager.currentTier,
                                    baseColor: subscriptionManager.currentTier.accentColor,
                                    rotation: celebrationRotation
                                )
                                .scaleEffect(1.2)
                                .scaleEffect(celebrationScale)
                                
                                // 2. 交互徽章本体
                                ZStack {
                                    Image("custom.wheel")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 95, height: 95)
                                        .foregroundStyle(
                                            LinearGradient(
                                                colors: [
                                                    subscriptionManager.currentTier.accentColor.opacity(0.8),
                                                    subscriptionManager.currentTier.accentColor
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                }
                                .frame(width: 150, height: 150)
                                .scaleEffect(isPressing ? 0.94 : 1)
                                .rotationEffect(.degrees(rotationAngle))
                                .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isPressing)
                                .shadow(
                                    color: subscriptionManager.currentTier.accentColor.opacity(isPressing ? 0.15 : 0.25),
                                    radius: isPressing ? 12 : 20,
                                    x: 0,
                                    y: isPressing ? 6 : 12
                                )
                            }
                            .position(x: center.x, y: center.y)
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                    .onChanged { value in
                                        let location = value.location
                                        let dx = location.x - center.x
                                        let dy = location.y - center.y
                                        let currentAngle = atan2(dy, dx) * 180 / .pi
                                        
                                        if !isPressing {
                                            isPressing = true
                                            previousAngle = currentAngle
                                            triggerHaptic()
                                        } else {
                                            var delta = currentAngle - previousAngle
                                            // 处理跨越 180 度的突变问题
                                            if delta > 180 {
                                                delta -= 360
                                            } else if delta < -180 {
                                                delta += 360
                                            }
                                            rotationAngle += delta
                                            previousAngle = currentAngle
                                        }
                                    }
                                    .onEnded { _ in
                                        isPressing = false
                                    }
                            )
                        }
                        .frame(width: 150, height: 150)
                        
                        Spacer() // 推挤居中
                    }
                    .frame(height: 190) // 给上下留出空间给礼花展示
                    
                    // 把隐藏的 Debug 开关转移到文字区域，作为彩蛋
                    VStack(spacing: 6) {
                        Text(subscriptionManager.currentTier.title)
                            .font(.title2.weight(.bold))
                        Text(subscriptionManager.currentTier.shortSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .contentShape(Rectangle()) // 增加文字区域的点击面积
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .padding(.horizontal, 24)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                // 去掉了整个卡片点击旋转，因为现在使用拖拽旋转手势
                
                // MARK: - 权益说明
                VStack(alignment: .leading, spacing: 14) {
                    Text(String(localized: "会员说明"))
                        .font(.headline)
                    ForEach(subscriptionManager.entitlementSummary, id: \.self) { item in
                        // 修改：去掉默认的对号图标，可以改成普通的 Text 或者保留 Label 但不提供图
                        Text(item)
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                purchaseSection

                Button {
                    Task {
                        await storeKitManager.restorePurchases()
                        subscriptionManager.refreshFromStore()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if storeKitManager.isRestoringPurchases {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(String(localized: "恢复购买"))
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .underline()
                    }
                }
                .disabled(storeKitManager.isRestoringPurchases)
                .padding(.top, 10)
                .padding(.bottom, 20) // 给底部留出一些呼吸空间
            }
            .padding()
        }
        .navigationTitle(String(localized: "会员中心"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isPresentedAsSheet {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .fontWeight(.medium)
                    }
                    .accessibilityLabel(String(localized: "关闭"))
                }
            }
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .alert(storeKitManager.currentNotice?.title ?? String(localized: "购买提示"), isPresented: purchaseAlertPresented) {
            Button(String(localized: "知道了"), role: .cancel) {
                storeKitManager.currentNotice = nil
            }
        } message: {
            Text(storeKitManager.currentNotice?.message ?? "")
        }
        .onAppear {
            startCelebrationAnimation(resetRotation: true)
            subscriptionManager.refreshFromStore()
        }
        .onChange(of: subscriptionManager.currentTier) { oldTier, newTier in
            guard oldTier != newTier else { return }
            startCelebrationAnimation(resetRotation: true)

            if newTier == .fullMember {
                triggerMembershipUnlockAnimation()
            }
        }
    }
    
    private func triggerHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    private func triggerMembershipUnlockAnimation() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        celebrationScale = 0.88

        withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) {
            celebrationScale = 1.16
        }

        withAnimation(.spring(response: 0.30, dampingFraction: 0.82).delay(0.10)) {
            celebrationScale = 1
        }
    }

    private func startCelebrationAnimation(resetRotation: Bool) {
        if resetRotation {
            celebrationRotation = 0
        }

        withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
            celebrationRotation = 360
        }
    }

    private var purchaseAlertPresented: Binding<Bool> {
        Binding(
            get: {
                storeKitManager.currentNotice != nil
            },
            set: { isPresented in
                if !isPresented {
                    storeKitManager.currentNotice = nil
                }
            }
        )
    }

    @ViewBuilder
    private var purchaseSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(subscriptionManager.currentTier == .fullMember ? String(localized: "购买状态") : String(localized: "购买会员"))
                .font(.headline)

            if subscriptionManager.currentTier == .fullMember {
                Text(String(localized: "感谢您的购买和支持，开发者感到无与伦比的幸福！"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if availableProducts.isEmpty {
                Text(String(localized: "正在读取商品信息，请稍后。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(availableProducts, id: \.id) { kind in
                    purchaseCard(for: kind)
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var availableProducts: [MembershipProductKind] {
        switch subscriptionManager.currentTier {
        case .free:
            return [.fullMember]
        case .fullMember:
            return []
        }
    }

    private func purchaseCard(for kind: MembershipProductKind) -> some View {
        let product = storeKitManager.product(for: kind)
        let isPurchasing = storeKitManager.purchasingProductID == kind.rawValue
        let displayPrice = product?.displayPrice

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                membershipArtwork(for: kind)

                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title)
                        .font(.headline)
                    Text(kind.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Button {
                Task {
                    await storeKitManager.purchase(kind)
                    subscriptionManager.refreshFromStore()
                }
            } label: {
                HStack {
                    Spacer()
                    if isPurchasing {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(
                        displayPrice.map {
                            String.localizedStringWithFormat(String(localized: "立即购买 %@"), $0)
                        } ?? String(localized: "立即购买")
                    )
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Spacer()
                }
                .padding(.vertical, 12)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(product == nil || isPurchasing || storeKitManager.isLoadingProducts)
        }
        .padding(16)
        .background(Color(UIColor.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    
    private func membershipArtwork(for kind: MembershipProductKind) -> some View {
        Image("Vip")
            .resizable()
            .scaledToFill()
            .frame(width: 64, height: 64)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(subscriptionManager.currentTier.accentColor.opacity(0.12), lineWidth: 1)
            )
    }
    
}

// MARK: - 礼花/粒子背景组件
struct CelebrationParticles: View {
    var tier: MembershipTier
    var baseColor: Color
    var rotation: Double
    
    var isFree: Bool {
        tier == .free
    }
    
    var isBigMember: Bool {
        tier == .fullMember
    }
    
    // 给星星预设一组彩虹色，让它看起来“花一点”
    let starColors: [Color] = [.yellow, .pink, .cyan, .orange, .purple, .green, .mint]
    
    var body: some View {
        ZStack {
            // 如果是免费用户，整个背景都不渲染，保持干净
            if !isFree {
                // 1. 小会员和大会员都有的：数字粒子 (1和0)
                ForEach(0..<10) { i in
                    Text(i % 2 == 0 ? "1" : "0")
                        .font(.system(size: i % 2 == 0 ? 12 : 16, weight: .bold, design: .monospaced))
                        .foregroundColor(starColors[i % starColors.count].opacity(0.75))
                        .offset(y: -75) // 扩散距离
                        .rotationEffect(.degrees(Double(i) * 36 + rotation))
                }
                
                // 2. 只有大满足会员才有的：数字粒子 (更多 1 和 0) 和微小彩块
                if isBigMember {
                    // 内层数字特效
                    ForEach(0..<8) { i in
                        Text(i % 2 == 0 ? "0" : "1")
                            .font(.system(size: i % 2 == 0 ? 16 : 24, weight: .bold, design: .monospaced))
                            // 使用预设的彩色数组循环上色
                            .foregroundColor(starColors[(i + 3) % starColors.count].opacity(0.85))
                            .offset(y: -95)
                            .rotationEffect(.degrees(Double(i) * 45 - rotation * 1.5))
                    }
                    
                    // 最外层彩色微小碎块（像像素点一样）
                    ForEach(0..<6) { i in
                        Rectangle()
                            .fill(starColors[(i + 2) % starColors.count].opacity(0.6))
                            .frame(width: 4, height: 4)
                            .offset(y: -115)
                            .rotationEffect(.degrees(Double(i) * 60 + rotation * 0.8))
                    }
                }
            }
        }
        // 淡淡的发光底座感
        .shadow(color: isFree ? .clear : baseColor.opacity(0.3), radius: 4, x: 0, y: 0)
    }
}

#Preview {
    NavigationStack {
        MembershipCenterView()
    }
}
