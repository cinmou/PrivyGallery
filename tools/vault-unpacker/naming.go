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
	ext := filepath.Ext(companionPath)
	if ext == "" {
		ext = ".mov"
	}
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
	ext := filepath.Ext(coverPath)
	if ext == "" {
		ext = ".jpg"
	}
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
	name = strings.TrimSpace(name)
	if name == "." || name == ".." {
		return ""
	}
	return name
}
