#!/usr/bin/env python3
"""Compile real search code and exercise metadata matching and visibility boundaries."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / 'SecurityFolder/Core'
source = (ROOT / 'SecurityFolder/Features/Library/ViewModels/MediaLibraryViewModel.swift').read_text()

def declaration(marker):
    start = source.index(marker)
    body = source.index('{', start)
    depth, end = 1, body + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

harness = '''import Foundation
@MainActor final class Harness {
    var items: [VaultItem] = []
    var albums: [VaultAlbum] = []
    let space = VaultSpaceKind.spaceA
    func mediaItems(for albumID: UUID) -> [VaultItem] {
        guard let album = albums.first(where: { $0.id == albumID }) else { return [] }
        return items.filter { itemMatches($0, album: album) }
    }
'''
for marker in ['func searchItems(', 'func searchAlbums(', 'private func itemMatches(']:
    harness += declaration(marker) + '\n'
harness += '}\n'
harness += r'''
@main struct Checks {
    @MainActor static func main() async {
        let h = Harness()
        let album = VaultAlbum(name: "旅行", kind: .custom, space: .spaceA)
        let secure = VaultAlbum(name: "旅行私密", kind: .secureCustom, space: .spaceA)
        let trash = VaultAlbum(name: "Trash", kind: .trash, space: .spaceA)
        h.albums = [album, secure, trash, VaultAlbum(name: "旅行B", kind: .custom, space: .spaceB)]
        let now = Date()
        func make(_ name: String, _ filename: String, _ kind: MediaKind = .photo) -> VaultItem {
            VaultItem(name: name, importedAt: now, originalCapturedAt: now, mediaKind: kind,
                      space: .spaceA, relativePath: "unused", originalFilename: filename, contentTypeIdentifier: "public.image", albums: [album])
        }
        let photo = make("Ｃａｆé 海边", "IMG_0042.HEIC")
        let live = make("Live", "live.heic", .livePhoto)
        let video = make("Video", "clip.MOV", .video)
        let hidden = make("海边", "hidden.heic"); hidden.isStrongProtected = true; hidden.albums = [secure]
        let archived = make("海边", "archive.heic"); archived.isArchived = true
        let deleted = make("海边", "trash.heic"); deleted.isInTrash = true
        let other = make("海边", "other.heic"); other.space = .spaceB
        let unknown = make("Unknown", "unknown.heic"); unknown.originalCapturedAt = nil
        h.items = [photo, live, video, hidden, archived, deleted, other, unknown]
        var q = MediaSearchQuery()
        var result = await h.searchItems(query: q, albumID: album.id, wholeSpace: true)
        precondition(Set(result.map(\.id)) == Set([photo.id, live.id, video.id, unknown.id]), "Global visibility must respect space and protection")
        q.text = "  cafe  "
        result = await h.searchItems(query: q, albumID: album.id, wholeSpace: true)
        precondition(result.map(\.id) == [photo.id], "Width/case/diacritic folding and trimming")
        q.text = "img_0042"
        result = await h.searchItems(query: q, albumID: album.id, wholeSpace: false)
        precondition(result.map(\.id) == [photo.id], "Original filename matching")
        q.text = "live"
        result = await h.searchItems(query: q, albumID: album.id, wholeSpace: true)
        precondition(result.map(\.id) == [live.id], "Live Photos match by name")
        q.text = "CLIP.mov"
        result = await h.searchItems(query: q, albumID: album.id, wholeSpace: true)
        precondition(result.map(\.id) == [video.id], "Videos match by original filename")
        q.text = ""; q.type = .photos
        result = await h.searchItems(query: q, albumID: album.id, wholeSpace: true)
        precondition(result.contains(live) && !result.contains(video), "Live Photos belong to photos")
        q.type = .videos
        result = await h.searchItems(query: q, albumID: album.id, wholeSpace: true)
        precondition(result.map(\.id) == [video.id], "Video-only filter")
        q.type = .all; q.usesDateRange = true; q.startDate = now; q.endDate = now
        result = await h.searchItems(query: q, albumID: album.id, wholeSpace: true)
        precondition(!result.contains(unknown) && result.count == 3, "Capture dates must not fall back to import dates")
        q.dateField = .imported
        result = await h.searchItems(query: q, albumID: album.id, wholeSpace: true)
        precondition(result.contains(unknown), "Import date supports missing EXIF")
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let upper = calendar.date(byAdding: .day, value: 1, to: start)!
        precondition(q.matches(name: "", filename: "", kind: .photo, capturedAt: nil, importedAt: upper.addingTimeInterval(-0.001)), "End date is inclusive")
        precondition(!q.matches(name: "", filename: "", kind: .photo, capturedAt: nil, importedAt: upper), "Next day is excluded")
        q = MediaSearchQuery(); q.text = "海边"
        result = await h.searchItems(query: q, albumID: secure.id, wholeSpace: false)
        precondition(result.map(\.id) == [hidden.id], "Secure search stays inside secure album")
        result = await h.searchItems(query: q, albumID: trash.id, wholeSpace: false)
        precondition(result.map(\.id) == [deleted.id], "Trash search stays inside trash")
        precondition(h.searchAlbums(text: "旅行").map(\.id) == [album.id], "Album search excludes secure and other spaces")
        // Full metadata matching must find items beyond the initial 48-cell page.
        h.items = (0..<1000).map { make("Photo \($0)", "\($0).heic") }
        q.text = "999.heic"
        result = await h.searchItems(query: q, albumID: album.id, wholeSpace: true)
        precondition(result.count == 1 && result[0].originalFilename == "999.heic", "Search precedes pagination")
        let cancelled = Task { @MainActor in
            await h.searchItems(query: MediaSearchQuery(), albumID: album.id, wholeSpace: true)
        }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        precondition(cancelledResult.isEmpty, "Cancelled requests cannot publish results")
        let begin = Date()
        let documents = (0..<10000).map { MediaSearchDocument(id: UUID(), name: "Photo \($0)", filename: "IMG_\($0).HEIC", kindRawValue: "photo", capturedAt: now, importedAt: now) }
        q.text = "9999"
        let ids = MediaSearchDocument.matchingIDs(in: documents, query: q, newestImportFirst: true)
        precondition(ids.count == 1)
        print("PASS: search matching, dates, scope isolation, full-library query and cancellation; 10k records including fixture creation: \(Int(Date().timeIntervalSince(begin) * 1000)) ms")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='privygallery-search-') as directory:
    folder = Path(directory)
    test = folder / 'checks.swift'
    test.write_text(harness)
    models = ['VaultSpaceKind', 'MediaAlbumKind', 'AlbumSortOption', 'MediaKind', 'VaultAlbum', 'VaultItem', 'AlbumColor']
    binary = folder / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *[str(CORE / 'Models' / f'{m}.swift') for m in models], str(ROOT / 'SecurityFolder/Features/Library/Models/MediaSearchQuery.swift'), str(test), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
