//go:build darwin && cgo

package alacritty

/*
#cgo CFLAGS: -I${SRCDIR}/../../engine/alacritty/bridge/include
#cgo LDFLAGS: ${SRCDIR}/../../engine/alacritty/bridge/target/release/libkero_alacritty.a -framework AppKit -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework Security -framework SystemConfiguration -framework IOKit -liconv
#include <stdlib.h>
#include "kero_alacritty.h"
extern void goAlacrittyEvent(void *, uint32_t, uint8_t *, size_t);
static inline KeroEventCallback event_callback(void) { return (KeroEventCallback)goAlacrittyEvent; }
*/
import "C"

import (
	"encoding/binary"
	"errors"
	"io"
	"os"
	"runtime/cgo"
	"strings"
	"sync"
	"unsafe"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/transfer"
	"github.com/egoist/mygo/ui"
)

type event struct {
	kind uint32
	data []byte
}
type controlRequest struct {
	size  [4]int
	theme *terminal.Theme
}
type Terminal struct {
	mu                                   sync.Mutex
	h                                    *C.KeroTerminal
	handle                               cgo.Handle
	callbackContext                      unsafe.Pointer
	opts                                 terminal.Options
	conn                                 io.ReadWriteCloser
	eventMu                              sync.Mutex
	events                               []event
	controlMu                            sync.Mutex
	controls                             []controlRequest
	controlWake                          chan struct{}
	wake                                 chan struct{}
	done                                 chan struct{}
	doneOnce                             sync.Once
	exitOnce                             sync.Once
	closed                               bool
	draw                                 func()
	status                               terminal.SearchStatus
	searchDirty                          bool
	services                             ui.Services
	cols, rows, cellW, cellH             int
	askedCols, askedRows, askedW, askedH int
	view                                 viewState
}

//export goAlacrittyEvent
func goAlacrittyEvent(ctx unsafe.Pointer, kind C.uint32_t, data *C.uint8_t, n C.size_t) {
	t := cgo.Handle(*(*C.uintptr_t)(ctx)).Value().(*Terminal)
	e := event{kind: uint32(kind)}
	if n != 0 {
		e.data = C.GoBytes(unsafe.Pointer(data), C.int(n))
	}
	t.eventMu.Lock()
	t.events = append(t.events, e)
	t.eventMu.Unlock()
	select {
	case t.wake <- struct{}{}:
	default:
	}
}

func cstr(s string) *C.char {
	if s == "" {
		return nil
	}
	return C.CString(s)
}
func packed(c ui.Color) C.uint32_t { return C.uint32_t(uint32(c.R)<<16 | uint32(c.G)<<8 | uint32(c.B)) }
func nativeTheme(theme *terminal.Theme) C.KeroTheme {
	if theme == nil {
		theme = terminal.DarkTheme()
	}
	var out C.KeroTheme
	for i, c := range theme.Palette {
		out.palette[i] = packed(c)
	}
	levels := [6]uint32{0, 95, 135, 175, 215, 255}
	for i := range 216 {
		out.palette[16+i] = C.uint32_t(levels[i/36]<<16 | levels[i/6%6]<<8 | levels[i%6])
	}
	for i := range 24 {
		v := uint32(8 + i*10)
		out.palette[232+i] = C.uint32_t(v<<16 | v<<8 | v)
	}
	out.foreground = packed(theme.Foreground)
	out.background = packed(theme.Background)
	out.cursor = out.foreground
	if theme.Cursor.A != 0 {
		out.cursor = packed(theme.Cursor)
	}
	return out
}

