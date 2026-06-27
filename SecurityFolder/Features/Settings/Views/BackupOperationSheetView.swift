import SwiftUI

/// 导入导出进行中的通用弹窗。
/// 主设置页只负责把当前进度状态传进来，这个视图专门负责呈现加载反馈和停止按钮。
struct BackupOperationSheetView: View {
    let title: String
    let progressTitle: String
    let progressDetail: String
    let progressValue: Double?
    let currentPart: Int
    let totalParts: Int
    let currentItem: Int
    let totalItems: Int
    let currentBytes: Int64
    let totalBytes: Int64
    let onCancel: () -> Void

    // 1. 定义显示确认弹窗的状态
    @State private var isShowingConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) { // 整体间距收紧
                        // 顶部图标与文字
                        VStack(spacing: 12) {
                            Image(systemName: "lock.rectangle.stack.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 56, height: 56)
                                .foregroundStyle(.blue)
                                .padding(.top, 20)
                            
                            Text(progressTitle.isEmpty ? title : progressTitle)
                                .font(.title3.weight(.bold))
                            
                            if !progressDetail.isEmpty {
                                Text(progressDetail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                            }
                        }
                        
                        // 卡片区域
                        VStack(spacing: 0) { // 内部设为0，通过子组件Padding控制
                            // 进度条部分
                            VStack(spacing: 8) {
                                HStack {
                                    Text(String(localized: "当前进度"))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if let progressValue {
                                        Text(String.localizedStringWithFormat(String(localized: "%lld%%"), Int64(progressValue * 100)))
                                            .font(.footnote.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text(String(localized: "准备中"))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let progressValue {
                                    ProgressView(value: progressValue)
                                        .progressViewStyle(.linear)
                                } else {
                                    ProgressView()
                                        .controlSize(.regular)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    if totalParts > 0 {
                                        Text(String.localizedStringWithFormat(String(localized: "备份文件：%1$lld / %2$lld"), currentPart, totalParts))
                                    }
                                    if totalItems > 0 {
                                        Text(String.localizedStringWithFormat(String(localized: "项目：%1$lld / %2$lld"), currentItem, totalItems))
                                    }
                                    if totalBytes > 0 {
                                        Text(byteProgressText)
                                    }
                                }
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding([.horizontal, .top], 20)
                            .padding(.bottom, 16)
                            
                            Divider()
                            
                            // 2. 绑定整个列的红色按钮
                            Button(action: {
                                isShowingConfirmation = true // 触发确认逻辑
                            }) {
                                Text(String(localized: "中止操作"))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity) // 撑开宽度
                                    .padding(.vertical, 14)     // 增加上下点击热区
                                    .contentShape(Rectangle())   // 关键：使整个透明区域都可点击
                            }
                            .buttonStyle(.plain)
                        }
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(24)
                        
                        // 底部提示文字：靠左且紧凑
                        Text(String(localized: "停止后，应用会自动清理本次未完成的导出或恢复数据。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.top, -4) // 紧贴卡片
                    }
                    .padding()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(true)
            // 3. 二次确认弹窗
            .confirmationDialog(
                String(localized: "确定要中止吗？"),
                isPresented: $isShowingConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "中止操作"), role: .destructive) {
                    onCancel()
                }
                Button(String(localized: "取消"), role: .cancel) { }
            } message: {
                Text(String(localized: "中止后将无法恢复当前的进度，且系统会清理已生成的临时数据。"))
            }
        }
    }

    private var byteProgressText: String {
        ByteCountFormatter.string(fromByteCount: currentBytes, countStyle: .file)
            + " / "
            + ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

#Preview {
    BackupOperationSheetView(
        title: "正在导出",
        progressTitle: "封装密文",
        progressDetail: "正在整理当前空间索引，请稍后...",
        progressValue: 0.42,
        currentPart: 1,
        totalParts: 3,
        currentItem: 24,
        totalItems: 800,
        currentBytes: 42_000_000,
        totalBytes: 120_000_000,
        onCancel: {}
    )
}
