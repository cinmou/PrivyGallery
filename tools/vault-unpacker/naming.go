package main

import (
	"fmt"
	"path/filepath"
	"strings"
)

// namer turns manifest item records into collision-free destination paths under
// a single output directory. Trashed items go into a "_Trash" subfolder so they
// don't mix with active media.
type namer struct {
	outDir string
	used   map[string]bool
}

func newNamer(outDir string) *namer {
	return &namer{outDir: outDir, used: make(map[string]bool)}
}

func parentDir(p string) string { return filepath.Dir(p) }

// destination returns a unique absolute path for the item and whether it was a
// trashed item.
func (n *namer) destination(item manifestItem) (string, bool) {
	base := strings.TrimSpace(item.OriginalFilename)
	if base == "" {
		base = strings.TrimSpace(item.Name)
	}
	base = sanitize(base)
	if base == "" {
		base = "media"
	}

	dir := n.outDir
	if item.IsInTrash {
		dir = filepath.Join(n.outDir, "_Trash")
	}

	return n.claim(filepath.Join(dir, base)), item.IsInTrash
}

// companionDestination places a Live Photo's paired video next to its still
// image with the same base name (IMG_0001.HEIC + IMG_0001.MOV).
func (n *namer) companionDestination(item manifestItem, stillDest, companionPath string) (string, bool) {
	ext := sanitizeExt(companionPath, ".mov")
	if stillDest == "" {
		base := sanitize(strings.TrimSpace(item.OriginalFilename))
		if base == "" {
			base = sanitize(strings.TrimSpace(item.Name))
		}
		stem := strings.TrimSuffix(base, filepath.Ext(base))
		if stem == "" {
			stem = "media"
		}
		dir := n.outDir
		if item.IsInTrash {
			dir = filepath.Join(n.outDir, "_Trash")
		}
		stillDest = filepath.Join(dir, stem)
	}
	return n.claim(strings.TrimSuffix(stillDest, filepath.Ext(stillDest)) + ext), item.IsInTrash
}

// coverDestination stores a custom album cover under "_AlbumCovers", named
// after its album.
func (n *namer) coverDestination(album manifestAlbum, coverPath string) string {
	name := sanitize(album.Name)
	if name == "" {
		name = "album"
	}
	ext := sanitizeExt(coverPath, ".jpg")
	return n.claim(filepath.Join(n.outDir, "_AlbumCovers", name+ext))
}

// claim reserves path, appending " (2)", " (3)"… when it is already taken.
func (n *namer) claim(path string) string {
	ext := filepath.Ext(path)
	stem := strings.TrimSuffix(path, ext)
	candidate := path
	for i := 2; n.used[strings.ToLower(candidate)]; i++ {
		candidate = fmt.Sprintf("%s (%d)%s", stem, i, ext)
	}
	n.used[strings.ToLower(candidate)] = true
	return candidate
}

// sanitize strips path separators and characters that are illegal on common
// filesystems, keeping the result recognizable.
func sanitize(name string) string {
	name = filepath.Base(name)
	replacer := strings.NewReplacer(
		"/", "_", "\\", "_", ":", "_", "*", "_",
		"?", "_", "\"", "_", "<", "_", ">", "_", "|", "_",
	)
	name = replacer.Replace(name)
	name = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, name)
	name = strings.TrimSpace(name)
	if name == "." || name == ".." {
		return ""
	}
	return name
}

// sanitizeExt extracts and sanitizes a file extension so untrusted paths cannot
// inject separators, NTFS alternate data streams (':'), or control characters.
func sanitizeExt(path, fallback string) string {
	raw := filepath.Ext(path)
	if raw == "" {
		return fallback
	}
	cleaned := sanitize(strings.TrimPrefix(raw, "."))
	cleaned = strings.TrimLeft(cleaned, ".")
	if cleaned == "" || len(cleaned) > 16 {
		return fallback
	}
	return "." + cleaned
}
