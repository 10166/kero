//go:build darwin && cgo

package alacritty

/*
#include "kero_alacritty.h"
*/
import "C"

import (
	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/transfer"
	"github.com/egoist/mygo/ui"
)

func (t *Terminal) binding(mods ui.Modifiers, key ui.Key) (terminal.Keybind, bool) {
	for i := len(t.opts.Keybinds) - 1; i >= 0; i-- {
		b := t.opts.Keybinds[i]
		if b.Mods == mods && b.Key == key {
			return b, b.Action != terminal.ActionNone
		}
	}
	if !t.opts.NoDefaultKeybinds {
		for _, b := range terminal.DefaultKeybinds() {
			if b.Mods == mods && b.Key == key {
				return b, true
			}
		}
	}
	return terminal.Keybind{}, false
}
func (t *Terminal) action(a terminal.Action) bool {
	switch a {
	case terminal.ActionIgnore:
		return true
	case terminal.ActionCopy:
		t.mu.Lock()
		selected := t.selection() != ""
		t.mu.Unlock()
		if selected {
			t.copySelection(terminal.CopyUser)
		}
		return selected
	case terminal.ActionPaste:
		d := t.services.ReadClipboardData(transfer.Text, transfer.PNG, transfer.FileList)
		if t.opts.OnPaste == nil || !t.opts.OnPaste(d) {
			t.PasteData(d)
		}
		return true
	case terminal.ActionSelectAll:
		t.mu.Lock()
		if t.h != nil {
			C.kero_alacritty_select_all(t.h)
		}
		copyNow := t.opts.CopyOnSelect == terminal.CopyOnSelectClipboard
		t.mu.Unlock()
		if copyNow {
			t.copySelection(terminal.CopySelect)
		}
		t.invalidate()
		return true
	case terminal.ActionClearScreen:
		if t.mode()&uint32(C.KERO_MODE_ALT_SCREEN) != 0 {
			return false
		}
		if t.opts.OnClear == nil || !t.opts.OnClear(terminal.ClearScreen) {
			t.mu.Lock()
			if t.h != nil {
				C.kero_alacritty_clear(t.h)
			}
			t.mu.Unlock()
			t.invalidate()
		}
		return true
	case terminal.ActionIncreaseFontSize, terminal.ActionDecreaseFontSize, terminal.ActionResetFontSize:
		z := terminal.Zoom{}
		if a == terminal.ActionIncreaseFontSize {
			z.Steps = 1
		} else if a == terminal.ActionDecreaseFontSize {
			z.Steps = -1
		} else {
			z.Reset = true
		}
		if t.opts.OnZoom == nil || !t.opts.OnZoom(z) {
			t.mu.Lock()
			if t.opts.Font.Size <= 0 {
				t.opts.Font.Size = 13
			}
			if z.Reset {
				t.opts.Font.Size = 13
			} else {
				t.opts.Font.Size = max(1, t.opts.Font.Size+float32(z.Steps))
			}
			t.mu.Unlock()
			t.invalidate()
		}
		return true
	case terminal.ActionScrollPageUp, terminal.ActionScrollPageDown, terminal.ActionScrollToTop, terminal.ActionScrollToBottom:
		t.mu.Lock()
		if t.h == nil || uint32(C.kero_alacritty_mode(t.h))&uint32(C.KERO_MODE_ALT_SCREEN) != 0 {
			t.mu.Unlock()
			return false
		}
		switch a {
		case terminal.ActionScrollPageUp:
			C.kero_alacritty_scroll(t.h, C.int32_t(max(t.rows-1, 1)))
		case terminal.ActionScrollPageDown:
			C.kero_alacritty_scroll(t.h, C.int32_t(-max(t.rows-1, 1)))
		case terminal.ActionScrollToTop:
			C.kero_alacritty_scroll(t.h, 2147483647)
		case terminal.ActionScrollToBottom:
			C.kero_alacritty_scroll_to_offset(t.h, 0)
		}
		t.mu.Unlock()
		t.invalidate()
		return true
	}
	return false
}
func (t *Terminal) menu(m *ui.Menu) {
	if m.Item("Copy").Chosen() {
		t.action(terminal.ActionCopy)
	}
	if m.Item("Paste").Chosen() {
		t.action(terminal.ActionPaste)
	}
	if m.Item("Select All").Chosen() {
		t.action(terminal.ActionSelectAll)
	}
	m.Separator()
	if m.Item("Clear").Chosen() {
		t.action(terminal.ActionClearScreen)
	}
}