func New(opts terminal.Options) (*Terminal, error) {
	t := &Terminal{opts: opts, conn: opts.Conn, wake: make(chan struct{}, 1), controlWake: make(chan struct{}, 1), done: make(chan struct{}), cols: 80, rows: 24, cellW: 8, cellH: 16}
	t.handle = cgo.NewHandle(t)
	t.callbackContext = C.malloc(C.size_t(unsafe.Sizeof(C.uintptr_t(0))))
	*(*C.uintptr_t)(t.callbackContext) = C.uintptr_t(t.handle)
	cfg := C.KeroConfig{columns: 80, rows: 24, cell_width: 8, cell_height: 16, scrollback_lines: 10000, cursor_blinking: C.bool(!opts.NoBlink)}
	if opts.Scrollback < 0 {
		cfg.scrollback_lines = 0
	} else if opts.Scrollback > 0 {
		cfg.scrollback_lines = C.size_t(opts.Scrollback / 80)
	}
	switch opts.Cursor {
	case terminal.CursorBar:
		cfg.cursor_shape = 2
	case terminal.CursorUnderline:
		cfg.cursor_shape = 1
	}
	var allocated []*C.char
	makeString := func(s string) *C.char {
		p := cstr(s)
		if p != nil {
			allocated = append(allocated, p)
		}
		return p
	}
	defer func() {
		for _, p := range allocated {
			C.free(unsafe.Pointer(p))
		}
	}()
	if opts.Conn == nil {
		shell := os.Getenv("SHELL")
		if shell == "" {
			shell = "/bin/zsh"
		}
		args := opts.Command
		if len(args) > 0 {
			shell = args[0]
			args = args[1:]
		} else {
			args = []string{"-l"}
		}
		cfg.shell = makeString(shell)
		cfg.working_directory = makeString(opts.Dir)
		if len(args) > 0 {
			ptr := C.malloc(C.size_t(len(args)) * C.size_t(unsafe.Sizeof(uintptr(0))))
			defer C.free(ptr)
			a := unsafe.Slice((**C.char)(ptr), len(args))
			for i, s := range args {
				a[i] = makeString(s)
			}
			cfg.args = (**C.char)(ptr)
			cfg.args_len = C.size_t(len(args))
		}
		env := []string{"TERM=xterm-256color", "COLORTERM=truecolor"}
		if os.Getenv("LANG") == "" && os.Getenv("LC_ALL") == "" && os.Getenv("LC_CTYPE") == "" {
			env = append(env, "LANG=en_US.UTF-8")
		}
		env = append(env, opts.Env...)
		ptr := C.malloc(C.size_t(len(env)) * C.size_t(unsafe.Sizeof(uintptr(0))))
		defer C.free(ptr)
		a := unsafe.Slice((**C.char)(ptr), len(env))
		for i, s := range env {
			a[i] = makeString(s)
		}
		cfg.env = (**C.char)(ptr)
		cfg.env_len = C.size_t(len(env))
	}
	theme := nativeTheme(opts.Theme)
	if opts.Conn != nil {
		cfg.suppress_protocol_writes = true
		t.h = C.kero_alacritty_new_remote(&cfg, &theme, C.event_callback(), t.callbackContext)
	} else {
		t.h = C.kero_alacritty_new(&cfg, &theme, C.event_callback(), t.callbackContext)
	}
	if t.h == nil {
		C.free(t.callbackContext)
		t.handle.Delete()
		return nil, errors.New("alacritty: could not create terminal")
	}
	go t.dispatch()
	if t.conn != nil {
		go t.read()
		go t.writeControls()
	}
	return t, nil
}
func (t *Terminal) dispatch() {
	for {
		select {
		case <-t.done:
			return
		case <-t.wake:
			t.eventMu.Lock()
			es := t.events
			t.events = nil
			t.eventMu.Unlock()
			for _, e := range es {
				switch e.kind {
				case C.KERO_EVENT_WAKEUP:
					t.invalidate()
				case C.KERO_EVENT_TITLE:
					if t.opts.OnTitle != nil {
						t.opts.OnTitle(string(e.data))
					}
				case C.KERO_EVENT_BELL:
					if t.opts.OnBell != nil {
						t.opts.OnBell()
					}
				case C.KERO_EVENT_EXIT:
					code := 0
					if len(e.data) >= 4 {
						code = int(int32(binary.LittleEndian.Uint32(e.data)))
					}
					t.exited(code)
				case C.KERO_EVENT_NOTIFICATION:
					if t.opts.OnNotify != nil {
						title, body, ok := strings.Cut(string(e.data), "\x00")
						if !ok {
							body = title
							title = ""
						}
						t.opts.OnNotify(title, body)
					}
				case C.KERO_EVENT_REMOTE_INPUT:
					if t.conn != nil {
						_, _ = t.conn.Write(e.data)
					}
				case C.KERO_EVENT_CLIPBOARD_STORE, C.KERO_EVENT_CLIPBOARD_LOAD:
					t.eventMu.Lock()
					t.view.pending = append(t.view.pending, e)
					t.eventMu.Unlock()
					t.invalidate()
				}
			}
		}
	}
}
func (t *Terminal) requestControl(r controlRequest) {
	t.controlMu.Lock()
	t.controls = append(t.controls, r)
	t.controlMu.Unlock()
	select {
	case t.controlWake <- struct{}{}:
	default:
	}
}
func (t *Terminal) writeControls() {
	for {
		select {
		case <-t.done:
			return
		case <-t.controlWake:
			t.controlMu.Lock()
			requests := t.controls
			t.controls = nil
			t.controlMu.Unlock()
			for _, r := range requests {
				if r.theme != nil {
					if c, ok := t.conn.(interface{ UseTheme(*terminal.Theme) error }); ok {
						_ = c.UseTheme(r.theme)
					}
				} else if c, ok := t.conn.(interface {
					ResizePixels(int, int, int, int) error
				}); ok {
					_ = c.ResizePixels(r.size[0], r.size[1], r.size[2], r.size[3])
				} else if c, ok := t.conn.(interface{ Resize(int, int) error }); ok {
					_ = c.Resize(r.size[0], r.size[1])
				}
			}
		}
	}
}
func (t *Terminal) invalidate() {
	t.mu.Lock()
	f := t.draw
	t.mu.Unlock()
	if f != nil {
		f()
	}
}
func (t *Terminal) Done() <-chan struct{} { return t.done }
func (t *Terminal) exited(code int) {
	t.doneOnce.Do(func() { close(t.done) })
	t.exitOnce.Do(func() {
		if t.opts.OnExit != nil {
			t.opts.OnExit(code)
		}
	})
}
func (t *Terminal) read() {
	b := make([]byte, 32768)
	for {
		n, err := t.conn.Read(b)
		if n > 0 {
			t.mu.Lock()
			if t.h != nil {
				C.kero_alacritty_feed(t.h, (*C.uint8_t)(unsafe.Pointer(&b[0])), C.size_t(n))
			}
			t.mu.Unlock()
		}
		if err != nil {
			t.exited(0)
			return
		}
	}
}
func (t *Terminal) Close() error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil
	}
	t.closed = true
	h := t.h
	t.h = nil
	t.doneOnce.Do(func() { close(t.done) })
	t.mu.Unlock()
	if t.conn != nil {
		_ = t.conn.Close()
	}
	if h != nil {
		C.kero_alacritty_free(h)
	}
	C.free(t.callbackContext)
	t.handle.Delete()
	return nil
}
func (t *Terminal) Resize(cols, rows int) {
	if cols < 1 || rows < 1 {
		return
	}
	t.mu.Lock()
	if t.h != nil {
		t.cols, t.rows = cols, rows
		C.kero_alacritty_resize(t.h, C.uint16_t(min(cols, 65535)), C.uint16_t(min(rows, 65535)), C.uint16_t(t.cellW), C.uint16_t(t.cellH))
	}
	t.mu.Unlock()
	t.invalidate()
}
func (t *Terminal) Send(b []byte) {
	if len(b) == 0 {
		return
	}
	t.mu.Lock()
	if t.h != nil {
		C.kero_alacritty_write(t.h, (*C.uint8_t)(unsafe.Pointer(&b[0])), C.size_t(len(b)))
	}
	t.mu.Unlock()
}
func (t *Terminal) Paste(s string) {
	t.mu.Lock()
	bracket := t.h != nil && uint32(C.kero_alacritty_mode(t.h))&uint32(C.KERO_MODE_BRACKETED_PASTE) != 0
	t.mu.Unlock()
	s = strings.ReplaceAll(s, "\x00", "")
	if bracket {
		s = "\x1b[200~" + strings.ReplaceAll(s, "\x1b", "") + "\x1b[201~"
	} else {
		s = strings.ReplaceAll(strings.ReplaceAll(s, "\r\n", "\r"), "\n", "\r")
	}
	t.Send([]byte(s))
}
func (t *Terminal) PasteData(d transfer.Data) {
	for _, item := range d.Items() {
		if b, err := item.Read(transfer.Text); err == nil {
			t.Paste(string(b))
			return
		}
	}
	if t.mode()&uint32(C.KERO_MODE_BRACKETED_PASTE) != 0 {
		t.Paste("")
	} else if t.opts.OnPasteStatus != nil {
		go t.opts.OnPasteStatus(terminal.PasteProgress{Status: terminal.PasteNoText})
	}
}
func (t *Terminal) Search(s string) {
	if s == "" {
		t.EndSearch()
		return
	}
	t.mu.Lock()
	if t.h != nil && s != t.status.Text {
		p := C.CString(s)
		count := int(C.kero_alacritty_find(t.h, p))
		C.free(unsafe.Pointer(p))
		t.status = terminal.SearchStatus{Text: s, Total: count}
		if count > 0 {
			i := int(C.kero_alacritty_find_step(t.h, false))
			if i >= 0 {
				t.status.Selected = i + 1
			}
		}
		t.searchDirty = true
	}
	t.mu.Unlock()
	t.invalidate()
}
func (t *Terminal) step(forward bool) {
	t.mu.Lock()
	if t.h != nil && t.status.Text != "" {
		i := int(C.kero_alacritty_find_step(t.h, C.bool(forward)))
		if i >= 0 {
			t.status.Selected = i + 1
		}
		t.searchDirty = true
	}
	t.mu.Unlock()
	t.invalidate()
}
func (t *Terminal) SearchNext()     { t.step(false) }
func (t *Terminal) SearchPrevious() { t.step(true) }
func (t *Terminal) EndSearch() {
	t.mu.Lock()
	if t.h != nil {
		C.kero_alacritty_find_end(t.h)
	}
	t.status = terminal.SearchStatus{}
	t.searchDirty = true
	t.mu.Unlock()
	t.invalidate()
}
func (t *Terminal) SearchStatus() terminal.SearchStatus {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.status
}
func (t *Terminal) SetFont(f terminal.Font) {
	t.mu.Lock()
	t.opts.Font = f
	t.mu.Unlock()
	t.invalidate()
}
func (t *Terminal) SetTheme(a, b *terminal.Theme) {
	t.mu.Lock()
	t.opts.Theme = a
	t.opts.DarkTheme = b
	t.view.theme = nil
	t.mu.Unlock()
	t.invalidate()
}
func (t *Terminal) SetMinimumContrast(v float32) {
	t.mu.Lock()
	t.opts.MinimumContrast = v
	t.mu.Unlock()
	t.invalidate()
}
func (t *Terminal) SetScrollMultiplier(v terminal.ScrollMultiplier) {
	t.mu.Lock()
	t.opts.ScrollMultiplier = v
	t.mu.Unlock()
}
func (t *Terminal) SetCopyOnSelect(v terminal.CopyOnSelect) {
	t.mu.Lock()
	t.opts.CopyOnSelect = v
	t.mu.Unlock()
}
func (t *Terminal) resolveClipboard(id uint64, text string, allow bool) {
	b := []byte(text)
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.h == nil {
		return
	}
	var p *C.uint8_t
	if len(b) > 0 {
		p = (*C.uint8_t)(unsafe.Pointer(&b[0]))
	}
	C.kero_alacritty_resolve_clipboard(t.h, C.uint64_t(id), p, C.size_t(len(b)), C.bool(allow))
}
