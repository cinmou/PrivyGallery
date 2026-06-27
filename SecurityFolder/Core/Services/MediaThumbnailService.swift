import AVFoundation
import Foundation
import ImageIO
import QuickLookThumbnailing
import UIKit

#if DEBUG
enum MediaPerformanceLog {
    private struct ThumbnailTaskRecord {
        let label: String
        let durationMS: Double
    }

    private struct AlbumSession {
        let albumHash: String
        let isCold: Bool
        let startedAt: CFAbsoluteTime
        var itemCount: Int = 0
        var firstGridMakeMS: Double?
        var firstReloadMS: Double?
        var firstLayoutMS: Double?
        var firstContentVisibleMS: Double?
        var cellForCount: Int = 0
        var cellForTotalMS: Double = 0
        var scrollEventCount: Int = 0

        nonisolated init(albumHash: String, isCold: Bool, startedAt: CFAbsoluteTime, itemCount: Int = 0) {
            self.albumHash = albumHash
            self.isCold = isCold
            self.startedAt = startedAt
            self.itemCount = itemCount
        }
    }

    private struct ThumbnailStats {
        var memoryHitCount = 0
        var memoryMissCount = 0
        var inFlightReuseCount = 0
        var generationStartCount = 0
        var generatedCount = 0
        var imageDownsampleCount = 0
        var videoThumbnailCount = 0
        var prefetchRequestCount = 0
        var prefetchCancelledCount = 0
        var visibleRequestCount = 0
        var activeTaskCount = 0
        var peakConcurrentTaskCount = 0
        var totalGenerationMS: Double = 0
        var slowTasks: [ThumbnailTaskRecord] = []

        nonisolated init() {}
    }

    nonisolated private static let lock = NSLock()
    nonisolated private static let processStart = CFAbsoluteTimeGetCurrent()
    nonisolated(unsafe) private static var seenAlbumHashes = Set<String>()
    nonisolated(unsafe) private static var currentAlbum: AlbumSession?
    nonisolated(unsafe) private static var thumbnailStats = ThumbnailStats()
    nonisolated(unsafe) private static var hitchDetectorStarted = false
    nonisolated(unsafe) private static var hitchTimer: DispatchSourceTimer?
    nonisolated(unsafe) private static var lastMainTick = CFAbsoluteTimeGetCurrent()
    nonisolated(unsafe) private static var currentStage = "idle"
    nonisolated(unsafe) private static var hitchCount = 0

    nonisolated static func mark(_ name: String, _ details: String = "") {
        let thread = Thread.isMainThread ? "main" : "bg"
        let elapsed = (CFAbsoluteTimeGetCurrent() - processStart) * 1000
        let suffix = details.isEmpty ? "" : " \(details)"
        print("[MediaPerf] +\(String(format: "%.1f", elapsed))ms [\(thread)] \(name)\(suffix)")
    }

