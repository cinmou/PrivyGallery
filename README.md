<p align="center">
  <img src="Materials/docs/assets/app-icon.png" alt="PrivyGallery" width="120" />
</p>

<h1 align="center">PrivyGallery</h1>

<p align="center">
  <strong>Dual Space Vault</strong> — a local-first, encrypted home for the photos and videos you'd rather keep private.
</p>

<p align="center">
  <strong>English</strong> ·
  <a href="README.zh-Hans.md">简体中文</a> ·
  <a href="README.zh-Hant.md">繁體中文</a>
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/privygallery-dual-space-vault/id6765981187">App Store</a> ·
  <a href="Materials/docs/index.html">Landing Page</a> ·
  <a href="tools/vault-unpacker/">.vault Unpacker</a> ·
  <a href="Materials/docs/vault-format.md">Backup Format</a> ·
  <a href="SECURITY.md">Security</a> ·
  <a href="PRIVACY.md">Privacy</a>
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/privygallery-dual-space-vault/id6765981187">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" height="56" />
  </a>
</p>

---

## Overview

PrivyGallery is a native iOS private media vault. Photos and videos you import are
encrypted on-device before they're stored, organized into albums and two fully
independent spaces, and never depend on a backend server to stay protected.

One simple idea: **your private media stays on your device, encrypted, and under
your control** — no account, no upload, no analytics.

## Screenshots

| Library | Albums | Media Player |
| :-----: | :----: | :----------: |
| <img src="Materials/images/1.PNG" width="220" /> | <img src="Materials/images/2.png" width="220" /> | <img src="Materials/images/6.png" width="220" /> |
| **Settings** | **Settings** | **Backup** |
| <img src="Materials/images/3.PNG" width="220" /> | <img src="Materials/images/4.PNG" width="220" /> | <img src="Materials/images/5.PNG" width="220" /> |

## Built on Apple's security stack

PrivyGallery deliberately **does not roll its own cryptography**. It relies on the
security capabilities Apple provides, used in standard ways:

| Capability | Apple API | Role in PrivyGallery |
| --- | --- | --- |
| Symmetric encryption | **CryptoKit** `AES-GCM` | Encrypts every photo/video and the `.vault` backup |
| Key storage & wrapping | **Keychain Services** | Stores each space's wrapped data-encryption key |
| Biometric unlock | **LocalAuthentication** + Keychain `biometryCurrentSet` | Face ID / Touch ID gated access to the space key |
| Hardware key protection | **Secure Enclave** | Backs biometric protection of keys |
| At-rest protection | **Data Protection** (`FileProtectionType.complete`) | OS-level file encryption for stored data |
| Key derivation | `PBKDF2-HMAC-SHA256` (CommonCrypto) | Derives the backup key from your password |

Because the design leans on audited, well-understood system primitives rather than a
custom cipher, the trust model is easier to reason about — and the parts that matter
(the `.vault` format) are fully documented and openly reviewable.

## Core Concepts

- **Two independent spaces** — `Space A` and `Space B`, each with its own passcode,
  wrapped key, media storage, and metadata. No state is shared between them.
- **Per-space data-encryption key (DEK)** — randomly generated, wrapped by a key
  derived from your passcode. Changing your passcode re-wraps the DEK; it never
  re-encrypts your whole library.
- **Coercion passcode** — a special passcode triggers an emergency local wipe.
- **Advanced Data Protection** — strongly protected media uses a stricter, isolated
  preview path.

## Main Features

- 🔐 On-device `AES-GCM` encryption before storage
- 🪟 Two independent spaces with separate passcodes
- 🔢 4-digit, 6-digit, or complex alphanumeric passcodes
- 🚨 Coercion passcode → emergency wipe
- 👁️ Face ID / biometric unlock with auto-lock
- 🗂️ Custom albums, secure albums, archive, and trash
- 📥 Import from Photos or Files (optional delete-after-import)
- 📸 Screen-privacy behavior for capture / recording
- 💾 Portable, encrypted `.vault` backups

