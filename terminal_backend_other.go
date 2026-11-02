//go:build !darwin || !cgo

package main

import (
	"errors"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"
)

const alacrittyAvailable = false

func newAlacrittySurface(terminal.Options) (terminalSurface, error) {
	return nil, errors.New("the Alacritty terminal backend requires a macOS build with cgo")
}
func alacrittySurfaceView(*ui.Context, terminalSurface) ui.Element { panic("unknown terminal surface") }