    nonisolated static func measure<T>(_ name: String, _ details: String = "", _ block: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let value = try block()
            let duration = (CFAbsoluteTimeGetCurrent() - start) * 1000
            mark(name, "\(details) duration=\(format(duration))ms")
            return value
        } catch {
            let duration = (CFAbsoluteTimeGetCurrent() - start) * 1000
            mark("\(name).failed", "\(details) duration=\(format(duration))ms")
            throw error
        }
    }

    nonisolated static func idHash(_ uuid: UUID) -> String {
        hash(uuid)
    }

    nonisolated static func keyHash(_ key: NSString) -> String {
        hash(key as String)
    }

    nonisolated static func beginAlbum(albumID: UUID, itemCount: Int, limit: Int) {
        let albumHash = hash(albumID)
        lock.lock()
        let isCold = !seenAlbumHashes.contains(albumHash)
        seenAlbumHashes.insert(albumHash)
        currentAlbum = AlbumSession(albumHash: albumHash, isCold: isCold, startedAt: CFAbsoluteTimeGetCurrent(), itemCount: itemCount)
        thumbnailStats = ThumbnailStats()
        currentStage = "album-enter"
        lock.unlock()
        mark("album.enter", "album=\(albumHash) mode=\(isCold ? "cold" : "warm") items=\(itemCount) limit=\(limit)")
        startMainThreadHitchDetectorIfNeeded()
        scheduleAlbumSummary(albumHash: albumHash)
    }

    nonisolated static func updateAlbumItems(albumID: UUID, itemCount: Int, limit: Int) {
        let albumHash = hash(albumID)
        lock.lock()
        if currentAlbum?.albumHash == albumHash {
            currentAlbum?.itemCount = itemCount
        }
        currentStage = "album-items"
        lock.unlock()
        mark("album.items.ready", "album=\(albumHash) items=\(itemCount) limit=\(limit)")
    }

    nonisolated static func recordFirstGridMake() {
        recordAlbumTimeOnce(\.firstGridMakeMS, stage: "grid-make", name: "grid.makeUIViewController")
    }

    nonisolated static func recordFirstContentVisibleIfNeeded() {
        recordAlbumTimeOnce(\.firstContentVisibleMS, stage: "first-visible", name: "grid.firstContentVisible")
    }

    nonisolated static func recordReload(durationMS: Double, layoutMS: Double, itemCount: Int) {
        lock.lock()
        if currentAlbum?.firstReloadMS == nil {
            currentAlbum?.firstReloadMS = durationMS
        }
        if currentAlbum?.firstLayoutMS == nil {
            currentAlbum?.firstLayoutMS = layoutMS
        }
        currentStage = "grid-reload"
        lock.unlock()
        mark("grid.reload", "items=\(itemCount) reload=\(format(durationMS))ms layout=\(format(layoutMS))ms")
    }

    nonisolated static func recordCellFor(durationMS: Double) {
        lock.lock()
        currentAlbum?.cellForCount += 1
        currentAlbum?.cellForTotalMS += durationMS
        lock.unlock()
    }

    nonisolated static func recordScrollEvent() {
        lock.lock()
        currentAlbum?.scrollEventCount += 1
        currentStage = "scroll"
        lock.unlock()
    }

    nonisolated static func recordThumbnailMemoryHit() {
        lock.lock()
        thumbnailStats.memoryHitCount += 1
        lock.unlock()
    }

    nonisolated static func recordThumbnailDiskHit(key: NSString) {
        mark("thumbnail.diskCache.hit", "key=\(keyHash(key))")
    }

    nonisolated static func recordThumbnailMemoryMiss() {
        lock.lock()
        thumbnailStats.memoryMissCount += 1
        lock.unlock()
    }

    nonisolated static func recordInFlightReuse() {
        lock.lock()
        thumbnailStats.inFlightReuseCount += 1
        lock.unlock()
    }

    nonisolated static func recordThumbnailRequest(priority: TaskPriority, visible: Bool) {
        lock.lock()
        if visible {
            thumbnailStats.visibleRequestCount += 1
        } else {
            thumbnailStats.prefetchRequestCount += 1
        }
        currentStage = visible ? "thumbnail-visible" : "thumbnail-prefetch"
        lock.unlock()
        mark("thumbnail.request", "source=\(visible ? "visible" : "prefetch") priority=\(priority)")
    }

    nonisolated static func recordPrefetchCancelled(count: Int) {
        guard count > 0 else { return }
        lock.lock()
        thumbnailStats.prefetchCancelledCount += count
        lock.unlock()
        mark("thumbnail.prefetch.cancel", "count=\(count)")
    }

    nonisolated static func generationStarted(kind: MediaKind, key: NSString) {
        lock.lock()
        thumbnailStats.generationStartCount += 1
        thumbnailStats.activeTaskCount += 1
        thumbnailStats.peakConcurrentTaskCount = max(thumbnailStats.peakConcurrentTaskCount, thumbnailStats.activeTaskCount)
        currentStage = "thumbnail-generate"
        lock.unlock()
        mark("thumbnail.generate.start", "kind=\(kind) key=\(hash(key as String))")
    }

    nonisolated static func generationEnded(kind: MediaKind, key: NSString, durationMS: Double, success: Bool) {
        lock.lock()
        thumbnailStats.activeTaskCount = max(0, thumbnailStats.activeTaskCount - 1)
        if success {
            thumbnailStats.generatedCount += 1
            thumbnailStats.totalGenerationMS += durationMS
            thumbnailStats.slowTasks.append(ThumbnailTaskRecord(label: "\(kind)/\(hash(key as String))", durationMS: durationMS))
            thumbnailStats.slowTasks.sort { $0.durationMS > $1.durationMS }
            if thumbnailStats.slowTasks.count > 5 {
                thumbnailStats.slowTasks.removeLast()
            }
        }
        lock.unlock()
        mark("thumbnail.generate.end", "kind=\(kind) key=\(hash(key as String)) success=\(success) duration=\(format(durationMS))ms")
    }

    nonisolated static func recordDownsample(durationMS: Double) {
        lock.lock()
        thumbnailStats.imageDownsampleCount += 1
        lock.unlock()
        mark("thumbnail.downsample", "duration=\(format(durationMS))ms")
    }

    nonisolated static func recordVideoThumbnail(durationMS: Double) {
        lock.lock()
        thumbnailStats.videoThumbnailCount += 1
        lock.unlock()
        mark("thumbnail.video", "duration=\(format(durationMS))ms")
    }

    nonisolated static func setStage(_ stage: String) {
        lock.lock()
        currentStage = stage
        lock.unlock()
    }

    nonisolated private static func recordAlbumTimeOnce(_ keyPath: WritableKeyPath<AlbumSession, Double?>, stage: String, name: String) {
        lock.lock()
        guard var album = currentAlbum, album[keyPath: keyPath] == nil else {
            lock.unlock()
            return
        }
        let duration = (CFAbsoluteTimeGetCurrent() - album.startedAt) * 1000
        album[keyPath: keyPath] = duration
        currentAlbum = album
        currentStage = stage
        lock.unlock()
        mark(name, "sinceEnter=\(format(duration))ms")
    }

    nonisolated private static func startMainThreadHitchDetectorIfNeeded() {
        lock.lock()
        guard !hitchDetectorStarted else {
            lock.unlock()
            return
        }
        hitchDetectorStarted = true
        lastMainTick = CFAbsoluteTimeGetCurrent()
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler {
            let now = CFAbsoluteTimeGetCurrent()
            lock.lock()
            let delta = now - lastMainTick
            lastMainTick = now
            let stage = currentStage
            if delta > 0.10 {
                hitchCount += 1
                let hitches = hitchCount
                lock.unlock()
                mark("main.hitch.warning", "blocked=\(format(delta * 1000))ms stage=\(stage) count=\(hitches)")
            } else {
                lock.unlock()
            }
        }
        hitchTimer = timer
        timer.resume()
    }

    nonisolated private static func scheduleAlbumSummary(albumHash: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            printSummary(albumHash: albumHash)
        }
    }

    nonisolated private static func printSummary(albumHash: String) {
        lock.lock()
        guard let album = currentAlbum, album.albumHash == albumHash else {
            lock.unlock()
            return
        }
        let stats = thumbnailStats
        let hitches = hitchCount
        lock.unlock()

        let avgCell = album.cellForCount > 0 ? album.cellForTotalMS / Double(album.cellForCount) : 0
        let avgThumb = stats.generatedCount > 0 ? stats.totalGenerationMS / Double(stats.generatedCount) : 0
        let slow = stats.slowTasks
            .map { "\($0.label)=\(format($0.durationMS))ms" }
            .joined(separator: ", ")
        mark(
            "album.summary",
            "album=\(album.albumHash) mode=\(album.isCold ? "cold" : "warm") items=\(album.itemCount) firstVisible=\(format(album.firstContentVisibleMS ?? -1))ms firstReload=\(format(album.firstReloadMS ?? -1))ms firstLayout=\(format(album.firstLayoutMS ?? -1))ms cellFor=\(album.cellForCount) avgCell=\(format(avgCell))ms scrollEvents=\(album.scrollEventCount) cacheHit=\(stats.memoryHitCount) cacheMiss=\(stats.memoryMissCount) inFlightReuse=\(stats.inFlightReuseCount) generated=\(stats.generatedCount) avgGen=\(format(avgThumb))ms imageDownsample=\(stats.imageDownsampleCount) videoThumb=\(stats.videoThumbnailCount) prefetch=\(stats.prefetchRequestCount) visibleReq=\(stats.visibleRequestCount) cancelledPrefetch=\(stats.prefetchCancelledCount) peakConcurrent=\(stats.peakConcurrentTaskCount) hitches=\(hitches) slowest=[\(slow)]"
        )
    }

    nonisolated private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    nonisolated private static func hash(_ uuid: UUID) -> String {
        hash(uuid.uuidString)
    }

    nonisolated private static func hash(_ value: String) -> String {
        let unsigned = UInt(bitPattern: value.hashValue)
        return String(unsigned, radix: 16)
    }
}
#endif

