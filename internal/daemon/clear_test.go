package daemon

import (
	"fmt"
	"io"
	"strings"
	"testing"

	"github.com/egoist/mygo/plugins/terminal"

	"kero/internal/proto"
)

// quiet is a client terminal's connection, which only frames feed.
type quiet struct{ done chan struct{} }

func (q quiet) Read([]byte) (int, error)    { <-q.done; return 0, io.EOF }
func (q quiet) Write(p []byte) (int, error) { return len(p), nil }
func (q quiet) Close() error                { return nil }

// client is a terminal attached to a pane, as the app's: it shows the
// frames of a Mirror of the pane's terminal.
type client struct {
	t    *testing.T
	s    *pane
	term *terminal.Terminal
	m    *terminal.Mirror
}

func attachClient(t *testing.T, s *pane) *client {
	t.Helper()
	done := make(chan struct{})
	term, err := terminal.New(terminal.Options{Conn: quiet{done}, ResizeByConn: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { close(done); term.Close() })
	m, err := s.term.NewMirror()
	if err != nil {
		t.Fatal(err)
	}
	term.Resize(s.info.Cols, s.info.Rows)
	c := &client{t: t, s: s, term: term, m: m}
	c.sync()
	return c
}

// sync shows the pane's next frame.
func (c *client) sync() {
	c.s.mu.Lock()
	f, _ := c.m.Frame()
	c.s.mu.Unlock()
	c.term.Feed(f)
}

// resize resizes the pane as the app does: frames of the old size, the
// client's terminal resized where the pane's was, frames of the new.
func (c *client) resize(cols, rows int) {
	c.sync()
	c.s.resize(cols, rows, 0, 0)
	c.term.Resize(cols, rows)
	c.sync()
}

// lines returns a terminal's text, scrollback and screen, without the
// empty lines at its end.
func lines(term *terminal.Terminal) []string {
	text := strings.TrimRight(term.Text(), "\n ")
	var out []string
	for l := range strings.SplitSeq(text, "\n") {
		out = append(out, strings.TrimRight(l, " "))
	}
	return out
}

// check fails unless the pane's terminal and the client's both show want
// and nothing else: no scrollback, nothing below.
func (c *client) check(when string, want ...string) {
	c.t.Helper()
	c.sync()
	for name, term := range map[string]*terminal.Terminal{"kerod": c.s.term, "client": c.term} {
		if got := lines(term); strings.Join(got, "\n") != strings.Join(want, "\n") {
			c.t.Errorf("%s, %s shows %q, want %q", when, name, got, want)
		}
	}
}

// ⌘K clears the session's terminal, whose frames the app shows: the
// prompt stays at the top as the user types, the scrollback stays gone,
// and resizes after it bring nothing back.
func TestClearScreen(t *testing.T) {
	s := testPane(t)
	c := attachClient(t, s)
	for i := range 60 {
		s.output(fmt.Appendf(nil, "line %d\r\n", i))
	}
	s.output([]byte("~/dev via v1.4.3\r\n\x1b[32m❯\x1b[0m "))
	c.sync()

	s.clear(proto.ClearScreen)
	c.check("after ⌘K", "❯")

	// The shell echoes what is typed where its cursor is, and repaints its
	// line from the line's start.
	s.output([]byte("l"))
	c.check("typing", "❯ l")
	s.output([]byte("\r\x1b[K\x1b[32m❯\x1b[0m ls -la"))
	c.check("the line repainted", "❯ ls -la")

	c.resize(80, 20)
	c.check("narrower", "❯ ls -la")
	c.resize(120, 40)
	c.check("wider", "❯ ls -la")

	// Output after it scrolls as before.
	s.output([]byte("\r\n"))
	for i := range 50 {
		s.output(fmt.Appendf(nil, "out %d\r\n", i))
	}
	c.sync()
	if got, want := lines(c.term), lines(s.term); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("output after ⌘K: the client shows %d lines, kerod %d", len(got), len(want))
	}
	if got := lines(s.term); len(got) != 51 || got[0] != "❯ ls -la" {
		t.Errorf("output after ⌘K: kerod shows %d lines from %q, want 51 from the prompt", len(got), got[0])
	}

	// Clear Scrollback leaves the screen.
	s.clear(proto.ClearScrollback)
	c.sync()
	if got, want := lines(c.term), lines(s.term); len(want) != 39 || strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("after Clear Scrollback: kerod shows %d lines, the client %d, want the screen's 39 above the cursor", len(want), len(got))
	}
}

// A full-screen program's screen is left alone.
func TestClearScreenFullScreen(t *testing.T) {
	s := testPane(t)
	c := attachClient(t, s)
	s.output([]byte("\x1b[?1049h\x1b[Htop row\x1b[10;5Hmiddle"))
	s.clear(proto.ClearScreen)
	c.sync()
	for name, term := range map[string]*terminal.Terminal{"kerod": s.term, "client": c.term} {
		got := lines(term)
		if len(got) != 10 || got[0] != "top row" || got[9] != "    middle" {
			t.Errorf("%s shows %q", name, got)
		}
	}
}
