// Command vault-unpacker decrypts and extracts PrivyGallery ".vault" backup
// files on any platform, without the original app.
//
// Usage:
//
//	vault-unpacker [options] <path>...
//
// Each <path> may be a .vault file or a directory containing .vault files.
// Multi-part backups can be passed together (or as a directory); each part is
// independent and is unpacked in turn.
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"golang.org/x/term"
)

func main() {
	outDir := flag.String("o", "vault-unpacked", "output directory for extracted media")
	password := flag.String("p", "", "backup password (omit to be prompted securely)")
	listOnly := flag.Bool("l", false, "list contents only; do not extract anything")

	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "vault-unpacker — decrypt and extract PrivyGallery .vault backups\n\n")
		fmt.Fprintf(os.Stderr, "Usage:\n  %s [options] <file-or-directory>...\n\nOptions:\n", filepath.Base(os.Args[0]))
		flag.PrintDefaults()
		fmt.Fprintf(os.Stderr, "\nExamples:\n")
		fmt.Fprintf(os.Stderr, "  %s ~/Backups/PrivyGallery\\ Backup.vault\n", filepath.Base(os.Args[0]))
		fmt.Fprintf(os.Stderr, "  %s -o ./restored ~/Backups            # unpack every .vault in a folder\n", filepath.Base(os.Args[0]))
		fmt.Fprintf(os.Stderr, "  %s -l backup.vault                    # just list what's inside\n", filepath.Base(os.Args[0]))
	}
	flag.Parse()

	if flag.NArg() == 0 {
		flag.Usage()
		os.Exit(2)
	}

	vaultFiles, err := collectVaultFiles(flag.Args())
	if err != nil {
		fatalf("%v", err)
	}
	if len(vaultFiles) == 0 {
		fatalf("no .vault files found in the given path(s)")
	}

	pass := *password
	if pass == "" {
		pass = os.Getenv("VAULT_PASSWORD")
	}
	if pass == "" {
		pass, err = promptPassword()
		if err != nil {
			fatalf("could not read password: %v", err)
		}
	}
	if strings.TrimSpace(pass) == "" {
		fatalf("password must not be empty")
	}

	if !*listOnly {
		if err := os.MkdirAll(*outDir, 0o755); err != nil {
			fatalf("could not create output directory: %v", err)
		}
	}

	var totalFiles int
	var totalBytes int64
	var failures int

	for _, vf := range vaultFiles {
		fmt.Printf("\n📦 %s\n", vf)
		extracted, bytes, err := unpackOne(vf, pass, *outDir, *listOnly)
		if err != nil {
			if errors.Is(err, ErrWrongPassword) {
				fatalf("incorrect password — could not decrypt %s", filepath.Base(vf))
			}
			fmt.Fprintf(os.Stderr, "   ✗ %v\n", err)
			failures++
			continue
		}
		totalFiles += extracted
		totalBytes += bytes
	}

	fmt.Printf("\n")
	if *listOnly {
		fmt.Printf("Listed %d media item(s) across %d backup file(s).\n", totalFiles, len(vaultFiles))
	} else {
		fmt.Printf("Done. Extracted %d media file(s) (%s) into %s\n",
			totalFiles, humanBytes(totalBytes), *outDir)
	}
	if failures > 0 {
		os.Exit(1)
	}
}

// unpackOne decrypts a single .vault file and extracts (or lists) its media.
func unpackOne(vaultPath, password, outDir string, listOnly bool) (int, int64, error) {
	tmp, err := os.CreateTemp("", "vault-archive-*.tmp")
	if err != nil {
		return 0, 0, err
	}
	archivePath := tmp.Name()
	tmp.Close()
	defer os.Remove(archivePath)

	header, err := decryptVaultToArchive(vaultPath, password, archivePath)
	if err != nil {
		return 0, 0, err
	}
	if header.TotalParts > 1 {
		fmt.Printf("   part %d of %d\n", header.PartIndex+1, header.TotalParts)
	}

	extracted, man, err := extractArchive(archivePath, outDir, listOnly)
	if err != nil {
		return 0, 0, err
	}

	if listOnly {
		for _, it := range man.Items {
			name := it.OriginalFilename
			if name == "" {
				name = it.Name
			}
			trash := ""
			if it.IsInTrash {
				trash = "  [trash]"
			}
			fmt.Printf("   • %s (%s)%s\n", name, it.MediaKindRawValue, trash)
		}
		return len(man.Items), 0, nil
	}

	var bytes int64
	for _, e := range extracted {
		bytes += e.ByteCount
	}
	fmt.Printf("   ✓ %d file(s), %s\n", len(extracted), humanBytes(bytes))
	return len(extracted), bytes, nil
}

// collectVaultFiles expands the given paths into a sorted list of .vault files.
// Files are taken as-is; directories are scanned (non-recursively) for *.vault.
func collectVaultFiles(paths []string) ([]string, error) {
	var files []string
	seen := make(map[string]bool)

	add := func(p string) {
		abs, err := filepath.Abs(p)
		if err != nil {
			abs = p
		}
		if !seen[abs] {
			seen[abs] = true
			files = append(files, p)
		}
	}

	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil {
			return nil, fmt.Errorf("cannot access %s: %w", p, err)
		}
		if info.IsDir() {
			entries, err := os.ReadDir(p)
			if err != nil {
				return nil, err
			}
			for _, e := range entries {
				if !e.IsDir() && strings.EqualFold(filepath.Ext(e.Name()), ".vault") {
					add(filepath.Join(p, e.Name()))
				}
			}
		} else {
			add(p)
		}
	}

	sort.Slice(files, func(i, j int) bool {
		return filepath.Base(files[i]) < filepath.Base(files[j])
	})
	return files, nil
}

func promptPassword() (string, error) {
	fmt.Fprint(os.Stderr, "Backup password: ")
	if term.IsTerminal(int(os.Stdin.Fd())) {
		b, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Fprintln(os.Stderr)
		if err != nil {
			return "", err
		}
		return string(b), nil
	}
	// Non-interactive stdin (e.g. piped): read a single line.
	var line string
	_, err := fmt.Scanln(&line)
	return line, err
}

func humanBytes(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(b)/float64(div), "KMGTPE"[exp])
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", args...)
	os.Exit(1)
}
