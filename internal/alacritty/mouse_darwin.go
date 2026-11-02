//go:build darwin && cgo

package alacritty

/*
#include "kero_alacritty.h"
*/
import "C"

import (
	"fmt"
	"github.com/egoist/mygo/ui"
)

func mouseSequence(mode uint32, ev ui.InputEvent, x, y int) string {
	if mode&uint32(C.KERO_MODE_MOUSE) == 0 || ev.Mods&ui.Shift != 0 {
		return ""
	}
	button := ev.Button
	switch button {
	case 0:
		button = 0
	case 1:
		button = 2
	case 2:
		button = 1
	default:
		button = 3
	}
	release := ev.Kind == ui.InputPointerUp
	if ev.Kind == ui.InputPointerMove {
		if mode&uint32(C.KERO_MODE_MOUSE_MOTION) == 0 && (mode&uint32(C.KERO_MODE_MOUSE_DRAG) == 0 || ev.Button < 0) {
			return ""
		}
		button += 32
	}
	if ev.Kind == ui.InputScroll {
		if ev.DY < 0 {
			button = 64
		} else {
			button = 65
		}
		release = false
	}
	if ev.Mods&ui.Shift != 0 {
		button += 4
	}
	if ev.Mods&ui.Alt != 0 {
		button += 8
	}
	if ev.Mods&ui.Ctrl != 0 {
		button += 16
	}
	if mode&uint32(C.KERO_MODE_SGR_MOUSE) != 0 {
		suffix := "M"
		if release {
			suffix = "m"
		}
		return fmt.Sprintf("\x1b[<%d;%d;%d%s", button, x+1, y+1, suffix)
	}
	if release {
		button = 3
	}
	if x >= 223 || y >= 223 {
		return ""
	}
	return string([]byte{27, '[', 'M', byte(button + 32), byte(x + 33), byte(y + 33)})
}
