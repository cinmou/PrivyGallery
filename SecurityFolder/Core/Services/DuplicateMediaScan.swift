import CryptoKit
import Foundation

nonisolated enum DuplicateMediaScan {
    struct Candidate: Sendable {
        let id: UUID
        let path: String
        let companionPath: String?
        let isLivePhoto: Bool
        let isPhoto: Bool
    }

    struct Group: Sendable {
        let ids: [UUID]
        let isApproximate: Bool
    }

    struct Result: Sendable {
        let groups: [Group]
        let exactGroups: [[UUID]]
        let skippedCount: Int
    }

    private struct Fingerprint: Hashable {
        let primary: SHA256.Digest
        let companion: SHA256.Digest?
    }

    static func scan(_ candidates: [Candidate], space: VaultSpaceKind, includeNearPhotos: Bool) throws -> Result {
        var matches: [Fingerprint: [UUID]] = [:]
        var order: [Fingerprint] = []
        var photoPaths: [Fingerprint: String] = [:]
        var skippedCount = 0

        #if DEBUG
        print("[DuplicateScan] started count=\(candidates.count) nearPhotos=\(includeNearPhotos)")
        #endif

        for candidate in candidates {
            try Task.checkCancellation()
            do {
                let primary = try digest(path: candidate.path, space: space)
                var companion: SHA256.Digest?
                if candidate.isLivePhoto {
                    guard let path = candidate.companionPath else {
                        skippedCount += 1
                        continue
                    }
                    companion = try digest(path: path, space: space)
                }
                let fingerprint = Fingerprint(primary: primary, companion: companion)
                if matches[fingerprint] == nil {
                    order.append(fingerprint)
                    if includeNearPhotos, candidate.isPhoto { photoPaths[fingerprint] = candidate.path }
                }
                matches[fingerprint, default: []].append(candidate.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch VaultCryptoError.keyUnavailable {
                throw VaultCryptoError.keyUnavailable
            } catch {
                skippedCount += 1
            }
        }

        #if DEBUG
        print("[DuplicateScan] exact pass complete, photo candidates=\(photoPaths.count)")
        #endif

        var approximateGroups: [[(fingerprint: Fingerprint, photo: NearDuplicatePhoto)]] = []
        for fingerprint in order {
            guard let path = photoPaths[fingerprint] else { continue }
            try Task.checkCancellation()
            do {
                // ImageIO and Vision can retain autoreleased decode and inference
                // buffers until the background scan returns.
                let photo = try autoreleasepool {
                    try loadPhoto(path: path, space: space)
                }
                var matchingGroup: Int?
                for index in approximateGroups.indices {
                    try Task.checkCancellation()
                    var allMatch = true
                    for member in approximateGroups[index] {
                        try Task.checkCancellation()
                        if !member.photo.matches(photo) {
                            allMatch = false
                            break
                        }
                    }
                    if allMatch {
                        matchingGroup = index
                        break
                    }
                }

                let candidate = (fingerprint, photo)
                if let matchingGroup {
                    approximateGroups[matchingGroup].append(candidate)
                } else {
                    approximateGroups.append([candidate])
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch VaultCryptoError.keyUnavailable {
                throw VaultCryptoError.keyUnavailable
            } catch {
                skippedCount += 1
            }
        }

        var combinedFingerprints = Set<Fingerprint>()
        let nearMatches = approximateGroups.compactMap { group -> Group? in
            guard group.count > 1 else { return nil }
            combinedFingerprints.formUnion(group.map(\.fingerprint))
            return Group(ids: group.flatMap { matches[$0.fingerprint] ?? [] }, isApproximate: true)
        }
        let exactGroups = order.compactMap { fingerprint -> (fingerprint: Fingerprint, ids: [UUID])? in
            guard let ids = matches[fingerprint], ids.count > 1 else { return nil }
            return (fingerprint, ids)
        }
        let exactMatches = exactGroups
            .filter { !combinedFingerprints.contains($0.fingerprint) }
            .map { Group(ids: $0.ids, isApproximate: false) }
        #if DEBUG
        print("[DuplicateScan] finished exactGroups=\(exactMatches.count) nearGroups=\(nearMatches.count) skipped=\(skippedCount)")
        #endif
        return Result(groups: exactMatches + nearMatches, exactGroups: exactGroups.map(\.ids), skippedCount: skippedCount)
    }

    private static func loadPhoto(path: String, space: VaultSpaceKind) throws -> NearDuplicatePhoto {
        let url = VaultFileStorageService.shared.fileURL(for: path)
        let maxBytes = 64 * 1024 * 1024
        var data = Data()
        defer {
            if !data.isEmpty {
                data.resetBytes(in: 0..<data.count)
            }
            data.removeAll(keepingCapacity: false)
        }
        try VaultCryptoService.shared.streamPlaintextChunks(fromEncryptedFileAt: url, space: space) { chunk in
            try Task.checkCancellation()
            guard chunk.count <= maxBytes - data.count else { throw CocoaError(.fileReadTooLarge) }
            data.append(chunk)
        }
        try Task.checkCancellation()
        return try NearDuplicatePhoto(data: data)
    }

    private static func digest(path: String, space: VaultSpaceKind) throws -> SHA256.Digest {
        let url = VaultFileStorageService.shared.fileURL(for: path)
        var hash = SHA256()
        try VaultCryptoService.shared.streamPlaintextChunks(fromEncryptedFileAt: url, space: space) { chunk in
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize()
    }
}
