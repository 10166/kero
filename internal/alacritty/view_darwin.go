//go:build darwin && cgo

package alacritty

/*
#include "kero_alacritty.h"
*/
import "C"

import (
	"bytes"
	"encoding/binary"
	"image/png"
	"math"
	"sort"
	"strings"
	"time"
	"unsafe"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"
)

var defaultLight, defaultDark = terminal.LightTheme(), terminal.DarkTheme()

type viewState struct {
	pending                             []event
	theme                               *terminal.Theme
	font                                ui.Font
	cw, ch, base, ox, oy                float32
	selecting                           bool
	capturedPending, capturedFocusOnly  bool
	capturedPress                       ui.InputEvent
	focused, cursorBlink, cursorVisible bool
	cursorX, cursorY                    int
	blinkStart                          time.Time
	keyMods                             ui.Modifiers
	keyCode                             int
	keyRepeat                           bool
	reportedKeys                        map[ui.Key]bool
	preedit                             string
	suppressText                        bool
	bitmaps                             map[uint32]imageCache
	glyphs                              map[glyphKey][]ui.Glyph
	pointerX, pointerY                  float32
	hovered                             string
	hoverRect                           ui.Rect
	clipOpen                            bool
	clipPending                         []clipboardRead
	scroll                              float32
	zoom                                float32
}
type clipboardRead struct {
	id      uint64
	primary bool
}

type imageCache struct {
	generation uint64
	bitmap     *ui.Bitmap
}
type glyphKey struct {
	text string
	font ui.Font
}

func (v *viewState) shape(text string, font ui.Font) []ui.Glyph {
	key := glyphKey{text, font}
	if glyphs, ok := v.glyphs[key]; ok {
		return glyphs
	}
	if len(v.glyphs) >= 8192 {
		clear(v.glyphs)
	}
	if v.glyphs == nil {
		v.glyphs = make(map[glyphKey][]ui.Glyph)
	}
	glyphs := ui.Shape(text, font)
	v.glyphs[key] = glyphs
	return glyphs
}

type drawnImage struct {
	bmp      *ui.Bitmap
	src, dst ui.Rect
	z        int32
}

