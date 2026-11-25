package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	lzfse "github.com/blacktop/lzfse-cgo"
)

// These tests synthesize a .vault file byte-for-byte the way the Swift
// VaultExportService does, then confirm the unpacker reconstructs the exact
// original media. This is the real correctness guarantee for the format,
// including the LZFSE compression path.

func be32(v uint32) []byte { b := make([]byte, 4); binary.BigEndian.PutUint32(b, v); return b }
func be64(v uint64) []byte { b := make([]byte, 8); binary.BigEndian.PutUint64(b, v); return b }

// buildInnerArchive mirrors writePlainArchive: SVAR header + manifest + blobs,
// chunking each media payload and compressing chunks with LZFSE when it helps.
func buildInnerArchive(t *testing.T, man manifest, media map[string][]byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	buf.WriteString(archiveMagic)
	buf.WriteByte(archiveVersion)

	manBytes, err := json.Marshal(man)
	if err != nil {
		t.Fatal(err)
	}
	buf.Write(be64(uint64(len(manBytes))))
	buf.Write(manBytes)
	buf.Write(be32(uint32(len(man.BlobEntries))))

	const mediaChunk = 64 * 1024
	for _, blob := range man.BlobEntries {
		payload := media[blob.RelativePath]
		buf.Write(be32(uint32(len(blob.RelativePath))))
		buf.WriteString(blob.RelativePath)
		domain := blob.SourceDomain
		if domain == 0 {
			domain = domainMedia
		}
		buf.WriteByte(domain)
		buf.Write(be64(uint64(len(payload))))

		for off := 0; off < len(payload); off += mediaChunk {
			end := min(off+mediaChunk, len(payload))
			chunk := payload[off:end]
			compressed := lzfse.EncodeBuffer(chunk)
			if len(compressed) > 0 && len(compressed) < len(chunk) {
				buf.WriteByte(codecLZFSE)
				buf.Write(be32(uint32(len(chunk))))
				buf.Write(be32(uint32(len(compressed))))
				buf.Write(compressed)
			} else {
				buf.WriteByte(codecRaw)
				buf.Write(be32(uint32(len(chunk))))
				buf.Write(be32(uint32(len(chunk))))
				buf.Write(chunk)
			}
		}
	}
	return buf.Bytes()
}

// buildVault mirrors encryptArchive: SVEX header + chunked AES-GCM of the inner
// archive, using the same KDF, nonce/tag layout and AAD.
func buildVault(t *testing.T, password string, formatVersion, partIndex, totalParts int, archive []byte) []byte {
	t.Helper()
	salt := make([]byte, 32)
	rand.Read(salt)
	rounds := 600000
	key, err := pbkdf2.Key(sha256.New, password, salt, rounds, 32)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := aes.NewCipher(key)
	gcm, _ := cipher.NewGCM(block)

	const vaultChunk = 4096 // small, to exercise multiple outer chunks
	header := vaultHeader{
		AppName:          "PrivyGallery",
		FormatVersion:    formatVersion,
		PartIndex:        partIndex,
		TotalParts:       totalParts,
		ArchiveEncoding:  "chunked-lzfse-v1",
		Cipher:           "aes-gcm-chunked-archive",
		ChunkSize:        vaultChunk,
		ArchiveByteCount: int64(len(archive)),
	}
	header.KDF.Algorithm = "pbkdf2-sha256"
	header.KDF.Rounds = rounds
	header.KDF.SaltBase64 = base64.StdEncoding.EncodeToString(salt)
	headerBytes, _ := json.Marshal(header)

	var buf bytes.Buffer
	buf.WriteString(vaultMagic)
	buf.WriteByte(vaultVersion)
	buf.Write(be32(uint32(len(headerBytes))))
	buf.Write(headerBytes)

	chunkIndex := 0
	for off := 0; off < len(archive); off += vaultChunk {
		end := min(off+vaultChunk, len(archive))
		plain := archive[off:end]
		nonce := make([]byte, 12)
		rand.Read(nonce)
		aad := []byte(sprintfAAD(partIndex, totalParts, chunkIndex, int64(len(archive))))
		sealed := gcm.Seal(nil, nonce, plain, aad)
		ciphertext := sealed[:len(sealed)-16]
		tag := sealed[len(sealed)-16:]

		buf.Write(be32(uint32(chunkIndex)))
		buf.Write(be64(uint64(len(plain))))
		buf.Write(be64(uint64(len(ciphertext))))
		buf.Write(be32(uint32(len(nonce))))
		buf.Write(nonce)
		buf.Write(be32(uint32(len(tag))))
		buf.Write(tag)
		buf.Write(ciphertext)
		chunkIndex++
	}
	return buf.Bytes()
}

