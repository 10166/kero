package main

import (
	"context"
	"errors"
	"net/url"
	"os"
	"strings"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"kero/internal/relay"
	"kero/internal/relaybridge"
	"kero/internal/settings"
	"kero/locales"
)

// Keep the development identity separate: a relay device can have only one
// live socket, and the installed app may be running alongside this build.
type relayCredentials struct{}

func relayCredentialService() string {
	if mygo.IsDev() {
		return "sh.kero.dev.remote"
	}
	return "sh.kero.remote"
}
func (relayCredentials) Get(key string) ([]byte, error) {
	data, err := mygo.Secrets.Service(relayCredentialService()).Get(key)
	if errors.Is(err, mygo.ErrSecretNotFound) {
		return nil, relay.ErrCredentialNotFound
	}
	return data, err
}
func (relayCredentials) Set(key string, value []byte) error {
	return mygo.Secrets.Service(relayCredentialService()).Set(key, value)
}
func (relayCredentials) Delete(key string) error {
	return mygo.Secrets.Service(relayCredentialService()).Delete(key)
}

// relayUI is owned by the UI thread. Network and credential operations report
// their results through update, guarded by generation and a cancelled context.
type relayUI struct {
	service              *relaybridge.Service
	client               *relay.Client
	identity             *relay.Identity
	cancel               context.CancelFunc
	ctx                  context.Context
	generation           uint64
	signedIn, busy       bool
	verifier, draft, err string
	devices              []relay.Device
}

func (a *App) startRelay() {
	r := &a.relay
	r.generation++
	generation := r.generation
	r.draft = a.set.RelayURL
	r.err = ""
	if strings.TrimSpace(a.set.RelayURL) == "" {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	r.ctx, r.cancel = ctx, cancel
	client, err := relay.NewClient(strings.TrimSpace(a.set.RelayURL), relayCredentials{}, nil)
	if err != nil {
		r.err = err.Error()
		return
	}
	r.client = client
	r.busy = true
	go func() {
		identity, err := relay.LoadOrCreateIdentity(relayCredentials{})
		signedIn := false
		if err == nil {
			_, err = client.Tokens()
			if errors.Is(err, relay.ErrCredentialNotFound) {
				err = nil
			} else if err == nil {
				signedIn = true
			}
		}
		a.update(func() {
			if a.relay.generation != generation || ctx.Err() != nil {
				return
			}
			r.busy = false
			if err != nil {
				r.err = err.Error()
				return
			}
			r.identity, r.signedIn = identity, signedIn
			if signedIn {
				a.runRelay()
			}
		})
	}()
}

func (a *App) runRelay() {
	r := &a.relay
	name, _ := os.Hostname()
	if name == "" {
		name = "Kero"
	}
	svc := relaybridge.New(r.client, r.identity, a.makeRelayBackend(r.identity.ID), name)
	r.service = svc
	svc.SetHostEnabled(a.set.RelayHostEnabled)
	ctx, generation := r.ctx, r.generation
	go func() { _ = svc.Run(ctx) }()
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case <-svc.Changes():
				hosts := svc.Hosts()
				a.update(func() {
					if a.relay.generation == generation && a.relay.service == svc {
						a.relayHostsChanged(hosts)
					}
				})
			}
		}
	}()
	a.refreshRelayDevices()
}

func (a *App) stopRelay() {
	r := &a.relay
	r.generation++
	if r.cancel != nil {
		r.cancel()
	}
	r.cancel, r.ctx, r.service, r.client, r.identity = nil, nil, nil, nil, nil
	r.verifier, r.err = "", ""
	r.signedIn, r.busy = false, false
	r.devices = nil
	a.relayHostsChanged(nil)
}

func (a *App) relaySettingsChanged(old settings.Settings) {
	if old.RelayURL != a.set.RelayURL {
		a.stopRelay()
		a.startRelay()
	} else if old.RelayHostEnabled != a.set.RelayHostEnabled && a.relay.service != nil {
		a.relay.service.SetHostEnabled(a.set.RelayHostEnabled)
	}
}

func (a *App) relaySignIn() {
	r := &a.relay
	if r.client == nil || r.identity == nil || r.busy {
		return
	}
	browserURL, verifier, err := r.client.BeginSignIn()
	if err != nil {
		r.err = err.Error()
		return
	}
	r.verifier, r.err = verifier, ""
	generation := r.generation
	go func() {
		err := mygo.Shell.OpenExternal(browserURL)
		if err != nil {
			a.update(func() {
				if a.relay.generation == generation && a.relay.verifier == verifier {
					a.relay.verifier = ""
					a.relay.err = err.Error()
				}
			})
		}
	}()
}

