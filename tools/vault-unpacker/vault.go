package main

import (
	"bufio"
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"

	lzfse "github.com/blacktop/lzfse-cgo"
)

// The .vault format is documented in ../../docs/vault-format.md. The constants
// and binary layout below mirror exactly what the iOS/macOS app writes in
// VaultExportService.swift. Anything that diverges from that file is a bug.

const (
	vaultMagic   = "SVEX"
	vaultVersion = 2

	archiveMagic   = "SVAR"
	archiveVersion = 1

	domainMedia              = 1
	domainLivePhotoCompanion = 2
	domainAlbumCover         = 3

	codecRaw   = 0
	codecLZFSE = 1

	maxHeaderBytes     = 2 << 20
	maxCiphertextBytes = 64 << 20
	maxManifestBytes   = 64 << 20
	maxPathBytes       = 4096
	maxPlaintextChunk  = 16 << 20
	minKDFRounds       = 10_000
	maxKDFRounds       = 5_000_000
	minSaltBytes       = 16
	maxSaltBytes       = 64
)

// ErrWrongPassword is returned when AES-GCM authentication fails, which almost
// always means the supplied password is wrong (or the file is corrupted).
var ErrWrongPassword = errors.New("incorrect password or corrupted backup file")

// vaultHeader is the cleartext JSON header at the front of every .vault file.
type vaultHeader struct {
	ExportedAt       string `json:"exportedAt"`
	AppName          string `json:"appName"`
	FormatVersion    int    `json:"formatVersion"`
	PartIndex        int    `json:"partIndex"`
	TotalParts       int    `json:"totalParts"`
	ArchiveEncoding  string `json:"archiveEncoding"`
	Cipher           string `json:"cipher"`
	ChunkSize        int    `json:"chunkSize"`
	ArchiveByteCount int64  `json:"archiveByteCount"`
	KDF              struct {
		Algorithm  string `json:"algorithm"`
		Rounds     int    `json:"rounds"`
		SaltBase64 string `json:"saltBase64"`
	} `json:"kdf"`
}

// manifest is the JSON index stored (encrypted) inside the SVAR archive.
type manifest struct {
	ExportedAt    string          `json:"exportedAt"`
	SpaceRawValue string          `json:"spaceRawValue"`
	PartIndex     int             `json:"partIndex"`
	TotalParts    int             `json:"totalParts"`
	Albums        []manifestAlbum `json:"albums"`
	Items         []manifestItem  `json:"items"`
	BlobEntries   []blobEntry     `json:"blobEntries"`
}

type manifestItem struct {
	Name              string `json:"name"`
	RelativePath      string `json:"relativePath"`
	OriginalFilename  string `json:"originalFilename"`
	MediaKindRawValue string `json:"mediaKindRawValue"`
	IsInTrash         bool   `json:"isInTrash"`
	// Set for Live Photos; points at a domainLivePhotoCompanion blob.
	LivePhotoCompanionRelativePath string `json:"livePhotoCompanionRelativePath"`
}

type manifestAlbum struct {
	Name                   string `json:"name"`
	CoverImageRelativePath string `json:"coverImageRelativePath"`
}

type blobEntry struct {
	RelativePath string `json:"relativePath"`
	SourceDomain uint8  `json:"sourceDomain"`
	ByteCount    int64  `json:"byteCount"`
}

// reader is a small big-endian binary reader over a buffered stream.
type reader struct {
	r *bufio.Reader
}

func newReader(r io.Reader) *reader {
	return &reader{r: bufio.NewReaderSize(r, 1<<20)}
}