private struct ThumbnailGenerationRequest: Sendable {
    let itemID: UUID
    let mediaKind: MediaKind
    let relativePath: String
    let originalFilename: String
    let space: VaultSpaceKind
}

final class MediaThumbnailService {
    static let shared = MediaThumbnailService()
    static let gridThumbnailSide: CGFloat = 260

    nonisolated(unsafe) private let cache = NSCache<NSString, UIImage>()
    nonisolated(unsafe) private let fileManager = FileManager.default
    private let generationLimiter = ThumbnailGenerationLimiter(maxConcurrentOperations: 2)
    nonisolated private let cacheOrderQueue = DispatchQueue(label: "SecurityFolder.MediaThumbnailService.CacheOrder")
    nonisolated(unsafe) private var cacheInsertionOrder: [NSString] = []
    private let inFlightLock = NSLock()
    private var inFlightTasks: [NSString: Task<UIImage?, Never>] = [:]
    private let maxVideoThumbnailSourceByteCount: Int64 = 256 * 1_024 * 1_024

    private init() {
        cache.countLimit = 420
        cache.totalCostLimit = 128 * 1_024 * 1_024

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThermalStateDidChange),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    func cachedThumbnail(for item: VaultItem, size: CGSize, contentMode: UIView.ContentMode = .scaleAspectFill) -> UIImage? {
        cachedImage(for: cacheKey(for: item.id, size: size, contentMode: contentMode))
    }

