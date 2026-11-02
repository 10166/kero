//go:build darwin && cgo

package main

import (
	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"
	"kero/internal/alacritty"
)

const alacrittyAvailable = true

func newAlacrittySurface(options terminal.Options) (terminalSurface, error) {
	return alacritty.New(options)
}
func alacrittySurfaceView(c *ui.Context, surface terminalSurface) ui.Element {
	return alacritty.View(c, surface.(*alacritty.Terminal))
}
