package terminal

import (
	"fmt"
	"strings"
	"testing"

	"github.com/egoist/mygo/ui"
)

func capturedFixture(t *testing.T, enabled bool) (*Terminal, *pipe, *ui.Tester) {
	t.Helper()
	loadLib(t)
	p := newPipe()
	term, err := New(Options{Conn: p, SelectOnCapturedMouseDrag: enabled, CopyOnSelect: CopyOnSelectClipboard})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { term.Close() })
	term.Feed([]byte("FIRST words\r\nSECOND words\r\nthird words\x1b[?1000h\x1b[?1006h"))
	tt := ui.NewTester(func(c *ui.Context) {
		ui.Column(c).Fill().Children(func() {
			ui.Button(c, "Other").Height(30)
			View(c, term).Grow(1).AutoFocus()
		})
	}, 400, 220)
	// AutoFocus is applied after View builds; the next frame observes it.
	tt.Frame()
	return term, p, tt
}

// Terminal coordinates are local to the view; the fixture places it below a button.
func capturedPoint(term *Terminal, col, row int) (float32, float32) {
	x, y := cellCenter(term, col, row)
	return x, y + 30
}

func TestCapturedMouseClicksAndJitter(t *testing.T) {
	term, p, tt := capturedFixture(t, true)
	x, y := capturedPoint(term, 2, 0)
	for click := range 2 {
		tt.Press(x, y)
		if got := p.take(term); got != "" {
			t.Fatalf("press reached program before release: %q", got)
		}
		tt.Move(x+2, y+1)
		tt.Release(x+2, y+1)
		if got, want := p.take(term), "\x1b[<0;3;1M\x1b[<0;3;1m"; got != want {
			t.Fatalf("click %d = %q, want %q", click+1, got, want)
		}
	}
}

func TestCapturedMouseDragThreshold(t *testing.T) {
	term, p, tt := capturedFixture(t, true)
	x, y := capturedPoint(term, 1, 0)
	tt.Press(x, y)
	tt.Move(x+4, y)
	if !term.v.selecting || term.v.capturedPending {
		t.Fatal("four DIP movement did not begin selection")
	}
	tt.Release(x+4, y)
	if got := p.take(term); got != "" {
		t.Fatalf("threshold drag reached program: %q", got)
	}
}

func TestCapturedMouseDragEndsAndStartsFresh(t *testing.T) {
	term, p, tt := capturedFixture(t, true)
	for row, want := range []string{"FIRST", "SECOND"} {
		x, y := capturedPoint(term, 0, row)
		tt.Press(x-2, y)
		x, y = capturedPoint(term, len(want)-1, row)
		tt.Move(x+2, y)
		tt.Release(x+2, y)
		if got := tt.Clipboard(); got != want {
			t.Fatalf("drag %d selected %q, want %q", row, got, want)
		}
		if got := p.take(term); got != "" {
			t.Fatalf("drag reported mouse to program: %q", got)
		}
		if term.v.selecting || term.v.ticking {
			t.Fatal("release left selection active")
		}
		tt.Move(x+20, y)
		if got := tt.Clipboard(); got != want {
			t.Fatalf("motion after release changed selection: %q", got)
		}
	}
}

func TestCapturedMouseFocusAndSecondary(t *testing.T) {
	term, p, tt := capturedFixture(t, true)
	if err := tt.Click("Other"); err != nil {
		t.Fatal(err)
	}
	x, y := capturedPoint(term, 0, 0)
	tt.ClickAt(x, y)
	if got := p.take(term); got != "" {
		t.Fatalf("focus click reached program: %q", got)
	}
	tt.ClickAt(x, y)
	if got := p.take(term); got != "\x1b[<0;1;1M\x1b[<0;1;1m" {
		t.Fatalf("focused click = %q", got)
	}
	if err := tt.Click("Other"); err != nil {
		t.Fatal(err)
	}
	tt.Press(x-2, y)
	x2, _ := capturedPoint(term, 4, 0)
	tt.Move(x2+2, y)
	tt.Release(x2+2, y)
	if got := tt.Clipboard(); got != "FIRST" {
		t.Fatalf("focus drag selected %q", got)
	}
	if got := p.take(term); got != "" {
		t.Fatalf("focus drag reached program: %q", got)
	}
	tt.RightClickAt(x, y)
	if got := p.take(term); got != "\x1b[<2;1;1M\x1b[<2;1;1m" {
		t.Fatalf("secondary click = %q", got)
	}
}

func TestCapturedMouseShiftAndStock(t *testing.T) {
	term, p, tt := capturedFixture(t, true)
	x, y := capturedPoint(term, 0, 0)
	tt.Press(x-2, y)
	x2, _ := capturedPoint(term, 4, 0)
	tt.Move(x2+2, y)
	tt.Release(x2+2, y)
	x3, y3 := capturedPoint(term, 5, 1)
	tt.ClickAtWith(ui.Shift, x3, y3)
	if got := tt.Clipboard(); got != "FIRST words\nSECOND" {
		t.Fatalf("Shift extension = %q", got)
	}
	if got := p.take(term); got != "" {
		t.Fatalf("Shift extension reached program: %q", got)
	}
	// Shift-double-click still uses the terminal's native word gesture.
	x, y = capturedPoint(term, 2, 2)
	tt.ClickAtWith(ui.Shift, x, y)
	tt.ClickAtWith(ui.Shift, x, y)
	if got := tt.Clipboard(); !strings.Contains(got, "third") {
		t.Fatalf("Shift double click selected %q", got)
	}

	stock, sp, st := capturedFixture(t, false)
	sx, sy := capturedPoint(stock, 1, 0)
	st.Press(sx, sy)
	if got, want := sp.take(stock), fmt.Sprintf("\x1b[<0;%d;1M", 2); got != want {
		t.Fatalf("stock press = %q, want %q", got, want)
	}
	st.Release(sx, sy)
	if got := sp.take(stock); got != "\x1b[<0;2;1m" {
		t.Fatalf("stock release = %q", got)
	}
}
