# PrivyGallery Import / Export Technical Review

This document describes the intended import and export behavior for PrivyGallery’s `.vault` backup feature, the current technical design, and the functional/security requirements that should be reviewed before the feature is finalized.

It is written for external experts who may review the backup architecture, memory behavior, cryptographic packaging, recovery semantics, and user-facing import/export workflow.

## 1. Product Goals

PrivyGallery is a local encrypted media vault. Users import photos and videos into app-managed storage, and the app stores media and metadata locally using encryption. The `.vault` feature exists so users can create encrypted backups of their app data and later restore those backups into the app.

The import/export feature should satisfy these goals:

- Export the current vault space into one or more encrypted `.vault` files.
- Allow users to keep generated `.vault` files inside the app until they decide to share or save them elsewhere.
- Allow users to manually export one or more generated `.vault` files through the system share sheet.
- Restore one or more `.vault` files into the currently unlocked app space.
- Avoid high memory usage with large media libraries.
- Avoid exposing plaintext media outside controlled temporary working directories.
- Provide clear progress feedback and user-readable errors.
- Support ordinary media and strongly encrypted media without changing their security semantics.

## 2. User-Facing Export Workflow

The current intended export workflow is:

1. User opens Settings.
2. User chooses “Back Up Current Space”.
3. App asks the user to verify the current space password.
4. App asks the user to set and confirm an export password.
5. App generates one or more `.vault` backup files.
6. Generated `.vault` files are saved into the app’s persistent backup directory:
   `Application Support/BackupFiles`.
7. App shows a success alert:
   “Backup saved. N backup files were created.”
8. App does not automatically open the system share sheet.
9. User can later open Settings → Current Backup Files.
10. User can export or delete stored `.vault` files manually.

This split is intentional. Backup generation can be slow and memory-intensive, and immediately presenting a share sheet after generation can create presentation conflicts or make it difficult to reason about file lifetime. By storing generated backup files first, the app separates “create backup” from “send backup somewhere”.

## 3. Current Backup File Management

Generated backup files are managed by `VaultBackupFileStore`.

The store is responsible for:

- Creating the persistent backup directory.
- Moving generated final `.vault` files out of the temporary export session directory.
- Listing stored `.vault` files.
- Reporting file name, file size, and creation date.
- Deleting only stored backup files.
- Avoiding accidental deletion of media library content.

Stored backup files are represented by:

```swift
struct StoredVaultBackupFile {
    let url: URL
    let fileName: String
    let byteCount: Int64
    let createdAt: Date
}
```

The Settings UI contains a “Current Backup Files” page. It uses a native SwiftUI `List` and supports:

- Listing stored `.vault` files.
- Single-file export.
- Batch export.
- Single-file deletion.
- Batch deletion.
- Deletion confirmation.

Deleting a stored `.vault` removes only the backup file from app storage. It must not delete or modify media in the vault.

## 4. User-Facing Import Workflow

The intended restore workflow is:

1. User opens Settings.
2. User chooses “Restore to Current Space”.
3. User selects one or more `.vault` files.
4. App asks the user to verify the current space password.
5. App asks for the backup password that was used during export.
6. App reads each selected `.vault`.
7. App decrypts and restores each backup into the currently active space.
8. App refreshes media library state.
9. App shows a restore summary.

The restore summary should include:

- Regular photos restored.
- Regular videos restored.
- Strongly encrypted items restored.
- Albums restored.
- Skipped items.
- Failed items.

The restore operation should be additive. It should merge restored content into the current space instead of replacing the existing library, unless a future product decision explicitly adds destructive restore modes.

## 5. `.vault` Format Overview

The current implementation uses a `.vault` format identified by:

- Outer magic: `SVEX`
- Current format version: `2`
- Inner archive magic: `SVAR`
- Inner archive version: `1`

The `.vault` file is not a plaintext ZIP file. It is an encrypted container built from an app-specific archive.

The high-level export pipeline is:

```text
metadata snapshot + encrypted app media
    -> stream-decrypt media from app storage
    -> write plaintext app archive (SVAR) to a temporary file
    -> compress media chunks before writing them into the archive
    -> encrypt the archive using chunked AES-GCM
    -> finalize .vault file
    -> move final .vault into Application Support/BackupFiles
```

The high-level import pipeline is:

