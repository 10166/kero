package main

import (
	"encoding/json"
	"errors"
	"testing"
	"time"

	"kero/internal/proto"
)

func TestRemoteHostStartupDirectory(t *testing.T) {
	for _, tc := range []struct {
		name, mode, selected, project, directory, wantDir, wantProject string
	}{
		{"host default", "current", "", "", "/srv/项目 files", "/srv/项目 files", ""},
		{"empty host", "current", "", "", "/srv/default", "/srv/default", ""},
		{"project", "project", "", "rp-build", "/srv/default", "", "rp-build"},
		{"current", "current", "rs-build", "", "/srv/default", "/home/me/api", "rp-build"},
		{"home", "home", "", "", "/srv/default", "~", ""},
		{"no default", "current", "", "", "", "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a := testApp(t)
			h := withHost(t, a, "build")
			h.cfg.Directory = tc.directory
			if tc.name == "empty host" {
				a.mergeState(h, proto.State{})
			}
			a.set.NewSessionDir, a.selected = tc.mode, tc.selected
			calls := make(chan proto.CreateParams, 1)
			cl, stop := projectClient(t, func(method string, raw json.RawMessage) (any, error) {
				if method != "create" {
					return nil, errors.New("unexpected method")
				}
				var p proto.CreateParams
				if err := json.Unmarshal(raw, &p); err != nil {
					return nil, err
				}
				calls <- p
				return proto.Session{ID: "new", Project: p.Project}, nil
			})
			h.cl = cl
			a.newSessionOn(h, tc.project)
			select {
			case got := <-calls:
				if got.Dir != tc.wantDir || got.Project != tc.wantProject {
					t.Fatalf("create: dir %q project %q, want %q %q", got.Dir, got.Project, tc.wantDir, tc.wantProject)
				}
			case <-time.After(time.Second):
				t.Fatal("create was not called")
			}
			stop()
		})
	}
}

func TestHostEditorPreservesIdentityAndMetadata(t *testing.T) {
	a := testApp(t)
	h := withHost(t, a, "build")
	cfg := a.set.Host("build")
	cfg.UUID = "ABCDEF01-2345-6789-ABCD-EF0123456789"
	cfg.DisplayName = "Original 名"
	cfg.Directory = "/old directory"
	h.cfg = *cfg
	a.ss.hostEdit = hostDraft{editing: h.name, name: h.name, addr: cfg.Addr, displayName: "New 名 #", directory: "/new 目录"}
	a.saveHost(h)
	got := a.set.Host("build")
	if got.UUID != "ABCDEF01-2345-6789-ABCD-EF0123456789" || got.DisplayName != "New 名 #" || got.Directory != "/new 目录" {
		t.Fatalf("saved host: %+v", got)
	}
	a.ss.hostEdit = hostDraft{editing: h.name, name: h.name, addr: got.Addr, displayName: "Another", directory: "relative"}
	a.saveHost(h)
	if a.ss.hostEdit.err == "" || a.set.Host("build").Directory != "/new 目录" || a.set.Host("build").DisplayName != "New 名 #" {
		t.Fatalf("invalid edit was accepted: %+v, %q", a.set.Host("build"), a.ss.hostEdit.err)
	}
}
