# vault-unpacker

**English** · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md)

A small, cross-platform command-line tool that decrypts and extracts
PrivyGallery `.vault` backup files **without the app**. Point it at a backup
file (or a folder full of them), give it the backup password, and it writes your
original photos and videos back out as plain files.

It runs anywhere Go runs: macOS, Linux, and Windows.

## What it does

- Reads the `.vault` container, derives the key from your password
  (PBKDF2-HMAC-SHA256), and AES-GCM-decrypts every chunk.
- Rebuilds the inner archive, decompresses each media chunk (LZFSE or raw), and
  writes each item out under its original filename.
- Handles **multi-part backups** and **multiple files at once** — every `.vault`
  is independent and is unpacked in turn.
- Never modifies the input `.vault` files.

## Install / build

You need [Go](https://go.dev/dl/) 1.24+ and a C compiler (the LZFSE
decompressor is Apple's reference implementation, used through cgo):

- **macOS:** `xcode-select --install` (provides clang)
- **Linux:** `gcc` (e.g. `sudo apt install build-essential`)
- **Windows:** a mingw-w64 / gcc toolchain, then build with `CGO_ENABLED=1`

```bash
cd tools/vault-unpacker
go build -o vault-unpacker .
```

This produces a single `vault-unpacker` binary you can copy anywhere.

## Usage

```
vault-unpacker [options] <file-or-directory>...

Options:
  -o string   output directory for extracted media (default "vault-unpacked")
  -p string   backup password (omit to be prompted securely)
  -l          list contents only; do not extract anything
```

If you don't pass `-p`, you'll be prompted for the password (input is hidden).
The password can also be supplied via the `VAULT_PASSWORD` environment variable.

### Examples

Unpack one backup into `./vault-unpacked`:

```bash
vault-unpacker "PrivyGallery Backup.vault"
```

Unpack a multi-part backup (or a whole folder of `.vault` files) into a chosen
directory:

```bash
vault-unpacker -o ./restored ~/Backups
```

Just see what's inside without extracting:

```bash
vault-unpacker -l "PrivyGallery Backup.vault"
```

## Output layout

Extracted media is written into the output directory using each item's original
filename. Files that were in the app's trash at export time go into a `_Trash/`
subfolder. Name collisions get a ` (2)`, ` (3)`, … suffix so nothing is
overwritten.

## How it works

The `.vault` format is a password-encrypted container:

1. A cleartext JSON header (`SVEX`, version 2) declares the KDF, salt, cipher,
   chunk size, and the part index for multi-part backups.
2. The body is the inner archive (`SVAR`), split into chunks and sealed
   independently with AES-GCM. Each chunk's authenticated data binds it to the
   format version, part number, chunk index, and archive length.
3. The inner archive holds a JSON manifest (albums + media metadata) followed by
   each media blob, stored as a sequence of LZFSE-or-raw compressed chunks.

The tool reverses exactly this pipeline. The authoritative byte-level layout
lives in the source — see [`vault.go`](vault.go), whose constants and reader
mirror the app's `VaultExportService`. (Note: the older `docs/vault-format.md`
describes the legacy v1 container and does not match the current v2 format.)

## Tests

```bash
go test ./...
```

The tests synthesize a `.vault` file byte-for-byte the way the app's exporter
does — including a real LZFSE-compressed chunk — and assert that unpacking
reproduces the original media exactly, and that a wrong password fails cleanly.
