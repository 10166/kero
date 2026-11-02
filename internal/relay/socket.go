package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"

	"github.com/coder/websocket"
)

type Presence struct {
	OnlineDeviceIDs []string `json:"online_device_ids"`
}
type Message struct {
	Presence *Presence
	Frame    []byte
}

// Socket carries presence messages and encrypted binary frames. Read must be
// called continuously, including while waiting for Ping's response.
type Socket struct {
	conn     *websocket.Conn
	deviceID string
}

func (c *Client) Connect(ctx context.Context, identity *Identity) (*Socket, error) {
	if identity == nil {
		return nil, errors.New("relay: missing identity")
	}
	id, err := normalizeUUID(identity.ID)
	if err != nil {
		return nil, err
	}
	token, err := c.AccessToken(ctx)
	if err != nil {
		return nil, err
	}
	u := c.endpoint("v1/socket")
	if u.Scheme == "https" {
		u.Scheme = "wss"
	} else {
		u.Scheme = "ws"
	}
	q := u.Query()
	q.Set("device_id", id)
	u.RawQuery = q.Encode()
	header := make(http.Header)
	header.Set("Authorization", "Bearer "+token)
	conn, response, err := websocket.Dial(ctx, u.String(), &websocket.DialOptions{HTTPClient: c.http, HTTPHeader: header, CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		if response != nil && (response.StatusCode < 200 || response.StatusCode >= 300) {
			return nil, &HTTPError{response.StatusCode}
		}
		return nil, fmt.Errorf("relay: websocket connection: %w", err)
	}
	conn.SetReadLimit(MaxFrameBytes)
	return &Socket{conn: conn, deviceID: id}, nil
}
func (s *Socket) Read(ctx context.Context) (Message, error) {
	kind, data, err := s.conn.Read(ctx)
	if err != nil {
		return Message{}, err
	}
	switch kind {
	case websocket.MessageBinary:
		if _, err := FrameSender(data); err != nil {
			return Message{}, err
		}
		if uuidString(data[2:18]) != s.deviceID {
			return Message{}, ErrWrongRoute
		}
		return Message{Frame: data}, nil
	case websocket.MessageText:
		var v struct {
			Type   string   `json:"type"`
			Online []string `json:"online_device_ids"`
		}
		if err := json.Unmarshal(data, &v); err != nil || v.Type != "presence" || v.Online == nil {
			return Message{}, errors.New("relay: invalid presence message")
		}
		for i := range v.Online {
			id, err := normalizeUUID(v.Online[i])
			if err != nil {
				return Message{}, errors.New("relay: invalid presence device ID")
			}
			v.Online[i] = id
		}
		return Message{Presence: &Presence{OnlineDeviceIDs: v.Online}}, nil
	default:
		return Message{}, errors.New("relay: invalid websocket message")
	}
}
func (s *Socket) WriteFrame(ctx context.Context, frame []byte) error {
	sender, err := FrameSender(frame)
	if err != nil {
		return err
	}
	if sender != s.deviceID {
		return ErrWrongRoute
	}
	return s.conn.Write(ctx, websocket.MessageBinary, frame)
}
func (s *Socket) Ping(ctx context.Context) error { return s.conn.Ping(ctx) }
func (s *Socket) Close() error                   { return s.conn.Close(websocket.StatusNormalClosure, "") }
