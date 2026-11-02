package clilink

import (
	"encoding/binary"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The command is a console copy of a GUI executable, which runs.
func TestLinkMakesConsoleCopy(t *testing.T) {
	src, err := exec.LookPath("notepad.exe")
	if err != nil {
		t.Skip("no notepad")
	}
	b, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if subsystem(t, b) != 2 {
		t.Skip("notepad is not a GUI executable")
	}
	exe := filepath.Join(t.TempDir(), "gui.exe")
	if err := os.WriteFile(exe, b, 0o755); err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	if err := Link(exe, bin); err != nil {
		t.Fatal(err)
	}
	out, err := os.ReadFile(filepath.Join(bin, "kero.exe"))
	if err != nil {
		t.Fatal(err)
	}
	if got := subsystem(t, out); got != 3 {
		t.Errorf("subsystem %d, want the console's", got)
	}
	if got := Target(bin); !strings.EqualFold(got, exe) {
		t.Errorf("target %q", got)
	}
	// Again: nothing to do.
	if err := Link(exe, bin); err != nil {
		t.Fatal(err)
	}
}

func subsystem(t *testing.T, b []byte) uint16 {
	pe := int(binary.LittleEndian.Uint32(b[0x3c:]))
	return binary.LittleEndian.Uint16(b[pe+24+68:])
}
