#!/usr/bin/env python3
"""Run model and backup-schema regression checks with the macOS Swift toolchain."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / 'SecurityFolder/Core'


def record(file, name, replacement):
    source = (CORE / 'Services' / file).read_text()
    start = source.index(f'struct {name}: Codable {{')
    end = source.index('\n}', start) + 2
    return source[start:end].replace(name, replacement, 1)


records = '\n'.join([
    record('EncryptedMetadataStore.swift', 'EncryptedAlbumRecord', 'MetadataAlbum'),
    record('EncryptedMetadataStore.swift', 'EncryptedItemRecord', 'MetadataItem'),
    record('VaultExportService.swift', 'VaultBackupAlbumRecord', 'ExportAlbum'),
    record('VaultExportService.swift', 'VaultBackupItemRecord', 'ExportItem'),
    record('VaultImportService.swift', 'VaultBackupAlbumRecord', 'ImportAlbum'),
    record('VaultImportService.swift', 'VaultBackupItemRecord', 'ImportItem'),
])
def declaration(source, marker):
    start = source.index(marker)
    body = source.index('{', start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


view_model = (ROOT / 'SecurityFolder/Features/Library/ViewModels/MediaLibraryViewModel.swift').read_text()
presentation = (ROOT / 'SecurityFolder/Features/Library/Models/LibraryPresentationModels.swift').read_text()
records += '\n' + declaration(presentation, 'struct AlbumSelectionOption:')
records += '\nfinal class MembershipHarness {\nvar albums: [VaultAlbum] = []\nvar items: [VaultItem] = []\nvar secureFeatureEnabled = true\nvar saveCount = 0\nfunc album(for id: UUID) -> VaultAlbum? { albums.first { $0.id == id } }\nfunc saveAndRefresh() { saveCount += 1 }\n'
for name in ['albumSelectionOptions', 'setMembership']:
    records += declaration(view_model, f'func {name}(') + '\n'
records += '}\n'

checks = r'''
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
let cBlue = AlbumColor(rawValue: "blue")!
let cRed = AlbumColor(rawValue: "red")!
let cGreen = AlbumColor(rawValue: "green")!
let cOrange = AlbumColor(rawValue: "orange")!
check(AlbumColor(rawValue: "#18a7c2")?.rawValue == "#18A7C2", "Custom RGB colors must normalize")
check(AlbumColor(rawValue: "#297DF2") == cBlue, "Legacy and custom colors must deduplicate")
for invalid in ["#GG0000", "#123", "#12345678", "unknown", "123456"] {
    check(AlbumColor(rawValue: invalid) == nil, "Invalid colors must be ignored")
}
let blue = VaultAlbum(name: "Travel", kind: .custom, space: .spaceA, colorRawValue: "blue")
let red = VaultAlbum(name: "Family", kind: .custom, space: .spaceA, colorRawValue: "red")
let anotherBlue = VaultAlbum(name: "Work", kind: .custom, space: .spaceA, colorRawValue: "blue")
let green = VaultAlbum(name: "Picks", kind: .custom, space: .spaceA, colorRawValue: "green")
let secure = VaultAlbum(name: "Secure", kind: .secureCustom, space: .spaceA, colorRawValue: "orange")
let otherSpace = VaultAlbum(name: "Other", kind: .custom, space: .spaceB, colorRawValue: "purple")
let system = VaultAlbum(name: "Videos", kind: .allVideos, space: .spaceA, colorRawValue: "yellow")
let unknown = VaultAlbum(name: "Future", kind: .custom, space: .spaceA, colorRawValue: "future-color")
let plain = VaultAlbum(name: "Uncolored", kind: .custom, space: .spaceA)
let item = VaultItem(name: "Clip", mediaKind: .video, space: .spaceA, relativePath: "clip.mov", originalFilename: "clip.mov", contentTypeIdentifier: "com.apple.quicktime-movie")
check(item.albumColors().isEmpty, "New media must have no colors")
item.albums = [blue, red, anotherBlue, secure, otherSpace, system, unknown, plain]
check(item.albumColors() == [cBlue, cRed], "Colors must deduplicate and respect space/protection boundaries")
check(item.albumColors(excluding: red.id) == [cBlue], "Current album must be excluded")
check(item.albumColors(excluding: blue.id) == [cBlue, cRed], "Same-colored other album must remain visible")
item.albums.append(green)
check(item.albumColors() == [cBlue, cGreen, cRed], "More than two colors must remain available for overflow indication")
item.albums.reverse()
check(item.albumColors() == [cBlue, cGreen, cRed], "Color order must not depend on membership order")
blue.colorRawValue = nil
anotherBlue.colorRawValue = nil
check(item.albumColors() == [cGreen, cRed], "Clearing album colors must update existing media")
item.albums.removeAll { $0.id == red.id }
check(item.albumColors() == [cGreen], "Removing membership must remove its color")
item.isStrongProtected = true
check(item.albumColors() == [cOrange], "Protected media must only display protected album colors")
for (duration, expected) in [(0.2, "0:01"), (59.9, "0:59"), (60, "1:00"), (3599, "59:59"), (3600, "1:00:00"), (3661, "1:01:01"), (Double.infinity, "--:--"), (-1, "--:--"), (Double.nan, "--:--"), (Double.greatestFiniteMagnitude, "--:--")] {
    item.videoDuration = duration
    check(item.videoDurationText == expected, "Unexpected duration display: \(duration)")
}
item.videoDuration = nil
check(item.videoDurationText == "--:--", "Unknown duration must not look like a still image")
let id = UUID().uuidString
let albumJSON: [String: Any] = ["id": id, "name": "Travel", "kindRawValue": "custom", "sortOptionRawValue": "newestFirst", "customOrderedItemIDs": [], "showsCover": false, "libraryOrderIndex": 0]
let itemJSON: [String: Any] = ["id": UUID().uuidString, "name": "Clip", "createdAt": 0, "importedAt": 0, "updatedAt": 0, "mediaKindRawValue": "video", "isInTrash": false, "isArchived": false, "isStrongProtected": false, "relativePath": "clip.mov", "originalFilename": "clip.mov", "contentTypeIdentifier": "com.apple.quicktime-movie", "albumIDs": [id]]
let decoder = JSONDecoder()
let encoder = JSONEncoder()
let oldAlbum = try JSONSerialization.data(withJSONObject: albumJSON)
let oldItem = try JSONSerialization.data(withJSONObject: itemJSON)
let oldMetadataAlbum = try decoder.decode(MetadataAlbum.self, from: oldAlbum)
let oldMetadataItem = try decoder.decode(MetadataItem.self, from: oldItem)
let oldBackupAlbum = try decoder.decode(ImportAlbum.self, from: oldAlbum)
let oldBackupItem = try decoder.decode(ImportItem.self, from: oldItem)
check(oldMetadataAlbum.colorRawValue == nil && oldBackupAlbum.colorRawValue == nil, "Old albums must load without a color")
check(oldMetadataItem.videoDuration == nil && oldBackupItem.videoDuration == nil, "Old items must load without duration")
var coloredJSON = albumJSON
coloredJSON["colorRawValue"] = "#18A7C2"
var timedJSON = itemJSON
timedJSON["videoDuration"] = 3661.5
let coloredData = try JSONSerialization.data(withJSONObject: coloredJSON)
let timedData = try JSONSerialization.data(withJSONObject: timedJSON)
let exportAlbum = try decoder.decode(ExportAlbum.self, from: coloredData)
let exportItem = try decoder.decode(ExportItem.self, from: timedData)
let restoredAlbum = try decoder.decode(ImportAlbum.self, from: encoder.encode(exportAlbum))
let restoredItem = try decoder.decode(ImportItem.self, from: encoder.encode(exportItem))
check(restoredAlbum.colorRawValue == "#18A7C2", "Backup export/import must preserve album color")
check(restoredItem.videoDuration == 3661.5, "Backup export/import must preserve duration")
check(restoredItem.albumIDs == [id], "Backup export/import must preserve membership")
let metadataAlbum = try decoder.decode(MetadataAlbum.self, from: coloredData)
let metadataItem = try decoder.decode(MetadataItem.self, from: timedData)
let reloadedAlbum = try decoder.decode(MetadataAlbum.self, from: encoder.encode(metadataAlbum))
let reloadedItem = try decoder.decode(MetadataItem.self, from: encoder.encode(metadataItem))
check(reloadedAlbum.colorRawValue == "#18A7C2" && reloadedItem.videoDuration == 3661.5, "Metadata records must round-trip new fields")
let membership = MembershipHarness()
let library = VaultAlbum(name: "Library", kind: .allPhotos, space: .spaceA)
let sameName = VaultAlbum(name: green.name, kind: .custom, space: .spaceA)
let first = VaultItem(name: "First", mediaKind: .photo, space: .spaceA, relativePath: "a.jpg", originalFilename: "a.jpg", contentTypeIdentifier: "public.jpeg", albums: [green])
let second = VaultItem(name: "Second", mediaKind: .video, space: .spaceA, relativePath: "b.mov", originalFilename: "b.mov", contentTypeIdentifier: "public.movie", albums: [red])
membership.albums = [library, green, red, sameName, secure]
membership.items = [first, second]
let selected: Set<UUID> = [first.id, second.id]
let options = membership.albumSelectionOptions(for: selected, currentAlbumID: library.id)
check(options.first { $0.id == green.id }!.isMixed, "Partial membership must be marked mixed")
check(!options.first { $0.id == sameName.id }!.isMixed, "Membership must use IDs, not duplicate names")
check(!options.contains { $0.id == secure.id }, "Regular media must not target protected albums")
membership.setMembership(of: selected, changes: [:], currentAlbumID: library.id)
check(membership.saveCount == 0 && second.albums == [red], "Untouched mixed selection must not change membership")
membership.setMembership(of: selected, changes: [sameName.id: true], currentAlbumID: library.id)
check(first.albums.contains(green) && !second.albums.contains(green), "Changing another album must preserve mixed membership")
check(first.albums.contains(sameName) && second.albums.contains(sameName), "Explicit addition must apply to all selected items")
membership.setMembership(of: [first.id], changes: [green.id: false], currentAlbumID: green.id)
check(!first.albums.contains(green), "Manage albums must allow removal from the current album")
check(membership.items.count == 2, "Removing membership must not delete media")
membership.setMembership(of: selected, changes: [secure.id: true], currentAlbumID: library.id)
check(!first.albums.contains(secure) && !second.albums.contains(secure), "Invalid targets must not cross protection boundaries")
print("PASS: album colors, space/protection boundaries, duration formatting, mixed batch membership, legacy metadata, backup record compatibility")
'''
with tempfile.TemporaryDirectory(prefix='privy-metadata-tests-') as folder:
    folder = Path(folder)
    source = folder / 'main.swift'
    source.write_text('import Foundation\n' + records + '\n' + checks)
    models = ['VaultSpaceKind', 'MediaAlbumKind', 'AlbumSortOption', 'MediaKind', 'VaultAlbum', 'VaultItem', 'AlbumColor']
    binary = folder / 'checks'
    subprocess.run(['xcrun', 'swiftc', *[str(CORE / 'Models' / f'{m}.swift') for m in models], str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
