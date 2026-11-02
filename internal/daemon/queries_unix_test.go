//go:build unix

package daemon

import (
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"kero/internal/proto"
)

// reader gives the pane a program that reads n bytes raw, the terminal's
// answer to a query, and returns a func that asks the query and returns
// the answer.
func reader(t *testing.T, s *pane, n int) func(query string) string {
	t.Helper()
	out := filepath.Join(t.TempDir(), "reply")
	proc, err := startPTY(ptyOptions{
		Path: "/bin/sh", Args: []string{"sh", "-c", `stty raw -echo; dd bs=1 count="$1" of="$0" 2>/dev/null`, out, strconv.Itoa(n)},
		Dir: t.TempDir(), Env: testEnv(t),
		Cols: s.info.Cols, Rows: s.info.Rows,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { proc.Kill() })
	go func() {
		buf := make([]byte, 4096)
		for {
			if _, err := proc.Read(buf); err != nil {
				return
			}
		}
	}()
	s.mu.Lock()
	s.proc = proc
	s.mu.Unlock()
	return func(query string) string {
		t.Helper()
		// The answer goes to the program once it reads raw.
		deadline := time.Now().Add(10 * time.Second) // a hang guard
		for {
			if _, err := os.Stat(out); err == nil {
				break
			}
			if time.Now().After(deadline) {
				t.Fatal("the program did not start")
			}
			time.Sleep(10 * time.Millisecond)
		}
		s.output([]byte(query))
		for {
			b, _ := os.ReadFile(out)
			if len(b) >= n || time.Now().After(deadline) {
				return string(b)
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
}

// The program gets the size of the client's cells in pixels, from the
// terminal's answer to CSI 16t and from the pseudo-terminal's size: what
// a program taking the mouse in pixels (mode 1016), as Claude Code does,
// counts the client's reports in.
func TestCellPixels(t *testing.T) {
	s := testPane(t)
	want := "\x1b[6;36;18t"
	ask := reader(t, s, len(want))
	s.resize(96, 28, 18, 36)
	var ws struct{ row, col, xpixel, ypixel uint16 }
	if err := ioctl(s.proc.master, syscall.TIOCGWINSZ, unsafe.Pointer(&ws)); err != nil {
		t.Fatal(err)
	}
	if ws.xpixel != 96*18 || ws.ypixel != 28*36 {
		t.Errorf("the pseudo-terminal is %dx%d pixels, want %dx%d", ws.xpixel, ws.ypixel, 96*18, 28*36)
	}
	if got := ask("\x1b[16t"); got != want {
		t.Errorf("CSI 16t answered %q, want %q", got, want)
	}
}

// The program asking about the colors gets the client's: Copilot CLI,
// asking the background, drew its input box dark on a light one. A pane
// made later gets them too.
func TestClientTheme(t *testing.T) {
	s := testPane(t)
	s.d.panes = map[string]*pane{s.info.ID: s}
	light := proto.Theme{Foreground: [4]byte{0x20, 0x20, 0x20, 255}, Background: [4]byte{0xfa, 0xfa, 0xfa, 255}}
	s.d.useTheme(light)
	want := "\x1b]11;rgb:fafa/fafa/fafa\x1b\\\x1b[?997;2n"
	if got := reader(t, s, len(want))("\x1b]11;?\x1b\\\x1b[?996n"); got != want {
		t.Errorf("the background and the color scheme answered %q, want %q", got, want)
	}
	later, err := newPane(s.d, "s", proto.Pane{ID: "q", Cols: 80, Rows: 24})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { later.term.Close() })
	if got := reader(t, later, len(want))("\x1b]11;?\x1b\\\x1b[?996n"); got != want {
		t.Errorf("a later pane answered %q, want %q", got, want)
	}
}
