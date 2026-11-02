//go:build darwin && cgo

package alacritty

import (
	"github.com/egoist/mygo/ui"
	"math"
)

func luminance(c ui.Color) float64 {
	f := func(v uint8) float64 {
		x := float64(v) / 255
		if x <= .04045 {
			return x / 12.92
		}
		return math.Pow((x+.055)/1.055, 2.4)
	}
	return .2126*f(c.R) + .7152*f(c.G) + .0722*f(c.B)
}
func contrastRatio(a, b float64) float64 {
	if a < b {
		a, b = b, a
	}
	return (a + .05) / (b + .05)
}
func contrastColor(fg, bg ui.Color, ratio float32) ui.Color {
	if ratio <= 1 || contrastRatio(luminance(fg), luminance(bg)) >= float64(ratio) {
		return fg
	}
	target := ui.RGB(0, 0, 0)
	if contrastRatio(1, luminance(bg)) > contrastRatio(0, luminance(bg)) {
		target = ui.RGB(255, 255, 255)
	}
	lo, hi := float32(0), float32(1)
	for range 8 {
		mid := (lo + hi) / 2
		if contrastRatio(luminance(fg.Mix(target, mid)), luminance(bg)) >= float64(ratio) {
			hi = mid
		} else {
			lo = mid
		}
	}
	return fg.Mix(target, hi)
}