func (a *App) relayOpenedURL(raw string) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "kero" || u.Host != "remote-auth" {
		return
	}
	r := &a.relay
	if r.verifier == "" || r.client == nil || r.identity == nil || r.busy {
		r.err = locales.RelayCallbackError()
		return
	}
	client, identity, verifier, ctx, generation := r.client, r.identity, r.verifier, r.ctx, r.generation
	r.verifier, r.busy, r.err = "", true, ""
	go func() {
		_, err := client.Exchange(ctx, raw, verifier, identity)
		a.update(func() {
			if a.relay.generation != generation || ctx.Err() != nil {
				return
			}
			r.busy = false
			if err != nil {
				r.err = err.Error()
				return
			}
			r.signedIn = true
			a.runRelay()
		})
	}()
}

func (a *App) relaySignOut() {
	r := &a.relay
	if r.client == nil {
		return
	}
	client := r.client
	a.stopRelay()
	generation := r.generation
	r.busy = true
	go func() {
		err := client.SignOut()
		a.update(func() {
			if a.relay.generation != generation {
				return
			}
			if err != nil {
				r.busy = false
				r.err = err.Error()
				return
			}
			a.startRelay()
		})
	}()
}

func (a *App) refreshRelayDevices() {
	r := &a.relay
	if !r.signedIn || r.client == nil || r.busy {
		return
	}
	client, ctx, generation := r.client, r.ctx, r.generation
	r.busy = true
	go func() {
		devices, err := client.Devices(ctx)
		a.update(func() {
			if a.relay.generation != generation || ctx.Err() != nil {
				return
			}
			r.busy = false
			if err != nil {
				r.err = err.Error()
				return
			}
			r.devices, r.err = devices, ""
		})
	}()
}

func (a *App) revokeRelayDevice(id string) {
	r := &a.relay
	if !r.signedIn || r.client == nil || r.busy {
		return
	}
	client, ctx, generation := r.client, r.ctx, r.generation
	r.busy = true
	go func() {
		err := client.Revoke(ctx, id)
		a.update(func() {
			if a.relay.generation != generation || ctx.Err() != nil {
				return
			}
			r.busy = false
			if err != nil {
				r.err = err.Error()
				return
			}
			if r.identity != nil && strings.EqualFold(id, r.identity.ID) {
				a.relaySignOut()
				return
			}
			a.refreshRelayDevices()
		})
	}()
}

func (a *App) relaySettingsGroup(c *ui.Context, pal *palette) {
	r := &a.relay
	settingsGroup(c, pal, locales.RelayTitle(), locales.RelayDetail(), func() {
		settingRow(c, pal, locales.RelayURL(), locales.RelayURLDetail(), func() {
			apply := func() { a.set.RelayURL = strings.TrimSpace(r.draft) }
			in := textField(c, "relay-url", &r.draft, "https://", 220, pal)
			in.OnSubmit(apply)
			if fieldButton(c, "relay-url-apply", locales.RelayApply(), false, pal) {
				apply()
			}
		})
		status := locales.RelaySignedOut()
		if r.busy {
			status = locales.RelayBusy()
		} else if r.verifier != "" {
			status = locales.RelayWaiting()
		} else if r.service != nil {
			state, err := r.service.State()
			switch state {
			case "connecting":
				status = locales.RelayConnecting()
			case "connected":
				status = locales.RelayConnected()
			case "failed":
				status = locales.RelayFailed()
				if err != nil {
					status += ": " + err.Error()
				}
			}
		}
		settingRow(c, pal, status, "", func() {
			if r.signedIn {
				if button(c, "relay-sign-out", locales.RelaySignOut(), "", false, pal) {
					a.relaySignOut()
				}
			} else if r.client != nil && r.identity != nil && !r.busy {
				if button(c, "relay-sign-in", locales.RelaySignIn(), "", true, pal) {
					a.relaySignIn()
				}
			}
		})
		if r.err != "" {
			ui.Text(c, r.err).FontSize(12).TextColor(pal.danger).Padding(0, 0, 10, 0)
		}
		settingRow(c, pal, locales.RelayHosting(), locales.RelayHostingDetail(), func() {
			toggle(c.Key("relay-host-enabled"), &a.set.RelayHostEnabled, pal)
		})
		if r.signedIn {
			settingRow(c, pal, locales.RelayDevices(), "", func() {
				if !r.busy && button(c, "relay-refresh", locales.RelayRefresh(), "", false, pal) {
					a.refreshRelayDevices()
				}
			})
			if len(r.devices) == 0 && !r.busy {
				settingRow(c, pal, locales.RelayNoDevices(), "", func() {})
			}
			for _, device := range r.devices {
				label := device.ID
				if r.identity != nil && strings.EqualFold(device.ID, r.identity.ID) {
					label = locales.RelayThisDevice() + " · " + label
				}
				settingRow(c, pal, label, device.LastSeenAt, func() {
					if !r.busy && button(c, "relay-revoke-"+device.ID, locales.RelayRevoke(), "", false, pal) {
						a.revokeRelayDevice(device.ID)
					}
				})
			}
		}
	})
}