    func cachedThumbnailInMemory(for itemID: UUID, size: CGSize, contentMode: UIView.ContentMode = .scaleAspectFill) -> UIImage? {
        cachedImage(for: cacheKey(for: itemID, size: size, contentMode: contentMode))
    }

    func prefetchThumbnail(for item: VaultItem, size: CGSize, priority: TaskPriority = .utility) -> Task<Void, Never> {
        Task.detached(priority: priority) { [self] in
            #if DEBUG
            MediaPerformanceLog.recordThumbnailRequest(priority: priority, visible: false)
            #endif
            _ = await thumbnail(for: item, size: size, priority: priority)
        }
    }

    func thumbnail(
        for item: VaultItem,
        size: CGSize,
        contentMode: UIView.ContentMode = .scaleAspectFill,
        priority: TaskPriority = .utility
    ) async -> UIImage? {
        let cacheKey = cacheKey(for: item.id, size: size, contentMode: contentMode)
        if let cached = cachedImage(for: cacheKey) {
            #if DEBUG
            MediaPerformanceLog.recordThumbnailMemoryHit()
            #endif
            return cached
        }

        guard !Task.isCancelled else {
            return nil
        }

        if let task = inFlightTask(for: cacheKey) {
            #if DEBUG
            MediaPerformanceLog.recordInFlightReuse()
            #endif
            return await task.value
        }

        #if DEBUG
        MediaPerformanceLog.recordThumbnailMemoryMiss()
        #endif

        let scale = UIScreen.main.scale
        let request = ThumbnailGenerationRequest(
            itemID: item.id,
            mediaKind: item.mediaKind,
            relativePath: item.relativePath,
            originalFilename: item.originalFilename,
            space: item.space
        )
        let cacheKeyString = cacheKey as String
        let task: Task<UIImage?, Never> = Task.detached(priority: priority) { [self] in
            let result: UIImage?? = await generationLimiter.schedule(priority: priority) { [self] in
                let detachedCacheKey = cacheKeyString as NSString
                return await generateThumbnail(for: request, size: size, cacheKey: detachedCacheKey, scale: scale)
            }
            return result ?? nil
        }
        setInFlightTask(task, for: cacheKey)
        let image = await task.value
        removeInFlightTask(for: cacheKey)
        return image
    }