```text
.vault file
    -> read SVEX header
    -> derive key from user password
    -> decrypt archive chunks with AES-GCM verification
    -> write temporary SVAR archive
    -> read manifest and media blobs
    -> restore media into current app space
    -> update metadata
    -> refresh media library
```

## 6. Splitting Strategy

Large exports may produce multiple `.vault` files. Each file is intended to be independently restorable.

The current export planner groups media items into parts using approximate limits such as:

- Maximum items per part.
- Target plaintext byte size per part.
- Large items may force a part boundary.

Each part has:

- Its own `.vault` file.
- Its own header.
- Its own KDF salt.
- Its own derived encryption key.
- Its own manifest subset.
- Its own encrypted archive.

The files are not conventional split volumes. A single generated `.vault` file should be restorable on its own, even if other parts exist. When users import multiple parts, the import service processes them sequentially and combines the restore summary.

## 7. Manifest and Archive Model

The inner archive contains:

- Archive magic and version.
- A JSON manifest.
- A list of blob entries.
- Blob payloads.

The manifest describes:

- Export timestamp.
- Source space identifier.
- Part index.
- Total parts.
- Album records.
- Media item records.
- Blob records.

Media item records include metadata such as:

- Item UUID.
- Display name.
- Creation/import/update timestamps.
- Media kind.
- Trash/archive state.
- Strong encryption flag.
- Original filename.
- Content type identifier.
- Location metadata if available.
- Album membership.

During restore, original internal relative paths from the backup are not reused as final destination paths. The app writes restored media into new current-space storage paths and updates metadata accordingly.

## 8. Compression Design

Compression happens before encryption.

This matters because encrypted data is effectively incompressible. The current design compresses media chunks before they are placed into the inner archive. The implementation uses Apple’s Compression framework, currently with an LZFSE-oriented path.

Important constraints:

- Compression should never require all media to be loaded into memory.
- Compression should operate per chunk or per item stream.
- If compression is not beneficial for a chunk, the archive may store the raw payload.
- Compression logs must not include full file paths or private filenames.

Review questions:

- Is chunk-level compression the right tradeoff for photos and videos?
- Should already-compressed formats such as HEIC/JPEG/H.264/H.265 skip compression more aggressively?
- Should the archive record compression ratio statistics for diagnostics?
- Should compression be optional, with a “fast backup” vs “smaller backup” mode?

## 9. Encryption Design

The outer `.vault` uses password-based encryption.

Current key derivation:

- Algorithm: PBKDF2-HMAC-SHA256
- Salt: random per `.vault` file
- Output: 32-byte symmetric key
- Rounds: currently encoded in the header

Current encryption:

- Algorithm: AES-GCM
- Mode: chunked AEAD
- Each archive chunk is sealed independently.
- Each chunk uses its own nonce.
- Each chunk has its own authentication tag.
- Associated data binds chunk encryption to the backup context.

The associated data currently includes values conceptually similar to:

```text
SVEX-v2 | partIndex | totalParts | chunkIndex | archiveByteCount
```

This provides integrity binding between:

- File format version.
- Backup part number.
- Total part count.
- Chunk position.
- Archive length.

Review questions:

- Is PBKDF2-HMAC-SHA256 with the current round count sufficient for the target devices and threat model?
- Should Argon2id or scrypt be considered in a future format version?
- Should the KDF parameters adapt to device performance?
- Should the header authenticate additional metadata?
- Should every chunk record include an explicit header hash or manifest hash in AAD?

## 10. Memory Safety Requirements

The backup system must avoid process termination caused by memory pressure.

Required behavior:

- Do not read all media into one `Data`.
- Do not build a giant in-memory archive.
- Do not call `AES.GCM.seal` on the entire backup archive at once.
- Do not decrypt an entire `.vault` into memory.
- Use temporary files and chunked reads/writes.
- Use `FileHandle` or equivalent streaming APIs for large payloads.
- Use `autoreleasepool` in long loops where UIKit/Foundation objects may accumulate.
- Ensure temporary plaintext working files are deleted on success, cancellation, and failure.

The current design writes an intermediate archive to a temporary export directory, encrypts it chunk by chunk, finalizes the `.vault`, then moves the final `.vault` into persistent backup storage.

## 11. Temporary File Policy

Temporary files may include:

- Plain archive files.
- Partial encrypted `.vault.partial` files.
- Temporary import archives.
- Restored staging media during import.

Rules:

