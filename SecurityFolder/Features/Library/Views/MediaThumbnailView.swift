import SwiftUI
import Combine

struct MediaThumbnailView: View {
    let item: VaultItem

    @StateObject private var loader = MediaThumbnailLoader()

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity.animation(.easeInOut(duration: 0.16)))
                } else {
                    Rectangle()
                        .fill(Color(.secondarySystemFill))
                        .overlay {
                            Image(systemName: item.mediaKind.symbolName)
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.width)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            loader.load(item)
        }
        .onChange(of: item.id) { _, _ in
            loader.load(item)
        }
        .onDisappear {
            loader.cancel()
        }
    }
}

@MainActor
private final class MediaThumbnailLoader: ObservableObject {
    @Published var image: UIImage?

    private var loadTask: Task<Void, Never>?
    private var itemID: UUID?

    func load(_ item: VaultItem) {
        let side = MediaThumbnailService.gridThumbnailSide
        let targetSize = CGSize(width: side, height: side)

        if itemID != item.id {
            image = nil
            itemID = item.id
        }

        cancel()

        if let cached = MediaThumbnailService.shared.cachedThumbnail(for: item, size: targetSize) {
            #if DEBUG
            MediaPerformanceLog.recordThumbnailMemoryHit()
            #endif
            image = cached
            return
        }

        let targetItemID = item.id
        loadTask = Task { [weak self] in
            let loadedImage = await MediaThumbnailService.shared.thumbnail(
                for: item,
                size: targetSize,
                priority: .userInitiated
            )
            guard !Task.isCancelled,
                  let self,
                  self.itemID == targetItemID,
                  let loadedImage else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                self.image = loadedImage
            }
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }
}

@MainActor
final class VisibleThumbnailRequestCoordinator {
    static let shared = VisibleThumbnailRequestCoordinator()

    private struct Request {
        let id: UUID
        let item: VaultItem
        let size: CGSize
        let completion: (UUID, UUID, UIImage?) -> Void
    }

    private struct Completion {
        let requestID: UUID
        let itemID: UUID
        let image: UIImage?
        let completion: (UUID, UUID, UIImage?) -> Void
    }

    private var pendingRequests: [Request] = []
    private var activeRequestIDs = Set<UUID>()
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingCompletions: [Completion] = []
    private var requestPumpScheduled = false
    private var completionPumpScheduled = false
    private var thumbnailLoadingSuspended = false
    private var visibleRequestPassDepth = 0

    private let requestBatchSize = 12
    private let completionBatchSize = 12

    var allowsVisibleRequests: Bool {
        !thumbnailLoadingSuspended && visibleRequestPassDepth > 0
    }

