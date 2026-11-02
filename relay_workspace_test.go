package main

import (
	"encoding/json"
	"strings"
	"testing"

	"kero/internal/proto"
	"kero/internal/relaybridge"
)

func TestRelayTopologyExcludesPathsAndRemoteWorkspaces(t *testing.T) {
	local := &host{conn: connReady}
	remote := &host{name: "other-device", relayID: "remote", conn: connReady}
	shell := proto.Pane{ID: "shell", Process: "agent", Title: "assistant", Dir: "/private/project"}
	browser := proto.Pane{ID: "browser", URL: "https://secret.example/private", Title: "private page"}
	app := &App{hosts: []*host{local, remote}, selected: "task", owner: map[string]*host{
		"project": local, "task": local, "shell": local, "browser": local,
		"remote-project": remote, "remote-task": remote,
	}, st: proto.State{
		Projects: []proto.Project{{ID: "project", Name: "Project", Dir: "/private/project"}, {ID: "remote-project", Name: "remote"}},
		Sessions: []proto.Session{{ID: "task", Project: "project", Name: "Task", Focus: "shell", Panes: []proto.Pane{shell, browser}, Layout: &proto.Layout{Row: true, Ratio: .4, A: &proto.Layout{Pane: "shell"}, B: &proto.Layout{Pane: "browser"}}}, {ID: "remote-task", Project: "remote-project", Panes: []proto.Pane{{ID: "remote-pane"}}}},
	}}
	b := &relayBackend{identity: "device"}
	if !b.refresh(app) {
		t.Fatal("first topology was not published")
	}
	topology, _ := b.Topology()
	data, err := json.Marshal(topology)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "/private") || strings.Contains(string(data), "secret.example") || strings.Contains(string(data), "private page") {
		t.Fatalf("topology exposes private paths or browser metadata: %s", data)
	}
	if len(topology.Projects) != 1 || len(topology.Projects[0].Tabs) != 1 {
		t.Fatalf("unexpected projects: %+v", topology.Projects)
	}
	tab := topology.Projects[0].Tabs[0]
	if tab.Layout.Kind != "split" || tab.Layout.Axis != "horizontal" || tab.Layout.First.Kind != "pane" || tab.Layout.First.Pane.SessionID == nil || tab.Layout.Second.Pane.Kind != "browser" {
		t.Fatalf("layout does not describe the split: %+v", tab.Layout)
	}
	if b.refresh(app) {
		t.Fatal("unchanged topology was republished")
	}
	if _, ok := b.targets[*tab.Layout.First.Pane.SessionID]; !ok {
		t.Fatal("terminal missing from exposed targets")
	}
}

func TestRelayWorkspaceKeepsDevicesAndPaneIDsSeparate(t *testing.T) {
	terminalID := "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	pane := &relaybridge.Pane{ID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", Kind: "terminal", Title: "shell", SessionID: &terminalID}
	topology := relaybridge.Topology{Projects: []relaybridge.Project{{ID: "project", Name: "project", Tabs: []relaybridge.Tab{{ID: "tab", Title: "task", FocusedPaneID: pane.ID, Layout: relaybridge.PaneNode{Kind: "pane", Pane: pane}}}}}}
	targets := map[string]relayPaneTarget{}
	one := relayWorkspace("device-one", topology, targets)
	two := relayWorkspace("device-two", topology, targets)
	if len(one.Sessions) != 1 || len(two.Sessions) != 1 {
		t.Fatal("both devices should expose their session")
	}
	a, b := one.Sessions[0].Panes[0].ID, two.Sessions[0].Panes[0].ID
	if a == b || targets[a].host != "device-one" || targets[b].host != "device-two" || targets[a].session != terminalID {
		t.Fatalf("device targets collided: %+v", targets)
	}
	if one.Sessions[0].Focus != a {
		t.Fatal("focused pane was not preserved")
	}
}
