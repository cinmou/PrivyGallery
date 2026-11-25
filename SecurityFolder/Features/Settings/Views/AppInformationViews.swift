//
//  AppInformationViews.swift
//  SecurityFolder
//

import SwiftUI
import UIKit

enum AppMetadata {
    static let displayNameCN = "私影相册"
    static let contactEmail = "liuruhongyi@gmail.com"
    static let appStoreReviewURLString = "itms-apps://itunes.apple.com/app/id6765981187?action=write-review"
    static let appStoreShareURLString = "https://apps.apple.com/app/id6765981187"
    static let developerAppStoreURLString = "https://apps.apple.com/developer/id1891542411"
    static let xiaohongshuURLString = "https://xhslink.cn/m/40pYzqFeaMP"
    static let coolapkURLString = "https://www.coolapk.com/u/3792313"
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
        Group {
        #if targetEnvironment(macCatalyst)
        MacInformationPage {
            MacInformationSection(String(localized: "应用说明")) {
                Text(String(localized: "本应用是一款专注于本地隐私保护的加密相册，旨在为你的私密照片与视频提供强大的的安全保障。"))
                Text(String(localized: "应用采用 AES-GCM 分块加密技术，确保所有媒体文件始终以密文形式存储于本地沙盒。我们不设服务器，不进行云端同步，数据完全由你掌握。"))
            }

            MacInformationSection(String(localized: "使用指南")) {
                guideRow(
                    title: String(localized: "双空间设置"),
                    detail: String(localized: "本应用可以创建数据互相独立的两个空间，输入不同的密码进入。你可以通过“设置 -> 隐私与安全 -> 空间管理”分别为两个空间配置不同的密码与名称。在启动时的锁定界面，直接输入对应的密码即可进入对应的空间，两者的数据与密钥完全隔离。")
                )
                guideRow(
                    title: String(localized: "双空间无感切换"),
                    detail: String(localized: "在创建了两个空间之后，您可以通过“设置 -> 隐私与安全 -> 空间管理”选择使用生物识别信息来解锁的是哪一个空间，也可以按照具体的时段来选择解锁的空间")
                )
                guideRow(
                    title: String(localized: "胁迫密码"),
                    detail: String(localized: "当你通过“设置 -> 隐私与安全 -> 密码管理”阅读说明并设置了胁迫密码后，若你面临必须解锁的不可抗力，可以在锁定界面输入该“胁迫密码”。一旦输入，应用将执行最高级别的应急清空服务：瞬间删除所有加密媒体、元数据索引、缩略图缓存以及本地设置，请谨慎使用该功能。")
                )
                guideRow(
                    title: String(localized: "屏幕隐私与录屏防窥"),
                    detail: String(localized: "切换到后台或多任务界面时，应用会遮挡内容；录屏或投屏期间也会隐藏内容。开启“侦测到截屏后锁定”后，应用会在收到截屏通知时锁定，已经保存的截图不会被撤回。")
                )
                guideRow(
                    title: String(localized: "安全预览模式"),
                    detail: String(localized: "安全预览模式是会员功能。开启后，媒体库首页会出现强加密媒体库，并允许你创建强加密相册。强加密媒体不会显示缩略图，只会以列表方式展示文件名称；点击后会通过独立的内存解密预览链路查看原图或原视频，不会把原始内容临时写回硬盘。普通媒体库不受影响，仍然可以正常显示缩略图、封面并进行预览。")
                )
                guideRow(
                    title: String(localized: "空间备份与迁移"),
                    detail: String(localized: "你可以通过“设置 -> 备份与恢复”将当前空间整体导出为加密的 .vault 文件。导入备份时，应用会使用当前空间的新密钥重新加密写入，迁移完成后请根据提示重启应用以刷新媒体库。")
                )
            }

            MacInformationSection(String(localized: "权限说明")) {
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
        #else
        List {
            Section(String(localized: "应用说明")) {
                Text(String(localized: "本应用是一款专注于本地隐私保护的加密相册，旨在为你的私密照片与视频提供强大的的安全保障。"))
                Text(String(localized: "应用采用 AES-GCM 分块加密技术，确保所有媒体文件始终以密文形式存储于本地沙盒。我们不设服务器，不进行云端同步，数据完全由你掌握。"))
            }

            Section(String(localized: "使用指南")) {
                guideRow(
                    title: String(localized: "双空间设置"),
                    detail: String(localized: "本应用可以创建数据互相独立的两个空间，输入不同的密码进入。你可以通过“设置 -> 隐私与安全 -> 空间管理”分别为两个空间配置不同的密码与名称。在启动时的锁定界面，直接输入对应的密码即可进入对应的空间，两者的数据与密钥完全隔离。")
                )
                guideRow(
                    title: String(localized: "双空间无感切换"),
                    detail: String(localized: "在创建了两个空间之后，您可以通过“设置 -> 隐私与安全 -> 空间管理”选择使用生物识别信息来解锁的是哪一个空间，也可以按照具体的时段来选择解锁的空间")
                )
                guideRow(
                    title: String(localized: "胁迫密码"),
                    detail: String(localized: "当你通过“设置 -> 隐私与安全 -> 密码管理”阅读说明并设置了胁迫密码后，若你面临必须解锁的不可抗力，可以在锁定界面输入该“胁迫密码”。一旦输入，应用将执行最高级别的应急清空服务：瞬间删除所有加密媒体、元数据索引、缩略图缓存以及本地设置，请谨慎使用该功能。")
                )
                guideRow(
                    title: String(localized: "屏幕隐私与录屏防窥"),
                    detail: String(localized: "切换到后台或多任务界面时，应用会遮挡内容；录屏或投屏期间也会隐藏内容。开启“侦测到截屏后锁定”后，应用会在收到截屏通知时锁定，已经保存的截图不会被撤回。")
                )
                guideRow(
                    title: String(localized: "安全预览模式"),
                    detail: String(localized: "安全预览模式是会员功能。开启后，媒体库首页会出现强加密媒体库，并允许你创建强加密相册。强加密媒体不会显示缩略图，只会以列表方式展示文件名称；点击后会通过独立的内存解密预览链路查看原图或原视频，不会把原始内容临时写回硬盘。普通媒体库不受影响，仍然可以正常显示缩略图、封面并进行预览。")
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
        #endif
        }
        .navigationTitle(String(localized: "使用指南"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func guideRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body.weight(.medium))
            Text(detail)
                #if targetEnvironment(macCatalyst)
                .font(.body)
                .foregroundStyle(.primary)
                #else
                .font(.subheadline)
                .foregroundStyle(.secondary)
                #endif
        }
        #if targetEnvironment(macCatalyst)
        .padding(.vertical, 8)
        #else
        .padding(.vertical, 2)
        #endif
    }
}

struct AboutAppView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    @State private var reviewErrorMessage: String?

    private var showsMainlandSocialLinks: Bool {
        let language = Locale.Language(identifier: locale.language.maximalIdentifier)
        return language.languageCode == .chinese
            && language.script == .hanSimplified
    }

    var body: some View {
        Group {
        #if targetEnvironment(macCatalyst)
        ScrollView {
            VStack(spacing: 20) {
                PressableAppIconCard()
                Text(AppMetadata.versionDisplay)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                MacSettingsSection(String.localizedStringWithFormat(String(localized: "关于 %@"), AppMetadata.appName)) {
                    macAboutLinkRow(String(localized: "联系开发者"), systemImage: "envelope", action: contactDeveloper)
                    Divider()
                    macAboutCustomImageRow(String(localized: "开源代码"), imageName: "github", action: openSourceRepository)
                    Divider()
                    macAboutLinkRow(String.localizedStringWithFormat(String(localized: "给 %@ 评分"), AppMetadata.appName), systemImage: "star", action: requestAppReview)
                    if let shareURL = URL(string: AppMetadata.appStoreShareURLString) {
                        Divider()
                        ShareLink(item: shareURL) {
                            HStack {
                                Label(String(localized: "分享给朋友"), systemImage: "square.and.arrow.up")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                MacSettingsSection(String(localized: "更多与关注")) {
                    macAboutLinkRow(String(localized: "更多应用"), systemImage: "square.grid.2x2") {
                        openExternalLink(AppMetadata.developerAppStoreURLString)
                    }
                    if showsMainlandSocialLinks {
                        Divider()
                        macAboutBrandImageRow(String(localized: "小红书"), imageName: "xiaohongshu") {
                            openExternalLink(AppMetadata.xiaohongshuURLString)
                        }
                        Divider()
                        macAboutBrandImageRow(String(localized: "酷安"), imageName: "coolapk") {
                            openExternalLink(AppMetadata.coolapkURLString)
                        }
                    }
                }

                Text(String(localized: "Copyright © 2026 Ruhongyi Liu. All rights reserved."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        #else
        List {
            Section {
                PressableAppIconCard()
                    #if targetEnvironment(macCatalyst)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                    #else
                    .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 20, trailing: 16))
                    #endif
                    .listRowSeparator(.hidden)
            }

            Section {
                HStack(spacing: 12) {
                    #if !targetEnvironment(macCatalyst)
                    Image(systemName: "fleuron")
                        .foregroundStyle(.primary)
                        .imageScale(.medium)
                        .frame(width: 29) // 固定宽度防止对齐偏移
                    #endif
                    
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

                if let shareURL = URL(string: AppMetadata.appStoreShareURLString) {
                    ShareLink(item: shareURL) {
                        Label(String(localized: "分享给朋友"), systemImage: "square.and.arrow.up")
                            .foregroundStyle(.primary)
                    }
                }
            } header: {
                Text(String.localizedStringWithFormat(String(localized: "关于 %@"), AppMetadata.appName))
            }

            Section {
                Button {
                    openExternalLink(AppMetadata.developerAppStoreURLString)
                } label: {
                    Label(String(localized: "更多应用"), systemImage: "square.grid.2x2")
                        .foregroundStyle(.primary)
                }

                if showsMainlandSocialLinks {
                    Button {
                        openExternalLink(AppMetadata.xiaohongshuURLString)
                    } label: {
                        Label {
                            Text(String(localized: "小红书"))
                        } icon: {
                            Image("xiaohongshu")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                        }
                        .foregroundStyle(.primary)
                    }

                    Button {
                        openExternalLink(AppMetadata.coolapkURLString)
                    } label: {
                        Label {
                            Text(String(localized: "酷安"))
                        } icon: {
                            Image("coolapk")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            } header: {
                Text(String(localized: "更多与关注"))
            } footer: {
                Text(String(localized: "Copyright © 2026 Ruhongyi Liu. All rights reserved."))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        #endif
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
        openExternalLink(AppMetadata.openSourceURLString)
    }

    private func requestAppReview() {
        openExternalLink(AppMetadata.appStoreReviewURLString)
    }

    private func openExternalLink(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            reviewErrorMessage = String(localized: "暂时无法打开")
            return
        }
        openURL(url)
    }

    #if targetEnvironment(macCatalyst)
    private func macAboutLinkRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func macAboutCustomImageRow(_ title: String, imageName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, image: imageName)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func macAboutBrandImageRow(_ title: String, imageName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    Image(imageName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
                .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif
}

private struct PressableAppIconCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var pressLocation: CGPoint?

    #if targetEnvironment(macCatalyst)
    private let cardSize: CGFloat = 80
    #else
    private let cardSize: CGFloat = 100
    #endif

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer() // 左边推挤
                
                GeometryReader { proxy in
                    let size = proxy.size
                    let location = pressLocation ?? CGPoint(x: size.width / 2, y: size.height / 2)
                    let x = reduceMotion ? 0 : min(1, max(-1, location.x / size.width * 2 - 1))
                    let y = reduceMotion ? 0 : min(1, max(-1, location.y / size.height * 2 - 1))

                    ZStack {
                        iconLayer("background")
                        ZStack {
                            iconLayer("album-card")
                            iconLayer("album-sun")
                            iconLayer("mountain-far")
                            iconLayer("mountain-near")
                            iconLayer("lock-ring")
                            ZStack {
                                iconLayer("lock-spokes")
                                iconLayer("lock-hub")
                            }
                            .offset(x: x * 0.8, y: y * 0.8)
                        }
                        .offset(x: x * 1.6, y: y * 1.6)
                    }
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: cardSize * 0.22, style: .continuous))
                    .rotation3DEffect(.degrees(-y * 7), axis: (x: 1, y: 0, z: 0))
                    .rotation3DEffect(.degrees(x * 7), axis: (x: 0, y: 1, z: 0))
                    .scaleEffect(pressLocation == nil ? 1 : 0.96)
                    .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.24, dampingFraction: 0.78), value: pressLocation != nil)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($pressLocation) { value, location, _ in
                                location = value.location
                            }
                    )
                    .accessibilityHidden(true)
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
    
    private func iconLayer(_ name: String) -> some View {
        Image("AboutIcon-" + name)
            .resizable()
            .scaledToFit()
    }

}


#Preview {
    NavigationStack {
        AboutAppView()
    }
}

#if targetEnvironment(macCatalyst)
struct MacInformationPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                content
            }
            .font(.body)
            .lineSpacing(3)
            .textSelection(.enabled)
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

struct MacInformationSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
