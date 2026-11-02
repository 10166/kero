package relaybridge

import (
	"context"
	"encoding/json"
	"fmt"
)

// Topology contains only display metadata. Backend implementations must not put
// paths, commands, environment variables, or other private data in these fields.
type Topology struct {
	Revision uint64    `json:"revision"`
	HostName string    `json:"hostName"`
	Projects []Project `json:"projects"`
}
type Project struct {
	ID            string  `json:"id"`
	Name          string  `json:"name"`
	Tabs          []Tab   `json:"tabs"`
	SelectedTabID *string `json:"selectedTabID,omitempty"`
}
type Tab struct {
	ID            string   `json:"id"`
	Title         string   `json:"title"`
	Layout        PaneNode `json:"layout"`
	FocusedPaneID string   `json:"focusedPaneID"`
}
type PaneNode struct {
	Kind     string    `json:"kind"`
	Pane     *Pane     `json:"pane,omitempty"`
	ID       string    `json:"id,omitempty"`
	Axis     string    `json:"axis,omitempty"`
	Fraction float64   `json:"fraction,omitempty"`
	First    *PaneNode `json:"first,omitempty"`
	Second   *PaneNode `json:"second,omitempty"`
}
type Pane struct {
	ID        string  `json:"id"`
	Kind      string  `json:"kind"`
	Title     string  `json:"title"`
	SessionID *string `json:"sessionID,omitempty"`
}

// Swift requires arrays, even when no projects or tabs are present.
func (t Topology) MarshalJSON() ([]byte, error) {
	type topology Topology
	if t.Projects == nil {
		t.Projects = []Project{}
	}
	return json.Marshal(topology(t))
}
func (p Project) MarshalJSON() ([]byte, error) {
	type project Project
	if p.Tabs == nil {
		p.Tabs = []Tab{}
	}
	return json.Marshal(project(p))
}

// Swift's custom pane encoding requires fraction for every split, including
// zero, and only encodes fields belonging to the selected node kind.
func (n PaneNode) MarshalJSON() ([]byte, error) {
	switch n.Kind {
	case "pane":
		return json.Marshal(struct {
			Kind string `json:"kind"`
			Pane *Pane  `json:"pane"`
		}{n.Kind, n.Pane})
	case "split":
		return json.Marshal(struct {
			Kind     string    `json:"kind"`
			ID       string    `json:"id"`
			Axis     string    `json:"axis"`
			Fraction float64   `json:"fraction"`
			First    *PaneNode `json:"first"`
			Second   *PaneNode `json:"second"`
		}{n.Kind, n.ID, n.Axis, n.Fraction, n.First, n.Second})
	default:
		return nil, fmt.Errorf("relay bridge: invalid pane node kind %q", n.Kind)
	}
}

type Resize struct {
	SessionID  string `json:"sessionID"`
	Columns    uint16 `json:"columns"`
	Rows       uint16 `json:"rows"`
	CellWidth  uint16 `json:"cellWidth"`
	CellHeight uint16 `json:"cellHeight"`
}
type attachRequest struct {
	RequestID       string `json:"requestID"`
	SessionID       string `json:"sessionID"`
	ControllerEpoch string `json:"controllerEpoch"`
	HostEpoch       string `json:"hostEpoch"`
	Columns         uint16 `json:"columns"`
	Rows            uint16 `json:"rows"`
	CellWidth       uint16 `json:"cellWidth"`
	CellHeight      uint16 `json:"cellHeight"`
}
type attachResponse struct {
	RequestID string `json:"requestID"`
	SessionID string `json:"sessionID"`
	Reason    string `json:"reason,omitempty"`
}
type sessionReference struct {
	SessionID string `json:"sessionID"`
}
type hello struct {
	Name        string `json:"name"`
	HostEnabled bool   `json:"hostEnabled"`
}

// Host is a snapshot of a device and its last authenticated topology.
type Host struct {
	ID          string
	Name        string
	Online      bool
	HostEnabled bool
	Topology    *Topology
}

// Backend supplies a safe topology and an exclusive terminal lease. Acquire
// returns only after ownership is granted and a bootstrap snapshot has been
// captured. Output must include all bytes after that snapshot, in order.
// Acquire must honor cancellation; Release must unblock Output and any pending
// lease operations. Implementations must use bounded output buffering.
type Backend interface {
	Topology() (Topology, error)
	Acquire(ctx context.Context, sessionID string, size Resize) (Lease, []byte, error)
}
type Lease interface {
	Output() <-chan []byte
	Write([]byte) error
	Resize(Resize) error
	Release() error
}

// TerminalEvent contains either bootstrap/output bytes, or a terminal state.
// State is one of "granted", "busy", "closed"; Data is populated for
// "bootstrap" and "output". No events follow a terminal state.
type TerminalEvent struct {
	State string
	Data  []byte
	Err   error
}
