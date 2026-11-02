package main

import (
	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"
)

// terminalSurface is the behavior Kero uses from either emulator. The daemon
// owns the PTY and its screen; the selected surface displays that stream.
type terminalSurface interface {
	Close() error
	Done() <-chan struct{}
	Resize(int, int)
	Send([]byte)
	Paste(string)
	Search(string)
	SearchNext()
	SearchPrevious()
	EndSearch()
	SearchStatus() terminal.SearchStatus
	HoveredLink() (string, bool, ui.Rect)
	SetFont(terminal.Font)
	SetTheme(*terminal.Theme, *terminal.Theme)
	SetMinimumContrast(float32)
	SetScrollMultiplier(terminal.ScrollMultiplier)
	SetCopyOnSelect(terminal.CopyOnSelect)
}

func newTerminalSurface(backend string, options terminal.Options) (terminalSurface, error) {
	if backend == "alacritty" {
		return newAlacrittySurface(options)
	}
	return terminal.New(options)
}

func terminalSurfaceView(c *ui.Context, surface terminalSurface) ui.Element {
	if t, ok := surface.(*terminal.Terminal); ok {
		return terminal.View(c, t)
	}
	return alacrittySurfaceView(c, surface)
}