    func performVisibleRequestPass(_ body: () -> Void) {
        visibleRequestPassDepth += 1
        body()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.visibleRequestPassDepth = max(0, self.visibleRequestPassDepth - 1)
        }
    }

    func setSuspended(_ suspended: Bool, reason: String) {
        guard thumbnailLoadingSuspended != suspended else { return }
        thumbnailLoadingSuspended = suspended
        #if DEBUG
        MediaPerformanceLog.mark("thumbnail.loading.suspended", "value=\(suspended) reason=\(reason) pending=\(pendingRequests.count) completions=\(pendingCompletions.count)")
        #endif
        if suspended {
            let cancelledCount = pendingRequests.count + activeTasks.count
            pendingRequests.removeAll()
            pendingCompletions.removeAll()
            activeRequestIDs.removeAll()
            activeTasks.values.forEach { $0.cancel() }
            activeTasks.removeAll()
            #if DEBUG
            MediaPerformanceLog.mark("thumbnail.request.cancelled", "reason=\(reason) count=\(cancelledCount)")
            #endif
            return
        }
        scheduleRequestPump()
        scheduleCompletionPump()
    }

    func enqueue(
        item: VaultItem,
        size: CGSize,
        completion: @escaping (UUID, UUID, UIImage?) -> Void
    ) -> UUID {
        let requestID = UUID()
        if thumbnailLoadingSuspended {
            #if DEBUG
            MediaPerformanceLog.mark("thumbnail.request.skipped", "reason=scrolling item=\(MediaPerformanceLog.idHash(item.id))")
            #endif
            return requestID
        }
        let request = Request(id: requestID, item: item, size: size, completion: completion)
        pendingRequests.append(request)
        scheduleRequestPump()
        return request.id
    }

    func cancel(_ requestID: UUID) {
        pendingRequests.removeAll { $0.id == requestID }
        activeRequestIDs.remove(requestID)
        activeTasks[requestID]?.cancel()
        activeTasks.removeValue(forKey: requestID)
        pendingCompletions.removeAll { $0.requestID == requestID }
    }

    private func scheduleRequestPump() {
        guard !requestPumpScheduled else { return }
        requestPumpScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.pumpRequests()
        }
    }

    private func pumpRequests() {
        requestPumpScheduled = false
        guard !thumbnailLoadingSuspended else {
            #if DEBUG
            MediaPerformanceLog.mark("thumbnail.request.pump.paused", "reason=scrolling pending=\(pendingRequests.count)")
            #endif
            return
        }
        guard !pendingRequests.isEmpty else { return }
        let batch = Array(pendingRequests.prefix(requestBatchSize))
        pendingRequests.removeFirst(min(requestBatchSize, pendingRequests.count))

        for request in batch {
            activeRequestIDs.insert(request.id)
            #if DEBUG
            MediaPerformanceLog.recordThumbnailRequest(priority: .userInitiated, visible: true)
            #endif
            let task = Task(priority: .userInitiated) { [weak self] in
                guard !Task.isCancelled else { return }
                let image = await MediaThumbnailService.shared.thumbnail(for: request.item, size: request.size, priority: .userInitiated)
                guard !Task.isCancelled else { return }
                self?.complete(request, image: image)
            }
            activeTasks[request.id] = task
        }

        if !pendingRequests.isEmpty {
            scheduleRequestPump()
        }
    }

    private func complete(_ request: Request, image: UIImage?) {
        guard activeRequestIDs.remove(request.id) != nil else { return }
        activeTasks.removeValue(forKey: request.id)
        pendingCompletions.append(
            Completion(
                requestID: request.id,
                itemID: request.item.id,
                image: image,
                completion: request.completion
            )
        )
        if thumbnailLoadingSuspended {
            #if DEBUG
            MediaPerformanceLog.mark("thumbnail.uiUpdate.deferred", "reason=scrolling pending=\(pendingCompletions.count)")
            #endif
            return
        }
        scheduleCompletionPump()
    }

    private func scheduleCompletionPump() {
        guard !completionPumpScheduled else { return }
        completionPumpScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.024) { [weak self] in
            self?.pumpCompletions()
        }
    }

    private func pumpCompletions() {
        completionPumpScheduled = false
        guard !thumbnailLoadingSuspended else {
            #if DEBUG
            MediaPerformanceLog.mark("thumbnail.uiUpdate.deferred", "reason=scrolling pending=\(pendingCompletions.count)")
            #endif
            return
        }
        guard !pendingCompletions.isEmpty else { return }
        let batch = Array(pendingCompletions.prefix(completionBatchSize))
        pendingCompletions.removeFirst(min(completionBatchSize, pendingCompletions.count))

        #if DEBUG
        MediaPerformanceLog.mark("thumbnail.uiUpdate.flush", "count=\(batch.count) remaining=\(pendingCompletions.count)")
        #endif

        for completion in batch {
            completion.completion(completion.requestID, completion.itemID, completion.image)
        }

        if !pendingCompletions.isEmpty {
            scheduleCompletionPump()
        }
    }
}

#Preview {
    MediaThumbnailView(item: PreviewSupport.sampleItem())
        .padding()
}