## The `.vault` backup format

PrivyGallery can export an entire space as a single encrypted `.vault` file. The
format is **open and documented** — the goal is transparency and avoiding lock-in,
**not** hiding the design.

At a glance (full spec in [`Materials/docs/vault-format.md`](Materials/docs/vault-format.md)):

1. A cleartext JSON header (`SVEX`, v2) declaring the KDF, salt, cipher, chunk size,
   and multi-part info.
2. The body is an inner archive (`SVAR`) split into chunks, each sealed independently
   with `AES-GCM` (each chunk authenticated against the format version, part index,
   chunk index, and archive length).
3. The inner archive holds a JSON manifest (albums + media metadata) followed by each
   media blob, stored as LZFSE-or-raw compressed chunks.

Key derivation is `PBKDF2-HMAC-SHA256`; the per-space app keys are never written into
a backup — the backup is encrypted with a key derived from the **export password**.

## The Go `.vault` unpacker

This repo ships a standalone, cross-platform recovery tool:
**[`tools/vault-unpacker`](tools/vault-unpacker/)**.

### What it's for

- Decrypt and **extract your original photos and videos** from a `.vault` backup on
  **macOS, Linux, or Windows** — without the app, so you're never locked in.
- Inspect what a backup contains (`-l` lists items without extracting).
- Recover data even if the iOS app is unavailable, as long as you have the file and
  the export password.

```bash
cd tools/vault-unpacker
go build -o vault-unpacker .
./vault-unpacker -o ./restored "PrivyGallery Backup.vault"
```

### What it does *not* do (limitations)

- It is a **recovery / extraction** tool, not a full re-importer. It writes plain
  media files to a folder; it does **not** load them back into the iOS app, rebuild
  albums inside the app, or restore app state.
- It **requires the correct export password**. There is no recovery if the password
  is lost — the encryption is real.
- It needs a **C compiler** at build time, because LZFSE decompression uses Apple's
  reference implementation via cgo (this keeps decompression byte-exact).
- Album/metadata relationships are preserved in the manifest but are surfaced only as
  filenames + a `_Trash/` folder, not reconstructed app objects.

See [`tools/vault-unpacker/README.md`](tools/vault-unpacker/README.md) for full usage.

## Build from Source

Requirements: Xcode 26+, iOS deployment target `17.0`, SwiftUI.

```bash
# Standard build (set your own signing team in Xcode)
xcodebuild -scheme SecurityFolder -destination 'generic/platform=iOS' build

# Unsigned local verification
xcodebuild -scheme SecurityFolder -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/SecurityFolderDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

> The project ships with a blank `DEVELOPMENT_TEAM`; set your own Apple Developer team
> and bundle identifiers before building to a device.

## Project Structure

```text
SecurityFolder/
├── SecurityFolder/          # Main iOS app target (App, Core, Features, Shared)
├── Share/                   # Share extension target
├── tools/
│   └── vault-unpacker/      # Cross-platform Go .vault recovery CLI
├── Materials/
│   ├── docs/                # Documentation + landing page (index.html)
│   └── images/              # Screenshots
├── LICENSE  · SECURITY.md · PRIVACY.md
└── SecurityFolder.xcodeproj
```

## Localization

Localized for Simplified Chinese, English, Traditional Chinese variants, Japanese,
and Korean.

## Limitations

- iOS provides no fully supported public API to globally block screenshots; some
  hardening relies on platform behavior that should be tested across iOS versions.
- Large albums and imports require ongoing memory-pressure tuning.
- This repository is app-first and is not yet packaged as a reusable SDK.
- **No formal third-party security audit has been performed.** See [SECURITY.md](SECURITY.md).

## License

Licensed under the **Apache License 2.0** — see [LICENSE](LICENSE).

---

<p align="center">
  Made with care for people who value their privacy. ·
  <a href="https://apps.apple.com/us/app/privygallery-dual-space-vault/id6765981187">Download on the App Store</a>
</p>