- `.partial` files must never be shown to users.
- User-facing errors must not include `.partial` filenames or internal paths.
- Temporary export session directories may be cleaned after final `.vault` files are safely moved into `Application Support/BackupFiles`.
- Final `.vault` files in `BackupFiles` must not be deleted automatically after a share sheet closes.
- Import staging directories must be cleaned after restore success, cancellation, or failure.
- Backup recovery logic should clean abandoned temporary sessions after crashes.

The `BackupOperationRecoveryService` tracks active import/export operations so unfinished temporary paths can be cleaned on next launch.

## 12. Share / System Export Behavior

System export is now separate from backup generation.

The app should not present `UIActivityViewController` automatically after backup generation. Instead:

- Generated backups remain in `Application Support/BackupFiles`.
- The user opens “Current Backup Files”.
- The user chooses one or more `.vault` files.
- The app presents the system share sheet for those selected files.
- When the share sheet closes, the app does not delete the stored `.vault` files.

This design avoids:

- SwiftUI presentation collisions between progress sheets, alerts, and share sheets.
- Deleting files before the share sheet reads them.
- Confusing users when backup generation is complete but the share sheet takes time to appear.

## 13. Restore Error Handling

The restore UI should distinguish these cases:

### Wrong password

User-facing message:

```text
The password is incorrect and this backup file cannot be decrypted. Please check and try again.
```

This should be used when:

- Key derivation succeeds but AES-GCM authentication fails.
- The authentication tag does not verify.
- The error is highly likely to be caused by an incorrect backup password.

### Invalid or corrupted file

User-facing message:

```text
The backup file is invalid or corrupted and cannot be restored.
```

This should be used when:

- Magic bytes are wrong.
- Version is unsupported.
- Header length is invalid.
- Header JSON cannot be decoded.
- Archive structure is malformed.
- Blob lengths do not match the manifest.

### Unsupported legacy format

Because this is still a beta-stage app, compatibility with older experimental backup formats is not guaranteed. The app may explicitly reject unsupported legacy versions with a clear message.

## 14. Progress Reporting Requirements

Import and export must use real phase-aware progress rather than a static spinner whenever possible.

Current progress model:

```swift
struct VaultTransferProgress {
    enum Phase {
        case scanning
        case planning
        case archiving
        case compressing
        case encrypting
        case writingPart
        case preparingShareSheet
        case waitingForShareSheet
        case reading
        case validating
        case decrypting
        case extracting
        case restoring
        case refreshing
        case completed
        case cancelled
    }

    let currentPart: Int
    let totalParts: Int
    let currentItem: Int
    let totalItems: Int
    let currentBytes: Int64
    let totalBytes: Int64
    let message: String
    let fractionCompleted: Double?
}
```

For export, users should see phases such as:

- Scanning media.
- Planning backup parts.
- Writing backup archive.
- Compressing.
- Encrypting.
- Saving backup files.
- Completed.

For import, users should see phases such as:

- Reading backup file.
- Validating backup.
- Decrypting.
- Extracting backup.
- Restoring media.
- Refreshing media library.
- Completed.

When `fractionCompleted` is known, the UI should show determinate progress. When it is unknown, the UI may show an indeterminate spinner with a specific message.

## 15. Debug Logging Requirements

Debug logging should help diagnose performance and file lifecycle issues without leaking private data.

Allowed in debug logs:

- Phase names.
- Part index.
- Total part count.
- Item count.
- Byte counts.
- Durations.
- High-level media kind.
- Hashed IDs.

Not allowed in logs:

- User passwords.
- Derived keys.
- Salt values.
- AES-GCM nonce values.
- Authentication tags.
- Full file paths.
- Full original filenames.
- Sensitive media names.

Recommended log prefix:

```text
[VaultTransfer]
```

Useful export events:

- `export.start`
- `export.plan`
- `export.part.start`
- `export.archive.item`
- `export.archive.finish`
- `export.encrypt.begin`
- `export.encrypt.chunk`
- `export.encrypt.finish`
- `export.part.finalize.move`
- `export.part.final.exists`
- `export.saved`
- `export.cleanup`

Useful import events:

- `import.start`
- `import.file.open`
- `import.header`
- `import.decrypt.chunk`
- `import.archive.read`
- `import.restore.item`
- `import.file.finish`
- `import.complete`
- `import.cleanup`

## 16. Security Boundary for Strongly Encrypted Media

Strongly encrypted media may have stricter preview and playback constraints elsewhere in the app. The backup layer should preserve the item’s strong-protection metadata and restore it as such.