func (rd *reader) full(n int) ([]byte, error) {
	if n < 0 {
		return nil, fmt.Errorf("negative length %d", n)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(rd.r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

func (rd *reader) u8() (uint8, error) {
	b, err := rd.full(1)
	if err != nil {
		return 0, err
	}
	return b[0], nil
}

func (rd *reader) u32() (uint32, error) {
	b, err := rd.full(4)
	if err != nil {
		return 0, err
	}
	return binary.BigEndian.Uint32(b), nil
}

func (rd *reader) u64() (uint64, error) {
	b, err := rd.full(8)
	if err != nil {
		return 0, err
	}
	return binary.BigEndian.Uint64(b), nil
}

// decryptVaultToArchive reads a .vault file, derives the key from the password,
// AES-GCM-decrypts every chunk and writes the reconstructed SVAR archive to
// archivePath. It returns the parsed header. A wrong password surfaces as
// ErrWrongPassword.
func decryptVaultToArchive(vaultPath, password, archivePath string) (*vaultHeader, error) {
	in, err := os.Open(vaultPath)
	if err != nil {
		return nil, err
	}
	defer in.Close()

	rd := newReader(in)

	magic, err := rd.full(len(vaultMagic))
	if err != nil {
		return nil, fmt.Errorf("read magic: %w", err)
	}
	if string(magic) != vaultMagic {
		return nil, fmt.Errorf("not a .vault file (bad magic %q)", magic)
	}
	version, err := rd.u8()
	if err != nil {
		return nil, err
	}
	if version != vaultVersion {
		return nil, fmt.Errorf("unsupported .vault version %d (this tool handles version %d)", version, vaultVersion)
	}

	headerLen, err := rd.u32()
	if err != nil {
		return nil, err
	}
	if headerLen == 0 || headerLen > maxHeaderBytes {
		return nil, fmt.Errorf("invalid header length %d", headerLen)
	}
	headerBytes, err := rd.full(int(headerLen))
	if err != nil {
		return nil, fmt.Errorf("read header: %w", err)
	}
	var header vaultHeader
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return nil, fmt.Errorf("decode header JSON: %w", err)
	}

	// Format 3 only adds blob domains (Live Photo videos, album covers).
	if (header.FormatVersion != 2 && header.FormatVersion != 3) ||
		header.ArchiveEncoding != "chunked-lzfse-v1" ||
		header.Cipher != "aes-gcm-chunked-archive" {
		return nil, fmt.Errorf("unsupported backup format (version=%d encoding=%q cipher=%q)",
			header.FormatVersion, header.ArchiveEncoding, header.Cipher)
	}
	if header.ArchiveByteCount < 0 {
		return nil, fmt.Errorf("invalid archiveByteCount %d", header.ArchiveByteCount)
	}
	if header.KDF.Algorithm != "pbkdf2-sha256" {
		return nil, fmt.Errorf("unsupported key derivation %q", header.KDF.Algorithm)
	}
	if header.KDF.Rounds < minKDFRounds || header.KDF.Rounds > maxKDFRounds {
		return nil, fmt.Errorf("unsupported KDF rounds %d", header.KDF.Rounds)
	}

	salt, err := base64.StdEncoding.DecodeString(header.KDF.SaltBase64)
	if err != nil {
		return nil, fmt.Errorf("decode salt: %w", err)
	}
	if len(salt) < minSaltBytes || len(salt) > maxSaltBytes {
		return nil, fmt.Errorf("invalid KDF salt length %d", len(salt))
	}
	key, err := pbkdf2.Key(sha256.New, password, salt, header.KDF.Rounds, 32)
	if err != nil {
		return nil, fmt.Errorf("derive key: %w", err)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	out, err := os.OpenFile(archivePath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return nil, err
	}
	defer out.Close()
	bw := bufio.NewWriterSize(out, 1<<20)

	var written int64
	expectedChunk := uint32(0)
	for {
		chunkIndex, err := rd.u32()
		if err == io.EOF {
			break // clean end of chunk stream
		}
		if err != nil {
			return nil, err
		}
		if chunkIndex != expectedChunk {
			return nil, fmt.Errorf("chunk out of order: got %d want %d", chunkIndex, expectedChunk)
		}
		plaintextLen, err := rd.u64()
		if err != nil {
			return nil, err
		}
		if plaintextLen > maxCiphertextBytes {
			return nil, fmt.Errorf("chunk %d: plaintext length %d exceeds limit", chunkIndex, plaintextLen)
		}
		ciphertextLen, err := rd.u64()
		if err != nil {
			return nil, err
		}
		if ciphertextLen > maxCiphertextBytes {
			return nil, fmt.Errorf("chunk %d: ciphertext length %d exceeds limit", chunkIndex, ciphertextLen)
		}
		nonceLen, err := rd.u32()
		if err != nil {
			return nil, err
		}
		if int(nonceLen) != gcm.NonceSize() {
			return nil, fmt.Errorf("chunk %d: invalid nonce length %d", chunkIndex, nonceLen)
		}
		nonce, err := rd.full(int(nonceLen))
		if err != nil {
			return nil, err
		}
		tagLen, err := rd.u32()
		if err != nil {
			return nil, err
		}
		if int(tagLen) != gcm.Overhead() {
			return nil, fmt.Errorf("chunk %d: invalid tag length %d", chunkIndex, tagLen)
		}
		tag, err := rd.full(int(tagLen))
		if err != nil {
			return nil, err
		}
		ciphertext, err := rd.full(int(ciphertextLen))
		if err != nil {
			return nil, err
		}

		// Go's GCM wants the tag appended to the ciphertext.
		sealed := append(ciphertext, tag...)
		aad := []byte(fmt.Sprintf("SVEX-v2|%d|%d|%d|%d",
			header.PartIndex, header.TotalParts, int(chunkIndex), header.ArchiveByteCount))

		plaintext, err := gcm.Open(nil, nonce, sealed, aad)
		if err != nil {
			return nil, ErrWrongPassword
		}
		if uint64(len(plaintext)) != plaintextLen {
			return nil, fmt.Errorf("chunk %d: decrypted length %d != declared %d", chunkIndex, len(plaintext), plaintextLen)
		}
		if written+int64(len(plaintext)) > header.ArchiveByteCount {
			return nil, fmt.Errorf("archive exceeds declared byte count %d", header.ArchiveByteCount)
		}
		if _, err := bw.Write(plaintext); err != nil {
			return nil, err
		}
		written += int64(len(plaintext))
		expectedChunk++
	}

	if err := bw.Flush(); err != nil {
		return nil, err
	}
	if written != header.ArchiveByteCount {
		return nil, fmt.Errorf("archive truncated: wrote %d bytes, header expected %d", written, header.ArchiveByteCount)
	}
	return &header, nil
}

// extractedFile records one media file written to disk.
type extractedFile struct {
	Path      string
	ByteCount int64
	InTrash   bool
}

// extractArchive parses a decrypted SVAR archive, reconstructs each media blob
// (decompressing LZFSE chunks as needed) and writes the files into outDir.
// When listOnly is true it parses the manifest and blob headers but writes
// nothing. namer maps a blob to its on-disk destination path.
func extractArchive(archivePath, outDir string, listOnly bool, naming *namer) ([]extractedFile, *manifest, error) {
	f, err := os.Open(archivePath)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()
	rd := newReader(f)

	magic, err := rd.full(len(archiveMagic))
	if err != nil {
		return nil, nil, err
	}
	if string(magic) != archiveMagic {
		return nil, nil, fmt.Errorf("internal archive corrupted (bad magic %q)", magic)
	}
	version, err := rd.u8()
	if err != nil {
		return nil, nil, err
	}
	if version != archiveVersion {
		return nil, nil, fmt.Errorf("unsupported archive version %d", version)
	}

	manifestLen, err := rd.u64()
	if err != nil {
		return nil, nil, err
	}
	if manifestLen == 0 || manifestLen > maxManifestBytes {
		return nil, nil, fmt.Errorf("invalid manifest length %d", manifestLen)
	}
	manifestBytes, err := rd.full(int(manifestLen))
	if err != nil {
		return nil, nil, err
	}
	var man manifest
	if err := json.Unmarshal(manifestBytes, &man); err != nil {
		return nil, nil, fmt.Errorf("decode manifest: %w", err)
	}

	// Map each blob path to its richer item record for friendly filenames.
	itemByPath := make(map[string]manifestItem, len(man.Items))
	itemByCompanionPath := make(map[string]manifestItem)
	for _, it := range man.Items {
		itemByPath[it.RelativePath] = it
		if it.LivePhotoCompanionRelativePath != "" {
			itemByCompanionPath[it.LivePhotoCompanionRelativePath] = it
		}
	}
	albumByCoverPath := make(map[string]manifestAlbum)
	for _, album := range man.Albums {
		if album.CoverImageRelativePath != "" {
			albumByCoverPath[album.CoverImageRelativePath] = album
		}
	}
	destByItemPath := make(map[string]string, len(man.Items))

	blobCount, err := rd.u32()
	if err != nil {
		return nil, nil, err
	}
	if int(blobCount) != len(man.BlobEntries) {
		return nil, nil, fmt.Errorf("blob count %d does not match manifest entries %d", blobCount, len(man.BlobEntries))
	}

	if naming == nil {
		naming = newNamer(outDir)
	}

	var root *os.Root
	if !listOnly {
		if err := os.MkdirAll(outDir, 0o700); err != nil {
			return nil, nil, err
		}
		root, err = os.OpenRoot(outDir)
		if err != nil {
			return nil, nil, err
		}
		defer root.Close()
	}

	var results []extractedFile

	for i := uint32(0); i < blobCount; i++ {
		pathLen, err := rd.u32()
		if err != nil {
			return nil, nil, err
		}
		if pathLen > maxPathBytes {
			return nil, nil, fmt.Errorf("blob path length %d exceeds limit", pathLen)
		}
		pathBytes, err := rd.full(int(pathLen))
		if err != nil {
			return nil, nil, err
		}
		relativePath := string(pathBytes)

		domain, err := rd.u8()
		if err != nil {
			return nil, nil, err
		}
		expectedBytesU, err := rd.u64()
		if err != nil {
			return nil, nil, err
		}
		if expectedBytesU > math.MaxInt64 {
			return nil, nil, fmt.Errorf("blob %q byte count %d overflows int64", relativePath, expectedBytesU)
		}
		expectedBytes := int64(expectedBytesU)
		var dest string
		var inTrash bool
		switch domain {
		case domainMedia:
			dest, inTrash = naming.destination(itemByPath[relativePath])
		case domainLivePhotoCompanion:
			item := itemByCompanionPath[relativePath]
			dest, inTrash = naming.companionDestination(item, destByItemPath[item.RelativePath], relativePath)
		case domainAlbumCover:
			dest = naming.coverDestination(albumByCoverPath[relativePath], relativePath)
		default:
			return nil, nil, fmt.Errorf("unsupported blob domain %d for %q", domain, relativePath)
		}

		var w *bufio.Writer
		var out *os.File
		var relDest string
		if !listOnly {
			out, dest, relDest, err = openUniqueFileInRoot(root, outDir, naming, dest)
			if err != nil {
				return nil, nil, err
			}
			w = bufio.NewWriterSize(out, 1<<20)
		}
		if domain == domainMedia {
			destByItemPath[relativePath] = dest
		}

		if err := readBlobChunks(rd, expectedBytes, w); err != nil {
			if out != nil {
				out.Close()
				root.Remove(relDest)
			}
			return nil, nil, fmt.Errorf("%s: %w", relativePath, err)
		}

		if !listOnly {
			if err := w.Flush(); err != nil {
				out.Close()
				root.Remove(relDest)
				return nil, nil, err
			}
			if err := out.Close(); err != nil {
				return nil, nil, err
			}
		}
		results = append(results, extractedFile{Path: dest, ByteCount: expectedBytes, InTrash: inTrash})
	}

	return results, &man, nil
}

// openUniqueFileInRoot creates a new file inside root without following symlinks
// or overwriting existing files. When a regular file already exists on disk, it
// advances the namer suffix (" (2)", " (3)", ...) until an exclusive create succeeds.
func openUniqueFileInRoot(root *os.Root, outDir string, naming *namer, initialDest string) (*os.File, string, string, error) {
	candidate := initialDest
	for {
		rel, err := filepath.Rel(outDir, candidate)
		if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
			return nil, "", "", fmt.Errorf("refusing to write outside output directory: %q", candidate)
		}

		subDir := filepath.Dir(rel)
		if subDir != "." {
			if info, lerr := root.Lstat(subDir); lerr == nil && info.Mode()&os.ModeSymlink != 0 {
				return nil, "", "", fmt.Errorf("refusing to follow symlink directory %q", subDir)
			}
			if err := root.MkdirAll(subDir, 0o700); err != nil {
				return nil, "", "", err
			}
		}

		if info, lerr := root.Lstat(rel); lerr == nil && info.Mode()&os.ModeSymlink != 0 {
			return nil, "", "", fmt.Errorf("refusing to follow symlink %q", rel)
		}

		f, err := root.OpenFile(rel, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err == nil {
			return f, candidate, rel, nil
		}
		if errors.Is(err, os.ErrExist) {
			candidate = naming.claim(initialDest)
			continue
		}
		return nil, "", "", err
	}
}

// readBlobChunks consumes codec-prefixed chunks until expectedBytes of plaintext
// have been produced, writing the plaintext to w (or discarding it when w is nil
// for list-only mode).
func readBlobChunks(rd *reader, expectedBytes int64, w io.Writer) error {
	var remaining = expectedBytes
	for remaining > 0 {
		codec, err := rd.u8()
		if err != nil {
			return err
		}
		plaintextLen, err := rd.u32()
		if err != nil {
			return err
		}
		if plaintextLen == 0 || plaintextLen > maxPlaintextChunk || int64(plaintextLen) > remaining {
			return fmt.Errorf("invalid chunk plaintext length %d (remaining %d)", plaintextLen, remaining)
		}
		payloadLen, err := rd.u32()
		if err != nil {
			return err
		}
		if payloadLen == 0 || payloadLen > maxPlaintextChunk {
			return fmt.Errorf("invalid chunk payload length %d", payloadLen)
		}
		payload, err := rd.full(int(payloadLen))
		if err != nil {
			return err
		}

		var chunk []byte
		switch codec {
		case codecRaw:
			if int(plaintextLen) != len(payload) {
				return fmt.Errorf("raw chunk length mismatch: %d != %d", plaintextLen, len(payload))
			}
			chunk = payload
		case codecLZFSE:
			buf := make([]byte, int(plaintextLen)+1)
			n := lzfse.DecodeBufferInto(payload, buf)
			if n != int(plaintextLen) {
				return fmt.Errorf("LZFSE decode produced %d bytes, expected %d", n, plaintextLen)
			}
			chunk = buf[:plaintextLen]
		default:
			return fmt.Errorf("unknown chunk codec %d", codec)
		}

		if w != nil {
			if _, err := w.Write(chunk); err != nil {
				return err
			}
		}
		remaining -= int64(len(chunk))
	}
	if remaining != 0 {
		return fmt.Errorf("blob overran expected size by %d bytes", -remaining)
	}
	return nil
}