func color(v C.uint32_t) ui.Color { n := uint32(v); return ui.RGB(uint8(n>>16), uint8(n>>8), uint8(n)) }
func View(c *ui.Context, t *Terminal) ui.Element {
	e := ui.Box(c).Direction(ui.LeftToRight).Focusable().FocusRing(false).Clip().Label("Terminal")
	t.mu.Lock()
	t.services = c.Services()
	t.draw = t.services.Invalidate
	theme := t.opts.Theme
	if c.Theme().Dark && t.opts.DarkTheme != nil {
		theme = t.opts.DarkTheme
	}
	if theme == nil {
		if c.Theme().Dark {
			theme = defaultDark
		} else {
			theme = defaultLight
		}
	}
	if t.view.theme != theme {
		if t.h != nil {
			native := nativeTheme(theme)
			C.kero_alacritty_set_theme(t.h, &native)
		}
		t.view.theme = theme
		if t.conn != nil {
			t.requestControl(controlRequest{theme: theme})
		}
	}
	status, dirty := t.status, t.searchDirty
	t.searchDirty = false
	focused := e.Focused()
	v := &t.view
	changed := focused != v.focused
	if changed {
		v.focused = focused
		v.blinkStart = c.Now()
	}
	report := changed && t.h != nil && uint32(C.kero_alacritty_mode(t.h))&uint32(C.KERO_MODE_FOCUS_REPORTING) != 0
	caret := ui.Rect{X: v.ox + float32(v.cursorX)*v.cw, Y: v.oy + float32(v.cursorY)*v.ch, W: v.cw, H: v.ch}
	since := c.Now().Sub(v.blinkStart)
	v.cursorVisible = !focused || !v.cursorBlink || since/(600*time.Millisecond)%2 == 0
	t.mu.Unlock()
	if report {
		if focused {
			t.Send([]byte("\x1b[I"))
		} else {
			t.Send([]byte("\x1b[O"))
		}
	}
	if focused {
		c.After(600*time.Millisecond - since%(600*time.Millisecond))
	}
	if dirty && t.opts.OnSearch != nil {
		t.opts.OnSearch(status)
	}
	t.clipboard(c)
	e.Cursor(ui.CursorText)
	e.TextCaret(caret)
	e.HandleInput(t.input)
	e.Draw(t.paint)
	e.ContextMenu(t.menu)
	return e
}
func (t *Terminal) clipboard(c *ui.Context) {
	t.eventMu.Lock()
	events := t.view.pending
	t.view.pending = nil
	t.eventMu.Unlock()
	for _, ev := range events {
		switch ev.kind {
		case C.KERO_EVENT_CLIPBOARD_STORE:
			if !t.opts.NoClipboardWrite {
				s := string(ev.data)
				c.WriteClipboard(s)
				if t.opts.OnCopy != nil {
					t.opts.OnCopy(s, terminal.CopyProgram)
				}
			}
		case C.KERO_EVENT_CLIPBOARD_LOAD:
			if len(ev.data) >= 8 {
				t.view.clipPending = append(t.view.clipPending, clipboardRead{binary.LittleEndian.Uint64(ev.data), len(ev.data) > 8 && ev.data[8] != 0})
			}
		}
	}
	v := &t.view
	for len(v.clipPending) > 0 {
		read := v.clipPending[0]
		allow := t.opts.ClipboardRead == terminal.ClipboardAllow
		if t.opts.ClipboardRead == terminal.ClipboardAsk {
			if !v.clipOpen {
				v.clipOpen = true
			}
			answer := ui.AlertDialog(c, &v.clipOpen, "Clipboard access", "Allow this terminal program to read the clipboard?", "Deny", "Allow")
			if answer == -1 {
				return
			}
			allow = answer > 0
		}
		text := ""
		if allow && !read.primary {
			text = t.services.ReadClipboard()
		}
		t.resolveClipboard(read.id, text, allow)
		v.clipPending = v.clipPending[1:]
	}
}
func (t *Terminal) paint(p *ui.Painter, r ui.Rect) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.h == nil {
		return
	}
	v := &t.view
	f := t.opts.Font
	if f.Family == "" {
		f.Family = "monospace"
	}
	if f.Size <= 0 {
		f.Size = 13
	}
	if f.Weight <= 0 {
		f.Weight = 400
	}
	if f.LineHeight <= 0 {
		f.LineHeight = 1
	}
	v.font = ui.Font{Family: f.Family, Size: f.Size, Weight: f.Weight, Features: strings.Join(f.Features, ","), Thicken: f.Thicken}
	metrics := v.font.Metrics()
	v.cw = 1
	for _, g := range ui.Shape("MW0123456789", v.font) {
		v.cw = max(v.cw, g.Advance)
	}
	scale := p.Scale()
	v.cw = float32(math.Ceil(float64(v.cw*scale))) / scale
	v.ch = float32(math.Ceil(float64((metrics.Ascent+metrics.Descent+metrics.LineGap)*f.LineHeight*scale))) / scale
	v.ch = max(v.ch, 1)
	v.base = (v.ch-metrics.Ascent-metrics.Descent)/2 + metrics.Ascent
	v.ox, v.oy = 6, 4
	if t.opts.Padding != (terminal.Padding{}) {
		v.ox = max(t.opts.Padding.X, 0)
		v.oy = max(t.opts.Padding.Y, 0)
	}
	cols := max(int((r.W-2*v.ox)/v.cw), 1)
	rows := max(int((r.H-2*v.oy)/v.ch), 1)
	cw := max(int(v.cw*scale), 1)
	ch := max(int(v.ch*scale), 1)
	if cols != t.askedCols || rows != t.askedRows || cw != t.askedW || ch != t.askedH {
		t.askedCols, t.askedRows, t.askedW, t.askedH = cols, rows, cw, ch
		if t.conn != nil {
			t.requestControl(controlRequest{size: [4]int{cols, rows, cw, ch}})
		}
		t.cellW, t.cellH = cw, ch
		if !t.opts.ResizeByConn {
			t.cols, t.rows = cols, rows
			C.kero_alacritty_resize(t.h, C.uint16_t(min(cols, 65535)), C.uint16_t(min(rows, 65535)), C.uint16_t(min(cw, 65535)), C.uint16_t(min(ch, 65535)))
		}
	}
	var s C.KeroSnapshot
	C.kero_alacritty_snapshot(t.h, &s)
	v.cursorX = max(int(s.cursor_column), 0)
	v.cursorY = max(int(s.cursor_line), 0)
	v.cursorBlink = bool(s.cursor_blinking)
	cells := append([]C.KeroCell(nil), unsafe.Slice(s.cells, int(s.columns*s.rows))...)
	text := C.GoBytes(unsafe.Pointer(s.text), C.int(s.text_len))
	var ks C.KeroKittySnapshot
	C.kero_alacritty_kitty_snapshot(t.h, &ks)
	images := make([]drawnImage, 0, int(ks.placements_len))
	seen := make(map[uint32]bool)
	for _, im := range unsafe.Slice(ks.placements, int(ks.placements_len)) {
		if im.png == nil || im.png_len == 0 {
			continue
		}
		if v.bitmaps == nil {
			v.bitmaps = make(map[uint32]imageCache)
		}
		id := uint32(im.image_id)
		cached := v.bitmaps[id]
		seen[id] = true
		if cached.bitmap == nil || cached.generation != uint64(im.image_generation) {
			decoded, err := png.Decode(bytes.NewReader(C.GoBytes(unsafe.Pointer(im.png), C.int(im.png_len))))
			if err != nil {
				continue
			}
			cached = imageCache{uint64(im.image_generation), ui.NewBitmap(decoded)}
			v.bitmaps[id] = cached
		}
		src := ui.Rect{X: float32(im.source_x), Y: float32(im.source_y), W: float32(im.source_width), H: float32(im.source_height)}
		dst := ui.Rect{X: r.X + v.ox + float32(im.column)*v.cw + float32(im.x_offset)/scale, Y: r.Y + v.oy + float32(im.viewport_row)*v.ch + float32(im.y_offset)/scale, W: float32(im.display_columns) * v.cw, H: float32(im.display_rows) * v.ch}
		if bool(im.placeholder) {
			src = ui.Rect{X: float32(im.src_x), Y: float32(im.src_y), W: float32(im.src_width), H: float32(im.src_height)}
			dst = ui.Rect{X: r.X + v.ox + (float32(im.column)+float32(im.dst_x))*v.cw, Y: r.Y + v.oy + (float32(im.viewport_row)+float32(im.dst_y))*v.ch, W: float32(im.dst_width) * v.cw, H: float32(im.dst_height) * v.ch}
		}
		images = append(images, drawnImage{cached.bitmap, src, dst, int32(im.z_index)})
	}
	for id := range v.bitmaps {
		if !seen[id] {
			delete(v.bitmaps, id)
		}
	}
	sort.SliceStable(images, func(i, j int) bool { return images[i].z < images[j].z })
	grid := ui.Rect{X: r.X + v.ox, Y: r.Y + v.oy, W: float32(s.columns) * v.cw, H: float32(s.rows) * v.ch}
	drawImages := func(layer int) {
		for _, im := range images {
			level := 2
			if im.z < -(1 << 30) {
				level = 0
			} else if im.z < 0 {
				level = 1
			}
			if level != layer {
				continue
			}
			p.Clip(grid, 0, func() { p.ImageRegion(im.bmp, im.src, im.dst, ui.ImageOptions{}) })
		}
	}
	if !t.opts.Transparent {
		p.Fill(r, color(s.background), 0)
	}
	drawImages(0)
	for y := range int(s.rows) {
		for x := range int(s.columns) {
			cell := cells[y*int(s.columns)+x]
			rect := ui.Rect{X: grid.X + float32(x)*v.cw, Y: grid.Y + float32(y)*v.ch, W: v.cw, H: v.ch}
			bg := color(cell.bg)
			if cell.flags&C.KERO_CELL_INVERSE != 0 {
				bg = color(cell.fg)
			}
			if cell.flags&C.KERO_CELL_SELECTED != 0 {
				bg = v.theme.Selection
				if bg.A == 0 {
					bg = v.theme.Foreground.Alpha(.33)
				}
			}
			if bg != color(s.background) {
				p.Fill(rect, bg, 0)
			}
		}
	}
	drawImages(1)
	for y := range int(s.rows) {
		for x := range int(s.columns) {
			cell := cells[y*int(s.columns)+x]
			flags := uint16(cell.flags)
			cp := rune(cell.ch)
			if cp == ' ' || cp == 0 || cp == 0x10eeee || flags&uint16(C.KERO_CELL_WIDE_SPACER|C.KERO_CELL_HIDDEN) != 0 {
				continue
			}
			str := string(cp)
			off, n := int(cell.text_offset), int(cell.text_len)
			if n > 0 && off >= 0 && off+n <= len(text) {
				str = string(text[off : off+n])
			}
			fg, bg := color(cell.fg), color(cell.bg)
			if flags&uint16(C.KERO_CELL_INVERSE) != 0 {
				fg, bg = bg, fg
			}
			if flags&uint16(C.KERO_CELL_SELECTED) != 0 {
				if v.theme.SelectionText.A != 0 {
					fg = v.theme.SelectionText
				}
				if v.theme.Selection.A != 0 {
					bg = v.theme.Selection
				}
			}
			fg = contrastColor(fg, bg, t.opts.MinimumContrast)
			if flags&uint16(C.KERO_CELL_DIM) != 0 {
				fg = fg.Alpha(.5)
			}
			font := v.font
			if flags&uint16(C.KERO_CELL_BOLD) != 0 {
				font.Weight = min(max(font.Weight+300, 700), 900)
			}
			font.Italic = flags&uint16(C.KERO_CELL_ITALIC) != 0
			px, py := grid.X+float32(x)*v.cw, grid.Y+float32(y)*v.ch
			p.Glyphs(v.shape(str, font), px, py+v.base, fg)
			if flags&uint16(C.KERO_CELL_UNDERLINE) != 0 {
				p.Fill(ui.Rect{X: px, Y: py + v.ch - 1/scale, W: v.cw, H: 1 / scale}, fg, 0)
			}
			if flags&uint16(C.KERO_CELL_STRIKEOUT) != 0 {
				p.Fill(ui.Rect{X: px, Y: py + v.ch/2, W: v.cw, H: 1 / scale}, fg, 0)
			}
		}
	}
	drawImages(2)
	if s.cursor_line >= 0 && s.cursor_column >= 0 && v.cursorVisible {
		cur := ui.Rect{X: grid.X + float32(s.cursor_column)*v.cw, Y: grid.Y + float32(s.cursor_line)*v.ch, W: v.cw, H: v.ch}
		switch s.cursor_shape {
		case 1:
			cur.Y += cur.H - 2/scale
			cur.H = 2 / scale
		case 2:
			cur.W = 2 / scale
		case 3:
			p.Stroke(cur, color(s.cursor_color), 0, 1/scale)
			return
		}
		if !v.focused && s.cursor_shape == 0 {
			p.Stroke(cur, color(s.cursor_color), 0, 1/scale)
		} else {
			p.Fill(cur, color(s.cursor_color).Alpha(.65), 0)
		}
	}
	if v.preedit != "" && s.cursor_line >= 0 && s.cursor_column >= 0 {
		x := grid.X + float32(s.cursor_column)*v.cw
		y := grid.Y + float32(s.cursor_line)*v.ch
		p.Fill(ui.Rect{X: x, Y: y, W: float32(len([]rune(v.preedit))) * v.cw, H: v.ch}, color(s.background), 0)
		p.Glyphs(ui.Shape(v.preedit, v.font), x, y+v.base, color(s.cursor_color))
	}
}
func (t *Terminal) selection() string {
	if t.h == nil {
		return ""
	}
	n := int(C.kero_alacritty_selection_text(t.h, nil, 0))
	if n == 0 {
		return ""
	}
	b := make([]byte, n)
	n = int(C.kero_alacritty_selection_text(t.h, (*C.uint8_t)(unsafe.Pointer(&b[0])), C.size_t(n)))
	return string(b[:min(n, len(b))])
}
func (t *Terminal) copySelection(source terminal.CopySource) {
	t.mu.Lock()
	text := t.selection()
	svc := t.services
	t.mu.Unlock()
	if text != "" {
		svc.WriteClipboard(text)
		if t.opts.OnCopy != nil {
			t.opts.OnCopy(text, source)
		}
	}
}
func (t *Terminal) HoveredLink() (string, bool, ui.Rect) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.view.hovered, false, t.view.hoverRect
}
func (t *Terminal) input(ev ui.InputEvent) bool {
	v := &t.view
	switch ev.Kind {
	case ui.InputText:
		v.preedit = ""
		if v.suppressText {
			v.suppressText = false
			return true
		}
		t.typed(ev.Text)
		return true
	case ui.InputCompose:
		v.preedit = ev.Text
		return true
	case ui.InputKeyDown:
		v.suppressText = false
		if t.opts.OnKey != nil && t.opts.OnKey(ev.Mods, ev.Key) {
			v.suppressText = true
			return true
		}
		if b, ok := t.binding(ev.Mods, ev.Key); ok {
			done := t.action(b.Action)
			if done || !b.Performable {
				v.suppressText = true
				return true
			}
		}
		handled := t.key(ev)
		if handled && ev.Mods&(ui.Ctrl|ui.Alt) != 0 && keyCode(ev.Key) >= 32 && keyCode(ev.Key) < 127 {
			v.suppressText = true
		}
		return handled
	case ui.InputKeyUp:
		return t.key(ev)
	case ui.InputCommand:
		switch ev.Text {
		case "copy":
			t.action(terminal.ActionCopy)
		case "paste":
			t.action(terminal.ActionPaste)
		case "selectAll":
			t.action(terminal.ActionSelectAll)
		default:
			return false
		}
		return true
	case ui.InputPointerDown, ui.InputPointerMove, ui.InputPointerUp:
		t.mu.Lock()
		if t.h == nil || v.cw <= 0 || v.ch <= 0 {
			t.mu.Unlock()
			return false
		}
		x := max(0, min(t.cols-1, int((ev.X-v.ox)/v.cw)))
		y := max(0, min(t.rows-1, int((ev.Y-v.oy)/v.ch)))
		right := (ev.X-v.ox)/v.cw-float32(x) >= .5
		v.pointerX, v.pointerY = ev.X, ev.Y
		mode := uint32(C.kero_alacritty_mode(t.h))
		tracking := mode&uint32(C.KERO_MODE_MOUSE) != 0 && ev.Mods&ui.Shift == 0
		if v.capturedPending {
			dx, dy := ev.X-v.capturedPress.X, ev.Y-v.capturedPress.Y
			if dx*dx+dy*dy >= 16 {
				press := v.capturedPress
				v.capturedPending = false
				px := max(0, min(t.cols-1, int((press.X-v.ox)/v.cw)))
				py := max(0, min(t.rows-1, int((press.Y-v.oy)/v.ch)))
				C.kero_alacritty_selection_start(t.h, C.int32_t(py), C.size_t(px), 0, false)
				v.selecting = true
			} else if ev.Kind == ui.InputPointerUp {
				press := v.capturedPress
				focusOnly := v.capturedFocusOnly
				v.capturedPending = false
				t.mu.Unlock()
				if !focusOnly {
					t.Send([]byte(mouseSequence(mode, press, x, y)))
					t.Send([]byte(mouseSequence(mode, ev, x, y)))
				}
				return true
			} else {
				t.mu.Unlock()
				return true
			}
		}
		if tracking && !v.selecting && t.opts.SelectOnCapturedMouseDrag && ev.Kind == ui.InputPointerDown && ev.Button == 0 && ev.Mods == 0 {
			v.capturedPress = ev
			v.capturedPending = true
			v.capturedFocusOnly = !v.focused
			t.mu.Unlock()
			return true
		}
		if tracking && !v.selecting {
			if report := mouseSequence(mode, ev, x, y); report != "" {
				t.mu.Unlock()
				t.Send([]byte(report))
				return true
			}
			t.mu.Unlock()
			return true
		}
		if ev.Kind == ui.InputPointerDown && ev.Button == 1 {
			rightClick := t.opts.RightClick
			t.mu.Unlock()
			switch rightClick {
			case terminal.RightClickContextMenu:
				return false
			case terminal.RightClickCopy:
				t.action(terminal.ActionCopy)
			case terminal.RightClickCopyOrPaste:
				if !t.action(terminal.ActionCopy) {
					t.action(terminal.ActionPaste)
				}
			case terminal.RightClickPaste:
				t.action(terminal.ActionPaste)
			}
			return true
		}
		if ev.Kind == ui.InputPointerDown && ev.Button == 0 {
			kind := min(max(ev.Clicks-1, 0), 2)
			C.kero_alacritty_selection_start(t.h, C.int32_t(y), C.size_t(x), C.uint32_t(kind), C.bool(right))
			v.selecting = true
		} else if ev.Kind == ui.InputPointerMove && v.selecting {
			C.kero_alacritty_selection_update(t.h, C.int32_t(y), C.size_t(x), C.bool(right))
		} else if ev.Kind == ui.InputPointerUp && v.selecting {
			C.kero_alacritty_selection_update(t.h, C.int32_t(y), C.size_t(x), C.bool(right))
			v.selecting = false
		}
		v.hovered = ""
		v.hoverRect = ui.Rect{}
		var area C.KeroURLRange
		n := int(C.kero_alacritty_url_at(t.h, C.int32_t(y), C.size_t(x), &area, nil, 0))
		if n > 0 {
			b := make([]byte, n)
			n = int(C.kero_alacritty_url_at(t.h, C.int32_t(y), C.size_t(x), &area, (*C.uint8_t)(unsafe.Pointer(&b[0])), C.size_t(n)))
			v.hovered = string(b[:min(n, len(b))])
			v.hoverRect = ui.Rect{X: v.ox + float32(area.start_column)*v.cw, Y: v.oy + float32(area.start_line)*v.ch, W: float32(int(area.end_column)-int(area.start_column)+1) * v.cw, H: v.ch}
		}
		copyNow := ev.Kind == ui.InputPointerUp && t.opts.CopyOnSelect == terminal.CopyOnSelectClipboard
		open := ev.Kind == ui.InputPointerUp && ev.Mods&ui.Super != 0 && v.hovered != ""
		link := v.hovered
		t.mu.Unlock()
		if copyNow {
			t.copySelection(terminal.CopySelect)
		}
		if open {
			if t.opts.OpenLink == nil || !t.opts.OpenLink(link) {
				t.services.OpenURL(link)
			}
		}
		t.invalidate()
		return true
	case ui.InputScroll:
		if ev.Mods&ui.Super != 0 {
			if ev.Precise {
				v.zoom -= ev.DY / 40
			} else if ev.DY < 0 {
				v.zoom++
			} else if ev.DY > 0 {
				v.zoom--
			}
			steps := int(v.zoom)
			v.zoom -= float32(steps)
			for steps > 0 {
				t.action(terminal.ActionIncreaseFontSize)
				steps--
			}
			for steps < 0 {
				t.action(terminal.ActionDecreaseFontSize)
				steps++
			}
			return true
		}
		delta := ev.DY
		t.mu.Lock()
		mode := uint32(0)
		if t.h != nil && v.cw > 0 && v.ch > 0 {
			mode = uint32(C.kero_alacritty_mode(t.h))
			x := max(0, min(t.cols-1, int((ev.X-v.ox)/v.cw)))
			y := max(0, min(t.rows-1, int((ev.Y-v.oy)/v.ch)))
			report := mouseSequence(mode, ev, x, y)
			if report != "" {
				t.mu.Unlock()
				t.Send([]byte(report))
				return true
			}
		}
		if ev.Precise {
			m := t.opts.ScrollMultiplier.Precision
			if m <= 0 {
				m = 1
			}
			delta = delta * m / max(v.ch, 1)
		} else {
			m := t.opts.ScrollMultiplier.Discrete
			if m <= 0 {
				m = 3
			}
			if delta > 0 {
				delta = m
			} else if delta < 0 {
				delta = -m
			}
		}
		v.scroll += delta
		rows := int(v.scroll)
		v.scroll -= float32(rows)
		t.mu.Unlock()
		if rows != 0 && (t.opts.OnScroll == nil || !t.opts.OnScroll(rows)) {
			if mode&uint32(C.KERO_MODE_ALT_SCREEN|C.KERO_MODE_ALTERNATE_SCROLL) == uint32(C.KERO_MODE_ALT_SCREEN|C.KERO_MODE_ALTERNATE_SCROLL) && ev.Mods&ui.Shift == 0 {
				key := "\x1b[A"
				if rows > 0 {
					key = "\x1b[B"
				}
				if mode&uint32(C.KERO_MODE_APP_CURSOR) != 0 {
					key = "\x1bO" + key[2:]
				}
				if rows < 0 {
					rows = -rows
				}
				t.Send([]byte(strings.Repeat(key, rows)))
			} else {
				t.mu.Lock()
				if t.h != nil {
					C.kero_alacritty_scroll(t.h, C.int32_t(-rows))
				}
				t.mu.Unlock()
				t.invalidate()
			}
		}
		return true
	}
	return false
}
