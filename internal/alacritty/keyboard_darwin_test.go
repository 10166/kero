//go:build darwin && cgo

package alacritty

import (
	"io"
	"net"
	"runtime"
	"testing"
	"time"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"
)

func TestControlKeysFollowMirroredModifyOtherKeys(t *testing.T) {
	for _, tc := range []struct {
		name, mode, want string
		level            uint32
	}{
		{"default", "", "\x03", 0},
		{"legacy", "\x1b[>4;1m", "\x03", 1},
		{"extended", "\x1b[>4;2m", "\x1b[27;5;99~", 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			local, peer := net.Pipe()
			defer peer.Close()
			term, err := New(terminal.Options{Conn: local})
			if err != nil {
				t.Fatal(err)
			}
			defer term.Close()
			if tc.mode != "" {
				if _, err := peer.Write([]byte(tc.mode)); err != nil {
					t.Fatal(err)
				}
			}
			deadline := time.Now().Add(2 * time.Second)
			for (term.mode()>>16)&3 != tc.level {
				if time.Now().After(deadline) {
					t.Fatal("terminal did not apply keyboard mode")
				}
				runtime.Gosched()
			}
			if !term.key(ui.InputEvent{Kind: ui.InputKeyDown, Key: ui.KeyC, Mods: ui.Ctrl}) {
				t.Fatal("Ctrl+C was not handled")
			}
			if err := peer.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
				t.Fatal(err)
			}
			got := make([]byte, len(tc.want))
			if _, err := io.ReadFull(peer, got); err != nil {
				t.Fatal(err)
			}
			if string(got) != tc.want {
				t.Fatalf("Ctrl+C sent %q, want %q", got, tc.want)
			}
		})
	}
}
