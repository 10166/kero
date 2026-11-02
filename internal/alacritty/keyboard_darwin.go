//go:build darwin && cgo

package alacritty

/*
#include "kero_alacritty.h"
*/
import "C"

import (
	"fmt"
	"github.com/egoist/mygo/ui"
	"strings"
)

func (t *Terminal) mode() uint32 {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.h == nil {
		return 0
	}
	return uint32(C.kero_alacritty_mode(t.h))
}
func keyCode(k ui.Key) int {
	if k >= ui.KeyA && k <= ui.KeyZ {
		return int('a') + int(k-ui.KeyA)
	}
	if k >= ui.Key0 && k <= ui.Key9 {
		return int('0') + int(k-ui.Key0)
	}
	switch k {
	case ui.KeyEnter:
		return 13
	case ui.KeyEscape:
		return 27
	case ui.KeyBackspace:
		return 127
	case ui.KeyTab:
		return 9
	case ui.KeySpace:
		return 32
	case ui.KeyInsert:
		return 57348
	case ui.KeyDelete:
		return 57349
	case ui.KeyLeft:
		return 57350
	case ui.KeyRight:
		return 57351
	case ui.KeyUp:
		return 57352
	case ui.KeyDown:
		return 57353
	case ui.KeyPageUp:
		return 57354
	case ui.KeyPageDown:
		return 57355
	case ui.KeyHome:
		return 57358
	case ui.KeyEnd:
		return 57359
	case ui.KeyMinus:
		return '-'
	case ui.KeyEqual:
		return '='
	case ui.KeyComma:
		return ','
	case ui.KeyPeriod:
		return '.'
	case ui.KeySlash:
		return '/'
	case ui.KeySemicolon:
		return ';'
	case ui.KeyQuote:
		return '\''
	case ui.KeyBracketLeft:
		return '['
	case ui.KeyBracketRight:
		return ']'
	case ui.KeyBackslash:
		return '\\'
	case ui.KeyBackquote:
		return '`'
	}
	if k >= ui.KeyF1 && k <= ui.KeyF12 {
		return 57364 + int(k-ui.KeyF1)
	}
	return 0
}
func modifierCode(mods ui.Modifiers) int {
	n := 1
	if mods&ui.Shift != 0 {
		n++
	}
	if mods&ui.Alt != 0 {
		n += 2
	}
	if mods&ui.Ctrl != 0 {
		n += 4
	}
	if mods&ui.Super != 0 {
		n += 8
	}
	return n
}
func shiftedCode(code int, mods ui.Modifiers) int {
	if mods&ui.Shift == 0 {
		return code
	}
	if code >= 'a' && code <= 'z' {
		return code - 'a' + 'A'
	}
	const from = "1234567890-=[]\\;',./`"
	const to = "!@#$%^&*()_+{}|:\"<>?~"
	if i := strings.IndexRune(from, rune(code)); i >= 0 {
		return int(to[i])
	}
	return code
}
func kittyKey(code int, mods ui.Modifiers, event int, flags uint32) string {
	m := modifierCode(mods)
	if flags&2 != 0 {
		return fmt.Sprintf("\x1b[%d;%d:%du", code, m, event)
	}
	if m != 1 {
		return fmt.Sprintf("\x1b[%d;%du", code, m)
	}
	return fmt.Sprintf("\x1b[%du", code)
}
func kittySpecial(k ui.Key, mods ui.Modifiers, event int, flags uint32) string {
	final := ""
	number := 0
	switch k {
	case ui.KeyUp:
		final = "A"
	case ui.KeyDown:
		final = "B"
	case ui.KeyRight:
		final = "C"
	case ui.KeyLeft:
		final = "D"
	case ui.KeyHome:
		final = "H"
	case ui.KeyEnd:
		final = "F"
	case ui.KeyF1:
		final = "P"
	case ui.KeyF2:
		final = "Q"
	case ui.KeyF3:
		final = "R"
	case ui.KeyF4:
		final = "S"
	case ui.KeyInsert:
		number = 2
	case ui.KeyDelete:
		number = 3
	case ui.KeyPageUp:
		number = 5
	case ui.KeyPageDown:
		number = 6
	case ui.KeyF5:
		number = 15
	case ui.KeyF6:
		number = 17
	case ui.KeyF7:
		number = 18
	case ui.KeyF8:
		number = 19
	case ui.KeyF9:
		number = 20
	case ui.KeyF10:
		number = 21
	case ui.KeyF11:
		number = 23
	case ui.KeyF12:
		number = 24
	default:
		return ""
	}
	mod := fmt.Sprint(modifierCode(mods))
	if flags&2 != 0 {
		mod += fmt.Sprintf(":%d", event)
	}
	if final != "" {
		return fmt.Sprintf("\x1b[1;%s%s", mod, final)
	}
	return fmt.Sprintf("\x1b[%d;%s~", number, mod)
}
func (t *Terminal) key(ev ui.InputEvent) bool {
	mode := t.mode()
	flags := (mode >> 11) & 31
	code := keyCode(ev.Key)
	if code == 0 {
		return false
	}
	if ev.Kind == ui.InputKeyUp {
		reported := t.view.reportedKeys[ev.Key]
		delete(t.view.reportedKeys, ev.Key)
		if flags&2 != 0 && reported {
			seq := kittySpecial(ev.Key, ev.Mods, 3, flags)
			if seq == "" {
				seq = kittyKey(shiftedCode(code, ev.Mods), ev.Mods, 3, flags)
			}
			t.Send([]byte(seq))
			return true
		}
		return false
	}
	if ev.Mods&ui.Super != 0 {
		return false
	}
	if flags != 0 && (flags&8 != 0 || ev.Mods&(ui.Ctrl|ui.Alt) != 0 || code >= 57344 || ev.Key == ui.KeyEscape) {
		if flags&2 != 0 {
			if t.view.reportedKeys == nil {
				t.view.reportedKeys = make(map[ui.Key]bool)
			}
			t.view.reportedKeys[ev.Key] = true
		}
		if code >= 32 && code < 127 && ev.Mods&(ui.Ctrl|ui.Alt) == 0 {
			t.view.keyMods = ev.Mods
			t.view.keyCode = code
			t.view.keyRepeat = ev.Repeat
			return true
		}
		event := 1
		if ev.Repeat {
			event = 2
		}
		seq := kittySpecial(ev.Key, ev.Mods, event, flags)
		if seq == "" {
			seq = kittyKey(shiftedCode(code, ev.Mods), ev.Mods, event, flags)
		}
		t.Send([]byte(seq))
		return true
	}
	if (mode>>16)&3 == 2 && code < 127 && ev.Mods&(ui.Ctrl|ui.Alt) != 0 {
		t.Send([]byte(fmt.Sprintf("\x1b[27;%d;%d~", modifierCode(ev.Mods), shiftedCode(code, ev.Mods))))
		return true
	}
	if ev.Mods&ui.Ctrl != 0 && ev.Key >= ui.KeyA && ev.Key <= ui.KeyZ {
		t.Send([]byte{byte(ev.Key - ui.KeyA + 1)})
		return true
	}
	if ev.Mods&ui.Alt != 0 && t.opts.OptionAsAlt && code >= 32 && code < 127 {
		t.Send([]byte{27, byte(code)})
		return true
	}
	seq := ""
	switch ev.Key {
	case ui.KeyEnter:
		seq = "\r"
	case ui.KeyTab:
		if ev.Mods&ui.Shift != 0 {
			seq = "\x1b[Z"
		} else {
			seq = "\t"
		}
	case ui.KeyEscape:
		seq = "\x1b"
	case ui.KeyBackspace:
		seq = "\x7f"
	case ui.KeyDelete:
		seq = "\x1b[3~"
	case ui.KeyInsert:
		seq = "\x1b[2~"
	case ui.KeyHome:
		seq = "\x1b[H"
	case ui.KeyEnd:
		seq = "\x1b[F"
	case ui.KeyPageUp:
		seq = "\x1b[5~"
	case ui.KeyPageDown:
		seq = "\x1b[6~"
	case ui.KeyUp:
		seq = "\x1b[A"
	case ui.KeyDown:
		seq = "\x1b[B"
	case ui.KeyRight:
		seq = "\x1b[C"
	case ui.KeyLeft:
		seq = "\x1b[D"
	case ui.KeyF1:
		seq = "\x1bOP"
	case ui.KeyF2:
		seq = "\x1bOQ"
	case ui.KeyF3:
		seq = "\x1bOR"
	case ui.KeyF4:
		seq = "\x1bOS"
	case ui.KeyF5:
		seq = "\x1b[15~"
	case ui.KeyF6:
		seq = "\x1b[17~"
	case ui.KeyF7:
		seq = "\x1b[18~"
	case ui.KeyF8:
		seq = "\x1b[19~"
	case ui.KeyF9:
		seq = "\x1b[20~"
	case ui.KeyF10:
		seq = "\x1b[21~"
	case ui.KeyF11:
		seq = "\x1b[23~"
	case ui.KeyF12:
		seq = "\x1b[24~"
	}
	if len(seq) == 3 && strings.HasPrefix(seq, "\x1b[") && strings.ContainsRune("ABCDHF", rune(seq[2])) {
		if m := modifierCode(ev.Mods); m != 1 {
			seq = fmt.Sprintf("\x1b[1;%d%c", m, seq[2])
		} else if mode&uint32(C.KERO_MODE_APP_CURSOR) != 0 {
			seq = "\x1bO" + seq[2:]
		}
	}
	if seq != "" {
		t.Send([]byte(seq))
		return true
	}
	return false
}
func (t *Terminal) typed(text string) {
	flags := (t.mode() >> 11) & 31
	if flags&8 == 0 {
		t.Send([]byte(text))
		return
	}
	var out strings.Builder
	for _, r := range text {
		code := fmt.Sprint(int(r))
		if flags&4 != 0 && t.view.keyCode != 0 && t.view.keyCode != int(r) {
			code += fmt.Sprintf(":%d", t.view.keyCode)
		}
		mod := fmt.Sprint(modifierCode(t.view.keyMods))
		if flags&2 != 0 {
			event := 1
			if t.view.keyRepeat {
				event = 2
			}
			mod += fmt.Sprintf(":%d", event)
		}
		if flags&16 != 0 {
			out.WriteString(fmt.Sprintf("\x1b[%s;%s;%du", code, mod, r))
		} else {
			out.WriteString(fmt.Sprintf("\x1b[%s;%su", code, mod))
		}
	}
	t.view.keyCode = 0
	t.Send([]byte(out.String()))
}
