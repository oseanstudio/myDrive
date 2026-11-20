//go:build ignore

// Build the host and collect the notices for the modules linked into it.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

func main() {
	if len(os.Args) != 2 {
		panic("usage: go run build.go --test | OUTPUT_DIRECTORY")
	}
	if err := build(os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func build(directory string) error {
	goTool := filepath.Join(runtime.GOROOT(), "bin", "go")
	binary := "mydrive-smb-host"
	if runtime.GOOS == "windows" {
		goTool += ".exe"
		binary += ".exe"
	}
	scratch, err := os.MkdirTemp("", "mydrive-smb-build-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(scratch)
	modfile, err := creditPayloadModfile(goTool, scratch)
	if err != nil {
		return err
	}
	if directory == "--test" {
		return runGo(goTool, "test", "-mod=readonly", "-modfile="+modfile, "./...")
	}
	if _, err := os.Stat(directory); err != nil {
		return err
	}
	if err := runGo(goTool, "build", "-mod=readonly", "-modfile="+modfile, "-trimpath", "-buildvcs=false",
		"-o", filepath.Join(directory, binary), "."); err != nil {
		return err
	}
	modules, err := exec.Command(goTool, "list", "-mod=readonly", "-buildvcs=false", "-deps", "-f",
		"{{with .Module}}{{if not .Main}}{{.Path}}\t{{.Dir}}{{end}}{{end}}", ".").Output()
	if err != nil {
		return err
	}

	var notices bytes.Buffer
	if err := appendNotice(&notices, "Go standard library", filepath.Join(runtime.GOROOT(), "LICENSE")); err != nil {
		return err
	}
	seen := map[string]bool{}
	for _, line := range strings.Split(string(modules), "\n") {
		name, root, found := strings.Cut(strings.TrimSpace(line), "\t")
		if !found || seen[name] {
			continue
		}
		seen[name] = true
		loaded := false
		for _, filename := range []string{"LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING", "NOTICE", "NOTICE.txt"} {
			file := filepath.Join(root, filename)
			if _, err := os.Stat(file); err == nil {
				if err := appendNotice(&notices, name+" "+filename, file); err != nil {
					return err
				}
				loaded = true
			}
		}
		if !loaded {
			return fmt.Errorf("missing Go notice for %s", name)
		}
	}
	return os.WriteFile(filepath.Join(directory, "SMB-ThirdPartyNotices.txt"), notices.Bytes(), 0o644)
}

func runGo(tool string, args ...string) error {
	command := exec.Command(tool, args...)
	command.Env = append(os.Environ(), "GOWORK=off")
	command.Stdout, command.Stderr = os.Stdout, os.Stderr
	return command.Run()
}

// SMB credits are calculated from the variable-length WRITE payload (MS-SMB2
// 3.1.5.2). The pinned version also counts the 48-byte fixed WRITE header,
// rejecting legitimate writes at 64 KiB boundaries. Keep the credit checks
// and account for both the declared and actual variable-length bytes.
func creditPayloadModfile(goTool, scratch string) (string, error) {
	const module = "github.com/go-filesystems/smb"
	command := exec.Command(goTool, "mod", "download", "-json", module)
	data, err := command.Output()
	if err != nil {
		return "", err
	}
	var downloaded struct{ Dir, Version string }
	if err := json.Unmarshal(data, &downloaded); err != nil {
		return "", err
	}
	patchedModule := filepath.Join(scratch, "smb")
	if err := os.CopyFS(patchedModule, os.DirFS(downloaded.Dir)); err != nil {
		return "", err
	}
	patched := filepath.Join(patchedModule, "credit.go")
	source, err := os.ReadFile(patched)
	if err != nil {
		return "", err
	}
	const before = "\tswitch h.command {\n\tcase cmdRead:"
	if strings.Count(string(source), before) != 1 {
		return "", fmt.Errorf("pinned SMB credit code changed; review the WRITE compatibility patch")
	}
	const after = "\tswitch h.command {\n\tcase cmdWrite:\n\t\tif len(body) >= 48 {\n\t\t\tsize = max(size-48, at(4))\n\t\t}\n\tcase cmdRead:"
	if err := os.WriteFile(patched, []byte(strings.Replace(string(source), before, after, 1)), 0o600); err != nil {
		return "", err
	}
	for _, filename := range []string{"go.mod", "go.sum"} {
		content, err := os.ReadFile(filename)
		if err != nil {
			return "", err
		}
		if err := os.WriteFile(filepath.Join(scratch, filename), content, 0o600); err != nil {
			return "", err
		}
	}
	path := filepath.Join(scratch, "go.mod")
	err = runGo(goTool, "mod", "edit", "-modfile="+path, "-replace="+module+"@"+downloaded.Version+"="+patchedModule)
	return path, err
}

func appendNotice(output *bytes.Buffer, title, file string) error {
	text, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	fmt.Fprintf(output, "===== %s =====\n\n%s\n\n", title, text)
	return nil
}
