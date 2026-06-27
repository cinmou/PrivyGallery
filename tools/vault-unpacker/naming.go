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

	ext := filepath.Ext(base)
	stem := strings.TrimSuffix(base, ext)

	candidate := filepath.Join(dir, base)
	for i := 2; n.used[strings.ToLower(candidate)]; i++ {
		candidate = filepath.Join(dir, fmt.Sprintf("%s (%d)%s", stem, i, ext))
	}
	n.used[strings.ToLower(candidate)] = true
	return candidate, item.IsInTrash
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