    func previewImage(for item: VaultItem) -> UIImage? {
        guard VaultFileStorageService.shared.fileExists(at: item.relativePath) else {
            return nil
        }

        guard let fileURL = try? VaultFileStorageService.shared.decryptedTemporaryURL(
            for: item.relativePath,
            originalFilename: item.originalFilename,
            space: item.space
        ) else {
            return nil
        }

        if let image = UIImage(contentsOfFile: fileURL.path()) {
            return image
        }

        return nil
    }

    func clearCache() {
        cache.removeAllObjects()
        cacheOrderQueue.sync {
            cacheInsertionOrder.removeAll()
        }
        try? fileManager.removeItem(at: thumbnailDirectory)
    }

    func removeCachedThumbnail(for itemID: UUID) {
        cacheOrderQueue.sync {
            let prefix = itemID.uuidString
            for key in cacheInsertionOrder where key.hasPrefix(prefix) {
                cache.removeObject(forKey: key)
            }
            cacheInsertionOrder.removeAll { $0.hasPrefix(prefix) }
        }
        try? fileManager.removeItem(at: thumbnailDirectory.appendingPathComponent("\(itemID.uuidString).jpg"))
    }

    nonisolated private func storeThumbnail(_ image: UIImage, for request: ThumbnailGenerationRequest, cacheKey: NSString) -> UIImage {
        let compressed = compressedThumbnail(from: image) ?? image
        setCachedImage(compressed, for: cacheKey)
        persistThumbnailToDisk(compressed, for: request)
        return compressed
    }

    nonisolated private func compressedThumbnail(from image: UIImage) -> UIImage? {
        // A larger raster keeps the library looking crisp on modern devices
        // without falling back to full-size media for grid cells.
        let maxDimension: CGFloat = 360
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }

