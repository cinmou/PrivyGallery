//
//  AppInformationViews.swift
//  SecurityFolder
//

import SwiftUI
import UIKit

enum AppMetadata {
    static let displayNameCN = "私影相册"
    static let displayNameEN = "PrivyGallery"
    static let contactEmail = "liuruhongyi@gmail.com"
    static let appStoreReviewURLString = "itms-apps://itunes.apple.com/app/id6765981187?action=write-review"
    static let openSourceURLString = "https://github.com/cinmou/PrivyGallery"
    static let privacyPolicyURLString = "https://quaint-windscreen-5b3.notion.site/Privacy-Policy-for-Priv-Media-355474154efe8050bde7e2106ade7a83"
    static let standardEULAURLString = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"

    static var appName: String {
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        return displayName ?? bundleName ?? displayNameCN
    }

    static var versionDisplay: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(shortVersion) (\(build))"
    }
}

struct AppInformationView: View {
    var body: some View {
        List {
            Section(String(localized: "应用说明")) {
                Text(String(localized: "本应用是一款专注于本地隐私保护的加密相册，旨在为你的私密照片与视频提供强大的的安全保障。"))
                Text(String(localized: "应用采用 AES-GCM 分块加密技术，确保所有媒体文件始终以密文形式存储于本地沙盒。我们不设服务器，不进行云端同步，数据完全由你掌握。"))
            }

            Section(String(localized: "使用指南")) {
                guideRow(
                    title: String(localized: "双空间设置"),
                    detail: String(localized: "本应用可以创建数据互相独立的两个空间，输入不同的密码进入。你可以通过“设置 -> 密码与空间 -> 空间管理”分别为两个空间配置不同的密码与名称。在启动时的锁定界面，直接输入对应的密码即可进入对应的空间，两者的数据与密钥完全隔离。")
                )
                guideRow(
                    title: String(localized: "双空间无感切换"),
                    detail: String(localized: "在创建了两个空间之后，您可以通过“设置 -> 密码与空间 -> 双空间管理”相同界面下的双空间管理来选择使用生物识别信息来解锁的是哪一个空间，也可以按照具体的时段来选择解锁的空间")
                )
                guideRow(
                    title: String(localized: "胁迫密码"),
                    detail: String(localized: "当你通过通过“设置 -> 密码与空间 -> 胁迫密码“阅读说明并设置了胁迫密码后，若你面临必须解锁的不可抗力，可以在锁定界面输入该“胁迫密码”。一旦输入，应用将执行最高级别的应急清空服务：瞬间删除所有加密媒体、元数据索引、缩略图缓存以及本地设置，请谨慎使用该功能。")
                )
                guideRow(
                    title: String(localized: "屏幕隐私与录屏防窥"),
                    detail: String(localized: "应用会自动监控系统行为，当你切换到多任务界面或回到桌面时，会自动显示隐私遮罩层。此外，开启屏幕隐私保护后，若系统检测到正在进行录屏或截屏，应用会在监测到的第一时间自动锁定，尽可能防止隐私内容被非法记录。")
                )
                guideRow(
                    title: String(localized: "高级数据保护"),
                    detail: String(localized: "高级数据保护是会员功能。开启后，媒体库首页会出现强加密媒体库，并允许你创建强加密相册。强加密媒体不会显示缩略图，只会以列表方式展示文件名称；点击后会通过独立的内存解密预览链路查看原图或原视频，不会把原始内容临时写回硬盘。普通媒体库不受影响，仍然可以正常显示缩略图、封面并进行预览。")
                )
                guideRow(
                    title: String(localized: "空间备份与迁移"),
                    detail: String(localized: "你可以通过“设置 -> 备份与恢复”将当前空间整体导出为加密的 .vault 文件。导入备份时，应用会使用当前空间的新密钥重新加密写入，迁移完成后请根据提示重启应用以刷新媒体库。")
                )
            }

            Section(String(localized: "权限说明")) {
                guideRow(
                    title: String(localized: "照片"),
                    detail: String(localized: "仅在导入照片和视频时需要访问相册权限。应用永远不会将你的媒体上传到任何云端服务器。")
                )
                guideRow(
                    title: String(localized: "生物识别"),
                    detail: String(localized: "用于便捷地解锁你的空间。")
                )
            }

        }
        .navigationTitle(String(localized: "使用指南"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func guideRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body.weight(.medium))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct AboutAppView: View {
    @Environment(\.openURL) private var openURL
    @State private var reviewErrorMessage: String?

    var body: some View {
        List {
            Section {
                PressableAppIconCard()
                    .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 20, trailing: 16))
                    .listRowSeparator(.hidden)
            }

            Section {
                HStack(spacing: 12) {
                    Image(systemName: "fleuron")
                        .foregroundStyle(.primary)
                        .imageScale(.medium)
                        .frame(width: 29) // 固定宽度防止对齐偏移
                    
                    Text(String(localized: "当前版本"))
                    
                    Spacer()
                    
                    Text(AppMetadata.versionDisplay)
                        .foregroundStyle(.secondary)
                }
                Button {
                    contactDeveloper()
                } label: {
                    Label(String(localized: "联系开发者"), systemImage: "envelope")
                        .foregroundStyle(.primary)
                }

                Button {
                    openSourceRepository()
                } label: {
                    Label(String(localized: "开源代码"), image: "github")
                        .foregroundStyle(.primary)
                }

                Button {
                    requestAppReview()
                } label: {
                    Label(String.localizedStringWithFormat(String(localized: "给 %@ 评分"), AppMetadata.appName), systemImage: "star")
                        .foregroundStyle(.primary)
                }
            } header: {
                Text(String.localizedStringWithFormat(String(localized: "关于 %@"), AppMetadata.appName))
            } footer: {
                Text(String(localized: "Copyright © 2026 Ruhongyi Liu. All rights reserved."))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(String(localized: "版本信息"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(String(localized: "暂时无法打开"), isPresented: reviewErrorBinding) {
            Button(String(localized: "好"), role: .cancel) { }
        } message: {
            Text(reviewErrorMessage ?? String(localized: "请稍后再试。"))
        }
    }

    // MARK: - 支持与反馈逻辑
    
    private var reviewErrorBinding: Binding<Bool> {
        Binding(
            get: { reviewErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    reviewErrorMessage = nil
                }
            }
        )
    }

    private func contactDeveloper() {
        guard let url = URL(string: "mailto:\(AppMetadata.contactEmail)") else {
            reviewErrorMessage = String(localized: "邮件地址格式无效。")
            return
        }
        openURL(url)
    }

    private func openSourceRepository() {
        guard let url = URL(string: AppMetadata.openSourceURLString) else {
            reviewErrorMessage = String(localized: "暂时无法打开")
            return
        }
        openURL(url)
    }

    private func requestAppReview() {
        guard let url = URL(string: AppMetadata.appStoreReviewURLString) else {
            reviewErrorMessage = String(localized: "暂时无法打开")
            return
        }
        openURL(url)
    }
}

private struct PressableAppIconCard: View {
    @State private var isPressing = false
    @State private var touchLocation: CGPoint = CGPoint(x: 50, y: 50)

    private let cardSize: CGFloat = 100

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer() // 左边推挤
                
                GeometryReader { proxy in
                    let size = proxy.size
                    let normalizedX = ((touchLocation.x / max(size.width, 1)) - 0.5) * 2
                    let normalizedY = ((touchLocation.y / max(size.height, 1)) - 0.5) * 2
                    let rotationX = isPressing ? max(-10, min(10, -normalizedY * 10)) : 0
                    let rotationY = isPressing ? max(-10, min(10, normalizedX * 10)) : 0

                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .scaleEffect(isPressing ? 0.96 : 1)
                        .rotation3DEffect(.degrees(rotationX), axis: (x: 1, y: 0, z: 0))
                        .rotation3DEffect(.degrees(rotationY), axis: (x: 0, y: 1, z: 0))
                        .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isPressing)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { value in
                                    touchLocation = value.location
                                    if !isPressing {
                                        isPressing = true
                                    }
                                }
                                .onEnded { _ in
                                    isPressing = false
                                    touchLocation = CGPoint(x: size.width / 2, y: size.height / 2)
                                }
                        )
                }
                .frame(width: cardSize, height: cardSize)
                
                Spacer() // 右边推挤
            }
            
            // 确保文字在整个 List 宽度中绝对居中
            Text(AppMetadata.appName)
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.vertical, 8)
    }
    
}


#Preview {
    NavigationStack {
        AboutAppView()
    }
}
