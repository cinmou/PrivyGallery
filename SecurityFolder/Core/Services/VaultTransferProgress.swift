import Foundation

nonisolated struct VaultTransferProgress: Sendable {
    enum Phase: String, Sendable {
        case scanning
        case planning
        case archiving
        case compressing
        case encrypting
        case writingPart
        case reading
        case validating
        case decrypting
        case extracting
        case restoring
        case refreshing
        case completed
        case cancelled
    }

    let phase: Phase
    let currentPart: Int
    let totalParts: Int
    let currentItem: Int
    let totalItems: Int
    let currentBytes: Int64
    let totalBytes: Int64
    let message: String
    let fractionCompleted: Double?

    init(
        phase: Phase,
        currentPart: Int = 0,
        totalParts: Int = 0,
        currentItem: Int = 0,
        totalItems: Int = 0,
        currentBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        message: String,
        fractionCompleted: Double?
    ) {
        self.phase = phase
        self.currentPart = currentPart
        self.totalParts = totalParts
        self.currentItem = currentItem
        self.totalItems = totalItems
        self.currentBytes = currentBytes
        self.totalBytes = totalBytes
        self.message = message
        self.fractionCompleted = fractionCompleted.map { min(max($0, 0), 1) }
    }

    var localizedTitle: String {
        switch phase {
        case .scanning:
            return String(localized: "正在扫描媒体")
        case .planning:
            return String(localized: "正在规划备份分片")
        case .archiving:
            return String(localized: "正在写入备份归档")
        case .compressing:
            return String(localized: "正在压缩")
        case .encrypting:
            return String(localized: "正在加密")
        case .writingPart:
            return String(localized: "正在写入备份文件")
        case .reading:
            return String(localized: "正在读取备份文件")
        case .validating:
            return String(localized: "正在验证备份")
        case .decrypting:
            return String(localized: "正在解密")
        case .extracting:
            return String(localized: "正在解压备份")
        case .restoring:
            return String(localized: "正在恢复媒体")
        case .refreshing:
            return String(localized: "正在刷新媒体库")
        case .completed:
            return String(localized: "完成")
        case .cancelled:
            return String(localized: "已取消")
        }
    }
}

#if DEBUG
nonisolated enum VaultTransferLog {
    private static let start = CFAbsoluteTimeGetCurrent()

    static func mark(_ name: String, _ details: String = "") {
        let thread = Thread.isMainThread ? "main" : "bg"
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let suffix = details.isEmpty ? "" : " \(details)"
        print("[VaultTransfer] +\(String(format: "%.1f", elapsed))ms [\(thread)] \(name)\(suffix)")
    }
}
#endif
