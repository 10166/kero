package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"runtime"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
	"kero/internal/remote"
	"kero/locales"
)

// sshPromptState is owned by the UI thread. Each queued request has its own
// buffered result channel so cancellation never blocks a later dialog.
type sshPromptState struct{ queue []*sshPromptRequest }

func (s *sshPromptState) active() bool { return len(s.queue) != 0 }

type sshPromptRequest struct {
	ctx       context.Context
	challenge remote.SSHChallenge
	open      bool
	value     string
	remember  bool
	saved     bool
	edited    bool
	result    chan sshPromptResult
}
type sshPromptResult struct {
	answer remote.SSHAnswer
	err    error
}

func sshCredentialKey(c remote.SSHChallenge) string {
	sum := sha256.Sum256([]byte(string(c.Kind) + "\x00" + c.Address.String() + "\x00" + c.Message))
	return fmt.Sprintf("ssh-%x", sum)
}
func sshMayRemember(c remote.SSHChallenge) bool {
	return runtime.GOOS == "darwin" && (c.Kind == remote.SSHPassword || c.Kind == remote.SSHPassphrase)
}

// sshPrompt may be called concurrently by OpenSSH helpers, including those of
// jump hosts. All state presented by sshDialog is changed on the UI thread.
func (a *App) sshPrompt(ctx context.Context, challenge remote.SSHChallenge) (remote.SSHAnswer, error) {
	if err := ctx.Err(); err != nil {
		return remote.SSHAnswer{}, err
	}
	if a.win == nil {
		return remote.SSHAnswer{}, fmt.Errorf("SSH prompt has no application window")
	}
	r := &sshPromptRequest{ctx: ctx, challenge: challenge, open: true, result: make(chan sshPromptResult, 1)}
	a.update(func() {
		if r.ctx.Err() != nil {
			return
		}
		a.sshAuth.queue = append(a.sshAuth.queue, r)
		a.showWindow()
	})
	if sshMayRemember(challenge) {
		// Keychain may show its own authorization UI; never block the SSH
		// dialog or its cancellation while the system answers.
		go func() {
			value, err := mygo.Secrets.Get(sshCredentialKey(challenge))
			if err != nil {
				return
			}
			a.update(func() {
				for _, pending := range a.sshAuth.queue {
					if pending == r && r.ctx.Err() == nil && !r.edited {
						r.value, r.saved = string(value), true
						break
					}
				}
			})
		}()
	}
	select {
	case result := <-r.result:
		if err := ctx.Err(); err != nil {
			return remote.SSHAnswer{}, err
		}
		if result.err != nil {
			return remote.SSHAnswer{}, result.err
		}
		if result.answer.Remember && sshMayRemember(challenge) {
			done := make(chan error, 1)
			go func() { done <- mygo.Secrets.Set(sshCredentialKey(challenge), []byte(result.answer.Text)) }()
			select {
			case err := <-done:
				if err != nil {
					a.update(func() { a.toast(locales.SshKeychainSaveFailed()) })
				}
			case <-ctx.Done():
				return remote.SSHAnswer{}, ctx.Err()
			}
		}
		return result.answer, nil
	case <-ctx.Done():
		a.update(func() { a.removeSSHPrompt(r) })
		return remote.SSHAnswer{}, ctx.Err()
	}
}

func (a *App) removeSSHPrompt(r *sshPromptRequest) {
	for i, item := range a.sshAuth.queue {
		if item == r {
			copy(a.sshAuth.queue[i:], a.sshAuth.queue[i+1:])
			a.sshAuth.queue[len(a.sshAuth.queue)-1] = nil
			a.sshAuth.queue = a.sshAuth.queue[:len(a.sshAuth.queue)-1]
			r.value = ""
			return
		}
	}
}

// cancelSSHPrompts is called on the UI thread when the window or app closes.
func (a *App) cancelSSHPrompts() {
	for _, h := range a.hosts {
		if h.dialCancel != nil {
			h.dialCancel()
			h.dialCancel = nil
		}
		if h.installCancel != nil {
			h.installCancel()
			h.installCancel = nil
		}
	}
	for _, r := range a.sshAuth.queue {
		r.value = ""
		select {
		case r.result <- sshPromptResult{err: context.Canceled}:
		default:
		}
	}
	a.sshAuth.queue = nil
}

func (a *App) sshDialog(c *ui.Context, pal *palette) {
	if !a.sshAuth.active() {
		return
	}
	r := a.sshAuth.queue[0]
	challenge := r.challenge
	title := locales.SshAuthentication()
	confirmation := challenge.Kind == remote.SSHHostKey || challenge.Kind == remote.SSHConfirmation
	if challenge.Kind == remote.SSHHostKey {
		title = locales.SshVerifyHostKey()
	}
	if challenge.Kind == remote.SSHNotice {
		title = locales.SshConnection()
	}
	var submit, reject bool
	ui.DialogBase(c.Key("ssh-auth"), &r.open, func(backdrop, panel ui.Element) {
		backdrop.Background(pal.overlay)
		floating(panel.Width(480).Padding(22).Gap(8).Radius(14).Background(pal.popover), pal).Label(title)
		ui.Text(c, title).FontSize(15).FontWeight(650).TextColor(pal.text)
		ui.Text(c, challenge.Message).FontSize(13).TextColor(pal.textMuted).LineHeight(1.4)
		if challenge.Kind == remote.SSHHostKey {
			ui.Text(c, locales.SshFingerprint(challenge.Fingerprint)).FontSize(13).TextColor(pal.text)
		}
		if !confirmation && challenge.Kind != remote.SSHNotice {
			var input ui.Element
			frame := ui.Row(c.Key("ssh-secret-frame"))
			frame.Children(func() {
				input = ui.TextInputBase(c.Key(fmt.Sprintf("ssh-secret-%p", r)), &r.value).Password().AutoFocus().Grow(1).MinWidth(0).AlignSelf(ui.Stretch).Padding(0, 8).FontSize(13).Label(locales.SshResponse())
				if input.Changed() {
					r.edited = true
					r.saved = false
				}
			})
			field(c, frame, input.Focused(), pal).Padding(0)
			if r.saved {
				ui.Text(c, locales.SshSavedCredential()).FontSize(12).TextColor(pal.textMuted)
			}
			if sshMayRemember(challenge) {
				ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
					toggle(c.Key("ssh-remember"), &r.remember, pal)
					ui.Text(c, locales.SshSaveInKeychain()).FontSize(13).TextColor(pal.text)
				})
			}
		}
		ui.Row(c).Gap(8).Justify(ui.End).Margin(14, 0, 0, 0).Children(func() {
			if button(c, "ssh-cancel", locales.CommonCancel(), "esc", false, pal) {
				r.open = false
			}
			if confirmation && button(c, "ssh-reject", locales.SshReject(), "", false, pal) {
				reject = true
			}
			label := locales.SshContinue()
			if challenge.Kind == remote.SSHHostKey {
				label = locales.SshTrustAndContinue()
			}
			if defaultButton(c, "ssh-submit", label, "↩", true, pal) || c.Shortcut(0, ui.KeyEnter) {
				submit = true
			}
		})
	})
	if !r.open || reject || submit {
		result := sshPromptResult{}
		if !r.open {
			result.err = context.Canceled
		} else if !reject {
			result.answer = remote.SSHAnswer{Text: r.value, Accept: true, Remember: r.remember}
		}
		a.removeSSHPrompt(r)
		select {
		case r.result <- result:
		default:
		}
		if !a.sshAuth.active() {
			a.focusTerminal()
		}
	}
}