During export:

- Strongly encrypted items may be temporarily decrypted only inside controlled export processing.
- Plaintext must not be written to long-lived cache directories.
- Plaintext temporary files must be cleaned.
- The final `.vault` remains encrypted with the export password.

During import:

- Restored strong-protected items must remain marked as strong-protected.
- They should not be routed through ordinary trash or ordinary album behavior if the rest of the app treats them differently.
- Restore should not weaken preview, deletion, or secure playback policies.

Review question:

- Should strong-protected items be encrypted inside the archive with an additional item-level key before archive-level encryption, or is archive-level encryption sufficient for backup files?

## 17. File Protection and Local Persistence

Stored backup files should use iOS file protection where possible.

Current expected storage:

```text
Application Support/
    BackupFiles/
        PrivyGallery Backup yyyy-MM-dd HH-mm.vault
        PrivyGallery Backup yyyy-MM-dd HH-mm (1 of 3).vault
        PrivyGallery Backup yyyy-MM-dd HH-mm (2 of 3).vault
```

Recommended protection:

- Apply `FileProtectionType.complete` to final `.vault` files.
- Apply protection to the backup directory.
- Avoid placing final `.vault` files in temporary directories.
- Do not delete final stored `.vault` files after share sheet dismissal.

Review questions:

- Should stored `.vault` files be excluded from device backups?
- Should the app warn users that keeping backup files inside app storage does not protect them if the app is deleted?
- Should the app provide an explicit “Export and Remove Local Copy” action?

## 18. Functional Requirements Checklist

### Export generation

- User can export the current unlocked space.
- Empty export password is rejected.
- Password confirmation mismatch is rejected.
- Backup generation shows progress.
- Backup generation can handle large libraries without loading all media into memory.
- Backup generation creates one or more `.vault` files.
- Generated `.vault` files are saved persistently in app storage.
- Backup generation does not automatically present the share sheet.
- Temporary files are cleaned after success, cancellation, or failure.
- Stored `.vault` files survive app restart.

### Stored backup file management

- User can view stored `.vault` files.
- User can see file name, size, and creation date.
- User can export one file.
- User can export multiple files.
- User can delete one file after confirmation.
- User can delete multiple files after confirmation.
- Deleting backup files does not affect media library content.
- Share sheet dismissal does not delete stored `.vault` files.

### Restore

- User can select one or more `.vault` files.
- User can enter backup password.
- Wrong password shows a clear error.
- Corrupt file shows a distinct invalid-file error where possible.
- Restore merges data into the current space.
- Restore refreshes the media library.
- Restore completion shows counts for photos, videos, strong-protected items, albums, skipped items, and failed items.
- Failed restore does not leave partial metadata or orphan files.

## 19. Open Design Questions for Expert Review

1. Is the current chunked AES-GCM construction appropriate, including nonce generation, AAD composition, and chunk metadata?
2. Should the backup header itself be authenticated separately or only through chunk AAD?
3. Should the manifest include a hash of the archive payload or per-blob hashes?
4. Is PBKDF2-HMAC-SHA256 with the current round count sufficient, or should a memory-hard KDF be considered?
5. Should every `.vault` part be fully independent, or should multi-part exports include an optional set manifest?
6. Should backup files stored in `Application Support/BackupFiles` be excluded from iCloud/device backups?
7. Should the app support resumable export/import for very large libraries?
8. Should video blobs be compressed at all, or should compression be skipped for known already-compressed formats?
9. Should the app provide a backup verification command before sharing?
10. Should the import process support dry-run validation before writing media?
11. Should old experimental `.vault` versions be unsupported, or should a migration importer be retained?
12. Should backup password strength requirements be stricter than four characters?

## 20. Relevant Implementation Files

Key files for review:

- `SecurityFolder/Core/Services/VaultExportService.swift`
- `SecurityFolder/Core/Services/VaultImportService.swift`
- `SecurityFolder/Core/Services/VaultBackupFileStore.swift`
- `SecurityFolder/Core/Services/VaultTransferProgress.swift`
- `SecurityFolder/Core/Services/BackupOperationRecoveryService.swift`
- `SecurityFolder/Features/Settings/Views/SettingsView.swift`
- `SecurityFolder/Features/Settings/Views/StoredVaultBackupFilesView.swift`
- `SecurityFolder/Shared/Components/ActivityView.swift`

Related documentation:

- `docs/vault-format.md`

