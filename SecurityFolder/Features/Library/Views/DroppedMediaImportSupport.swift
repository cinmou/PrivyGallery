import Foundation
import UniformTypeIdentifiers
import UIKit

enum DroppedMediaImportSupport {
    static let supportedTypeIdentifiers: [String] = [
        UTType.movie.identifier,
        UTType.image.identifier,
        UTType.fileURL.identifier
    ]

    static func loadURLs(from providers: [NSItemProvider]) async -> [URL] {
        await withTaskGroup(of: URL?.self) { group in
            for provider in providers {
                group.addTask {
                    await loadURL(from: provider)
                }
            }

            var urls: [URL] = []
            for await url in group {
                if let url {
                    urls.append(url)
                }
            }
            return urls
        }
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        if let movieURL = await loadFileRepresentation(from: provider, contentType: .movie) {
            return movieURL
        }

        if let imageURL = await loadFileRepresentation(from: provider, contentType: .image) {
            return imageURL
        }

        if let fileURL = await loadDirectFileURL(from: provider) {
            return fileURL
        }

        if let imageDataURL = await loadDataRepresentation(from: provider, contentType: .image) {
            return imageDataURL
        }

        if let movieDataURL = await loadDataRepresentation(from: provider, contentType: .movie) {
            return movieDataURL
        }

        return nil
    }

    private static func loadFileRepresentation(from provider: NSItemProvider, contentType: UTType) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(contentType.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: contentType.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }

                let copiedURL = copyToTemporaryLocation(sourceURL: url, preferredExtension: contentType.preferredFilenameExtension)
                continuation.resume(returning: copiedURL)
            }
        }
    }

    private static func loadDirectFileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: copyToTemporaryLocation(sourceURL: url, preferredExtension: url.pathExtension))
                    return
                }

                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: copyToTemporaryLocation(sourceURL: url, preferredExtension: url.pathExtension))
                    return
                }

                continuation.resume(returning: nil)
            }
        }
    }

    private static func loadDataRepresentation(from provider: NSItemProvider, contentType: UTType) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(contentType.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: contentType.identifier) { data, _ in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }

                let fileExtension = resolvedFilenameExtension(for: contentType)
                let filename = UUID().uuidString + "." + fileExtension
                let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

                do {
                    try data.write(to: destinationURL, options: .atomic)
                    continuation.resume(returning: destinationURL)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func copyToTemporaryLocation(sourceURL: URL, preferredExtension: String?) -> URL? {
        let fileManager = FileManager.default
        let pathExtension = sourceURL.pathExtension.isEmpty ? (preferredExtension ?? "") : sourceURL.pathExtension
        let filename = pathExtension.isEmpty ? UUID().uuidString : UUID().uuidString + "." + pathExtension
        let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(filename)

        var didStartSecurityScope = false
        if sourceURL.startAccessingSecurityScopedResource() {
            didStartSecurityScope = true
        }

        defer {
            if didStartSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            return nil
        }
    }

    private static func resolvedFilenameExtension(for contentType: UTType) -> String {
        if let preferred = contentType.preferredFilenameExtension {
            return preferred
        }

        if contentType.conforms(to: .movie) {
            return "mov"
        }

        return "jpg"
    }
}