        let scale = min(maxDimension / size.width, maxDimension / size.height, 1)
        let targetSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        guard let data = resized.jpegData(compressionQuality: 0.68),
              let compressed = UIImage(data: data) else {
            return resized
        }
        return compressed
    }

    nonisolated private func diskCachedThumbnail(for request: ThumbnailGenerationRequest, cacheKey: NSString) -> UIImage? {
        let url = thumbnailURL(for: request)
        guard fileManager.fileExists(atPath: url.path()),
              let image = UIImage(contentsOfFile: url.path()) else {
            return nil
        }
        setCachedImage(image, for: cacheKey)
        #if DEBUG
        MediaPerformanceLog.recordThumbnailDiskHit(key: cacheKey)
        #endif
        return image
    }

    nonisolated private func persistThumbnailToDisk(_ image: UIImage, for request: ThumbnailGenerationRequest) {
        let url = thumbnailURL(for: request)
        guard let data = image.jpegData(compressionQuality: 0.76) else { return }
        do {
            try ensureThumbnailDirectoryExists()
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    nonisolated private func thumbnailURL(for request: ThumbnailGenerationRequest) -> URL {
        thumbnailDirectory.appendingPathComponent("\(request.itemID.uuidString).jpg")
    }

    nonisolated private func ensureThumbnailDirectoryExists() throws {
        if !fileManager.fileExists(atPath: thumbnailDirectory.path()) {
            try fileManager.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        }
    }

    nonisolated private var thumbnailDirectory: URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaThumbnailCache", isDirectory: true)
    }

    nonisolated private func renderThumbnail(for request: ThumbnailGenerationRequest, fileURL: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        switch request.mediaKind {
        case .photo, .livePhoto:
            return imageThumbnail(for: fileURL, size: size, scale: scale)
        case .video:
            return await videoThumbnail(for: fileURL, size: size, scale: scale)
        }
    }

    nonisolated private func imageThumbnail(for fileURL: URL, size: CGSize, scale: CGFloat) -> UIImage? {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            #if DEBUG
            MediaPerformanceLog.recordDownsample(durationMS: (CFAbsoluteTimeGetCurrent() - start) * 1000)
            #endif
        }
        let maxPixelSize = max(size.width, size.height) * scale
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: image)
    }

    nonisolated private func videoThumbnail(for fileURL: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            #if DEBUG
            MediaPerformanceLog.recordVideoThumbnail(durationMS: (CFAbsoluteTimeGetCurrent() - start) * 1000)
            #endif
        }
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: size.width * scale,
            height: size.height * scale
        )

        let cgImage: CGImage?
        if #available(iOS 18.0, *) {
            cgImage = await withCheckedContinuation { continuation in
                generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
                    continuation.resume(returning: image)
                }
            }
        } else {
            cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil)
        }

        return cgImage.map(UIImage.init(cgImage:))
    }

    nonisolated private func cacheCost(for image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }

    nonisolated private func cachedImage(for key: NSString) -> UIImage? {
        guard let image = cache.object(forKey: key) else { return nil }
        cacheOrderQueue.sync {
            cacheInsertionOrder.removeAll { $0 == key }
            cacheInsertionOrder.append(key)
        }
        return image
    }

    nonisolated private func setCachedImage(_ image: UIImage, for key: NSString) {
        cache.setObject(image, forKey: key, cost: cacheCost(for: image))
        cacheOrderQueue.sync {
            cacheInsertionOrder.removeAll { $0 == key }
            cacheInsertionOrder.append(key)
        }
    }

    private func cacheKey(for itemID: UUID, size: CGSize, contentMode: UIView.ContentMode) -> NSString {
        let scale = UIScreen.main.scale
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        return "\(itemID.uuidString)-\(width)x\(height)-\(contentMode.rawValue)" as NSString
    }

    private func inFlightTask(for key: NSString) -> Task<UIImage?, Never>? {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        return inFlightTasks[key]
    }

    private func setInFlightTask(_ task: Task<UIImage?, Never>, for key: NSString) {
        inFlightLock.lock()
        inFlightTasks[key] = task
        inFlightLock.unlock()
    }

    private func removeInFlightTask(for key: NSString) {
        inFlightLock.lock()
        inFlightTasks.removeValue(forKey: key)
        inFlightLock.unlock()
    }

    nonisolated private func generateThumbnail(for request: ThumbnailGenerationRequest, size: CGSize, cacheKey: NSString, scale: CGFloat) async -> UIImage? {
        #if DEBUG
        let generationStart = CFAbsoluteTimeGetCurrent()
        MediaPerformanceLog.generationStarted(kind: request.mediaKind, key: cacheKey)
        func finish(_ image: UIImage?) -> UIImage? {
            MediaPerformanceLog.generationEnded(
                kind: request.mediaKind,
                key: cacheKey,
                durationMS: (CFAbsoluteTimeGetCurrent() - generationStart) * 1000,
                success: image != nil
            )
            return image
        }
        #endif

        guard !Task.isCancelled else {
            #if DEBUG
            return finish(nil)
            #else
            return nil
            #endif
        }

        if let cached = cachedImage(for: cacheKey) {
            #if DEBUG
            MediaPerformanceLog.recordThumbnailMemoryHit()
            return finish(cached)
            #else
            return cached
            #endif
        }

        guard !Task.isCancelled else {
            #if DEBUG
            return finish(nil)
            #else
            return nil
            #endif
        }

        if let diskCached = diskCachedThumbnail(for: request, cacheKey: cacheKey) {
            #if DEBUG
            return finish(diskCached)
            #else
            return diskCached
            #endif
        }

        guard !Task.isCancelled else {
            #if DEBUG
            return finish(nil)
            #else
            return nil
            #endif
        }

        guard VaultFileStorageService.shared.fileExists(at: request.relativePath) else {
            #if DEBUG
            return finish(nil)
            #else
            return nil
            #endif
        }

        // Video thumbnails require a decrypted playable file for AVFoundation.
        // Skip very large uncached videos here so opening a big album cannot
        // trigger multiple full-video decryptions just to draw the grid.
        if request.mediaKind == .video,
           VaultFileStorageService.shared.byteCount(for: request.relativePath) > maxVideoThumbnailSourceByteCount {
            #if DEBUG
            return finish(nil)
            #else
            return nil
            #endif
        }

        guard let fileURL = try? VaultFileStorageService.shared.decryptedTemporaryURL(
            for: request.relativePath,
            originalFilename: request.originalFilename,
            space: request.space,
            cacheResult: false
        ) else {
            #if DEBUG
            return finish(nil)
            #else
            return nil
            #endif
        }
        defer {
            VaultFileStorageService.shared.clearDecryptedTemporaryURLIfManaged(fileURL)
        }

        if let renderedImage = await renderThumbnail(for: request, fileURL: fileURL, size: size, scale: scale) {
            #if DEBUG
            return finish(storeThumbnail(renderedImage, for: request, cacheKey: cacheKey))
            #else
            return storeThumbnail(renderedImage, for: request, cacheKey: cacheKey)
            #endif
        }

        let qlRequest = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )

        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: qlRequest)
            #if DEBUG
            return finish(storeThumbnail(representation.uiImage, for: request, cacheKey: cacheKey))
            #else
            return storeThumbnail(representation.uiImage, for: request, cacheKey: cacheKey)
            #endif
        } catch {
            #if DEBUG
            return finish(nil)
            #else
            return nil
            #endif
        }
    }

    @objc
    private func handleMemoryWarning() {
        trimOldestCachedThumbnails(removalFraction: 0.65, reason: "memoryWarning")
    }

    @objc
    private func handleDidEnterBackground() {
        trimOldestCachedThumbnails(removalFraction: 0.2, reason: "didEnterBackground")
    }

    @objc
    private func handleThermalStateDidChange() {
        let thermalState = ProcessInfo.processInfo.thermalState
        guard thermalState == .serious || thermalState == .critical else { return }
        trimOldestCachedThumbnails(removalFraction: 0.35, reason: "thermalState=\(thermalState.rawValue)")
    }

    private func trimOldestCachedThumbnails(removalFraction: Double, reason: String) {
        let keysToRemove: [NSString] = cacheOrderQueue.sync {
            guard !cacheInsertionOrder.isEmpty else { return [] }
            let removalCount = max(1, Int(Double(cacheInsertionOrder.count) * removalFraction))
            let removing = Array(cacheInsertionOrder.prefix(removalCount))
            cacheInsertionOrder.removeFirst(min(removalCount, cacheInsertionOrder.count))
            return removing
        }

        guard !keysToRemove.isEmpty else { return }
        for key in keysToRemove {
            cache.removeObject(forKey: key)
        }
        print("[MediaThumbnailService] Trimmed \(keysToRemove.count) in-memory thumbnails due to \(reason).")
    }

}

actor ThumbnailGenerationLimiter {
    private let maxConcurrentOperations: Int
    private var currentOperations = 0

    init(maxConcurrentOperations: Int) {
        self.maxConcurrentOperations = max(1, maxConcurrentOperations)
    }

    func schedule<T>(
        priority: TaskPriority,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        guard await acquirePermit(priority: priority) else {
            return nil
        }
        defer {
            releasePermit()
        }

        guard !Task.isCancelled else {
            return nil
        }

        return await operation()
    }

    private func acquirePermit(priority: TaskPriority) async -> Bool {
        let sleepNanoseconds = Self.pollIntervalNanoseconds(for: priority)
        while !Task.isCancelled {
            if currentOperations < maxConcurrentOperations {
                currentOperations += 1
                return true
            }
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
        }
        return false
    }

    private func releasePermit() {
        currentOperations = max(0, currentOperations - 1)
    }

    private static func pollIntervalNanoseconds(for priority: TaskPriority) -> UInt64 {
        switch priority {
        case .high, .userInitiated:
            return 5_000_000
        case .medium:
            return 10_000_000
        case .low, .utility:
            return 20_000_000
        case .background:
            return 30_000_000
        default:
            return 15_000_000
        }
    }
}