func sprintfAAD(partIndex, totalParts, chunkIndex int, archiveByteCount int64) string {
	return "SVEX-v2|" +
		itoa(partIndex) + "|" + itoa(totalParts) + "|" + itoa(chunkIndex) + "|" + itoa64(archiveByteCount)
}

func itoa(v int) string { return itoa64(int64(v)) }
func itoa64(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	var b [20]byte
	i := len(b)
	for v > 0 {
		i--
		b[i] = byte('0' + v%10)
		v /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

func TestUnpackRoundTrip(t *testing.T) {
	password := "correct horse battery staple"

	// Compressible media (forces the LZFSE path) and incompressible media
	// (forces the raw path), each larger than one media chunk.
	zeros := make([]byte, 200*1024)
	random := make([]byte, 150*1024)
	rand.Read(random)

	man := manifest{
		SpaceRawValue: "spaceA",
		PartIndex:     0,
		TotalParts:    1,
		Items: []manifestItem{
			{Name: "Zeros", RelativePath: "VaultStorage/Space_A/Active/a.bin", OriginalFilename: "photo.png", MediaKindRawValue: "photo", IsInTrash: false},
			{Name: "Random", RelativePath: "VaultStorage/Space_A/Trash/b.bin", OriginalFilename: "clip.mp4", MediaKindRawValue: "video", IsInTrash: true},
		},
		BlobEntries: []blobEntry{
			{RelativePath: "VaultStorage/Space_A/Active/a.bin", ByteCount: int64(len(zeros))},
			{RelativePath: "VaultStorage/Space_A/Trash/b.bin", ByteCount: int64(len(random))},
		},
	}
	media := map[string][]byte{
		"VaultStorage/Space_A/Active/a.bin": zeros,
		"VaultStorage/Space_A/Trash/b.bin":  random,
	}

	archive := buildInnerArchive(t, man, media)
	vaultBytes := buildVault(t, password, 2, 0, 1, archive)

	dir := t.TempDir()
	vaultPath := filepath.Join(dir, "test.vault")
	if err := os.WriteFile(vaultPath, vaultBytes, 0o644); err != nil {
		t.Fatal(err)
	}

	outDir := filepath.Join(dir, "out")
	extracted, _, err := unpackOne(vaultPath, password, outDir, false, nil)
	if err != nil {
		t.Fatalf("unpack failed: %v", err)
	}
	if extracted != 2 {
		t.Fatalf("expected 2 extracted files, got %d", extracted)
	}

	gotZeros, err := os.ReadFile(filepath.Join(outDir, "photo.png"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(gotZeros, zeros) {
		t.Fatalf("LZFSE-path file mismatch: got %d bytes", len(gotZeros))
	}

	gotRandom, err := os.ReadFile(filepath.Join(outDir, "_Trash", "clip.mp4"))
	if err != nil {
		t.Fatalf("trashed file not in _Trash: %v", err)
	}
	if !bytes.Equal(gotRandom, random) {
		t.Fatalf("raw-path file mismatch: got %d bytes", len(gotRandom))
	}
}

func TestWrongPassword(t *testing.T) {
	password := "right"
	media := map[string][]byte{"VaultStorage/x": []byte("hello world payload")}
	man := manifest{
		SpaceRawValue: "spaceA", TotalParts: 1,
		Items:       []manifestItem{{RelativePath: "VaultStorage/x", OriginalFilename: "f.bin"}},
		BlobEntries: []blobEntry{{RelativePath: "VaultStorage/x", ByteCount: int64(len(media["VaultStorage/x"]))}},
	}
	archive := buildInnerArchive(t, man, media)
	vaultBytes := buildVault(t, password, 2, 0, 1, archive)

	dir := t.TempDir()
	vaultPath := filepath.Join(dir, "t.vault")
	os.WriteFile(vaultPath, vaultBytes, 0o644)

	_, _, err := unpackOne(vaultPath, "wrong", filepath.Join(dir, "out"), false, nil)
	if err == nil {
		t.Fatal("expected error with wrong password")
	}
}

func TestUnpackLivePhotoAndAlbumCover(t *testing.T) {
	password := "pw"
	still := []byte("still image bytes")
	video := []byte("paired video bytes")
	cover := []byte("cover jpeg bytes")

	man := manifest{
		SpaceRawValue: "spaceA",
		TotalParts:    1,
		Albums: []manifestAlbum{
			{Name: "Trip", CoverImageRelativePath: "VaultStorage/Space_A/AlbumCovers/c.jpg"},
		},
		Items: []manifestItem{{
			RelativePath:                   "VaultStorage/Space_A/Active/s.heic",
			OriginalFilename:               "IMG_0001.HEIC",
			MediaKindRawValue:              "livePhoto",
			LivePhotoCompanionRelativePath: "VaultStorage/Space_A/Active/v.MOV",
		}},
		BlobEntries: []blobEntry{
			{RelativePath: "VaultStorage/Space_A/Active/s.heic", SourceDomain: domainMedia, ByteCount: int64(len(still))},
			{RelativePath: "VaultStorage/Space_A/Active/v.MOV", SourceDomain: domainLivePhotoCompanion, ByteCount: int64(len(video))},
			{RelativePath: "VaultStorage/Space_A/AlbumCovers/c.jpg", SourceDomain: domainAlbumCover, ByteCount: int64(len(cover))},
		},
	}
	media := map[string][]byte{
		"VaultStorage/Space_A/Active/s.heic":     still,
		"VaultStorage/Space_A/Active/v.MOV":      video,
		"VaultStorage/Space_A/AlbumCovers/c.jpg": cover,
	}

	dir := t.TempDir()
	vaultPath := filepath.Join(dir, "live.vault")
	archive := buildInnerArchive(t, man, media)
	if err := os.WriteFile(vaultPath, buildVault(t, password, 3, 0, 1, archive), 0o644); err != nil {
		t.Fatal(err)
	}

	outDir := filepath.Join(dir, "out")
	extracted, _, err := unpackOne(vaultPath, password, outDir, false, nil)
	if err != nil {
		t.Fatalf("unpack failed: %v", err)
	}
	if extracted != 3 {
		t.Fatalf("expected 3 extracted files, got %d", extracted)
	}

	for path, want := range map[string][]byte{
		filepath.Join(outDir, "IMG_0001.HEIC"):            still,
		filepath.Join(outDir, "IMG_0001.MOV"):             video,
		filepath.Join(outDir, "_AlbumCovers", "Trip.jpg"): cover,
	} {
		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("missing %s: %v", path, err)
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("%s content mismatch", path)
		}
	}
}

func TestMalformedHeaderAndNonceRejectedWithoutPanic(t *testing.T) {
	dir := t.TempDir()

	// 1. Oversized header length must fail cleanly instead of allocating gigabytes.
	var badHeader bytes.Buffer
	badHeader.WriteString(vaultMagic)
	badHeader.WriteByte(vaultVersion)
	badHeader.Write(be32(maxHeaderBytes + 1))
	badHeaderPath := filepath.Join(dir, "bad-header.vault")
	if err := os.WriteFile(badHeaderPath, badHeader.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := unpackOne(badHeaderPath, "pw", filepath.Join(dir, "out1"), false, nil); err == nil {
		t.Fatal("expected error for oversized headerLen")
	}

	// 2. Non-12-byte GCM nonce must return an error instead of panicking in gcm.Open.
	salt := make([]byte, 32)
	rand.Read(salt)
	header := vaultHeader{
		AppName:          "PrivyGallery",
		FormatVersion:    2,
		PartIndex:        0,
		TotalParts:       1,
		ArchiveEncoding:  "chunked-lzfse-v1",
		Cipher:           "aes-gcm-chunked-archive",
		ChunkSize:        4096,
		ArchiveByteCount: 16,
	}
	header.KDF.Algorithm = "pbkdf2-sha256"
	header.KDF.Rounds = minKDFRounds
	header.KDF.SaltBase64 = base64.StdEncoding.EncodeToString(salt)
	headerBytes, _ := json.Marshal(header)

	var badNonce bytes.Buffer
	badNonce.WriteString(vaultMagic)
	badNonce.WriteByte(vaultVersion)
	badNonce.Write(be32(uint32(len(headerBytes))))
	badNonce.Write(headerBytes)
	badNonce.Write(be32(0))    // chunkIndex
	badNonce.Write(be64(16))   // plaintextLen
	badNonce.Write(be64(16))   // ciphertextLen
	badNonce.Write(be32(1))    // invalid nonceLen != 12
	badNonce.Write([]byte{0})  // 1-byte nonce
	badNonce.Write(be32(16))   // tagLen
	badNonce.Write(make([]byte, 16))
	badNonce.Write(make([]byte, 16))

	badNoncePath := filepath.Join(dir, "bad-nonce.vault")
	if err := os.WriteFile(badNoncePath, badNonce.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := unpackOne(badNoncePath, "pw", filepath.Join(dir, "out2"), false, nil); err == nil {
		t.Fatal("expected error for invalid GCM nonce length")
	}
}

func TestMultiPartCollisionAndSymlinkProtection(t *testing.T) {
	password := "pw"
	dir := t.TempDir()
	outDir := filepath.Join(dir, "out")

	makePart := func(name string, payload []byte) string {
		man := manifest{
			SpaceRawValue: "spaceA",
			TotalParts:    2,
			Items:         []manifestItem{{RelativePath: "VaultStorage/Space_A/Active/a.jpg", OriginalFilename: "same.jpg"}},
			BlobEntries:   []blobEntry{{RelativePath: "VaultStorage/Space_A/Active/a.jpg", SourceDomain: domainMedia, ByteCount: int64(len(payload))}},
		}
		archive := buildInnerArchive(t, man, map[string][]byte{"VaultStorage/Space_A/Active/a.jpg": payload})
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, buildVault(t, password, 2, 0, 2, archive), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}

	p1 := makePart("part1.vault", []byte("first-part-content"))
	p2 := makePart("part2.vault", []byte("second-part-content"))

	// Pre-populate same.jpg on disk to verify on-disk O_EXCL collision avoidance too.
	if err := os.MkdirAll(outDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outDir, "same.jpg"), []byte("preexisting"), 0o600); err != nil {
		t.Fatal(err)
	}

	naming := newNamer(outDir)
	if _, _, err := unpackOne(p1, password, outDir, false, naming); err != nil {
		t.Fatalf("part1 failed: %v", err)
	}
	if _, _, err := unpackOne(p2, password, outDir, false, naming); err != nil {
		t.Fatalf("part2 failed: %v", err)
	}

	for path, want := range map[string]string{
		filepath.Join(outDir, "same.jpg"):     "preexisting",
		filepath.Join(outDir, "same (2).jpg"): "first-part-content",
		filepath.Join(outDir, "same (3).jpg"): "second-part-content",
	} {
		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("missing %s: %v", path, err)
		}
		if string(got) != want {
			t.Fatalf("%s = %q, want %q", path, got, want)
		}
	}

	// Symlink at target path must be refused rather than followed.
	symOut := filepath.Join(dir, "symout")
	if err := os.MkdirAll(symOut, 0o700); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(dir, "outside.txt")
	if err := os.WriteFile(outside, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(symOut, "same.jpg")); err != nil {
		t.Fatal(err)
	}
	if _, _, err := unpackOne(p1, password, symOut, false, nil); err == nil {
		t.Fatal("expected symlink target to be rejected")
	}
	if got, _ := os.ReadFile(outside); string(got) != "keep" {
		t.Fatalf("outside file was modified through symlink: %q", got)
	}
}

func TestSanitizeExtBlocksAlternateDataStreams(t *testing.T) {
	n := newNamer("/tmp/out")
	got := n.coverDestination(manifestAlbum{Name: "Album"}, "VaultStorage/Space_A/AlbumCovers/c.jpg:evil")
	if filepath.Base(got) != "Album.jpg_evil" {
		t.Fatalf("unexpected sanitized cover destination: %q", got)
	}
}
