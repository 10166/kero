// Package settings is kero's settings: one file, settings.json in kero's
// directory, that the app writes from its Settings window and kerod reads
// as it starts panes, so that the shell, its environment and the
// scrollback apply to new panes at once.
package settings

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"

	"kero/internal/adblock"
	"kero/internal/proto"
	"kero/internal/remote"
)

// Settings are the user's choices. The zero value of a field is never a
// choice of its own: Load fills defaults in.
type Settings struct {
	// General
	NewSessionDir     string `json:"newSessionDir"`     // "current", "project" or "home"
	SessionName       string `json:"sessionName"`       // what names an unnamed session: proto.NameFocused, NameLead or NameFolder
	SidebarRows       string `json:"sidebarRows"`       // "detailed", two lines a session, or "compact", one
	FocusFollowsMouse bool   `json:"focusFollowsMouse"` // a pane the pointer enters takes the focus
	ConfirmClose      bool   `json:"confirmClose"`      // before closing a pane a program runs in
	RestoreSessions   bool   `json:"restoreSessions"`   // after kerod restarts, as after a reboot
	ResumeAgents      bool   `json:"resumeAgents"`      // as it restores sessions: the agents' own
	SessionHistory    bool   `json:"sessionHistory"`    // the sidebar lists the agents' ended conversations
	QuitConfirm       bool   `json:"quitConfirm"`       // tell, the first time, that quitting keeps sessions
	AppIcon           string `json:"appIcon"`           // macOS: AppIcons; elsewhere the icon is always in the notification area

	// Appearance
	Appearance string `json:"appearance"` // "system", "light" or "dark"
	Language   string `json:"language"`   // "system", or one of Languages
	Vibrancy   bool   `json:"vibrancy"`   // the window's material under the wash

	// Terminal
	TerminalBackend string  `json:"terminalBackend"` // "libghostty" or "alacritty"
	FontFamily      string  `json:"fontFamily"`      // "" the font kero carries; "monospace" the system's
	FontSize        float32 `json:"fontSize"`
	LineHeight      float32 `json:"lineHeight"`
	FontWeight      int     `json:"fontWeight"`
	Ligatures       bool    `json:"ligatures"`
	Thicken         bool    `json:"thicken"`
	MinContrast     float32 `json:"minContrast"`           // a WCAG ratio text keeps with its background
	DimUnfocused    bool    `json:"dimUnfocusedTerminals"` // the terminals the user is not in fade
	Cursor          string  `json:"cursor"`                // "block", "bar" or "underline"
	CursorBlink     bool    `json:"cursorBlink"`
	LightTheme      string  `json:"lightTheme"` // one of KeroThemes by its Name, or a Ghostty theme's
	DarkTheme       string  `json:"darkTheme"`
	OptionAsAlt     bool    `json:"optionAsAlt"`
	CopyOnSelect    bool    `json:"copyOnSelect"`
	Clipboard       string  `json:"clipboard"`  // programs reading it: "ask", "allow" or "deny"
	RightClick      string  `json:"rightClick"` // "menu", "paste" or "copyOrPaste"
	// ScrollPrecision scales a touchpad's scrolling, and ScrollDiscrete is
	// the rows a notch of a mouse wheel scrolls, as Ghostty's
	// mouse-scroll-multiplier = precision:…,discrete:….
	ScrollPrecision float32 `json:"scrollPrecision"`
	ScrollDiscrete  float32 `json:"scrollDiscrete"`

	// Shell
	Shell      string   `json:"shell"` // "" the account's login shell
	Env        []string `json:"env"`   // "KEY=value", added to every pane's
	Scrollback int      `json:"scrollback"`

	// Notifications
	NotifyWaiting bool `json:"notifyWaiting"` // a session needs you
	NotifyDone    bool `json:"notifyDone"`    // an agent finished
	NotifyFailed  bool `json:"notifyFailed"`  // a program reported it failed
	NotifySound   bool `json:"notifySound"`
	DockBadge     bool `json:"dockBadge"`
	BounceDock    bool `json:"bounceDock"`

	// Agents
	RemoteControl    bool   `json:"remoteControl"` // kero focus and kero do drive the app
	RelayURL         string `json:"relayURL"`
	RelayHostEnabled bool   `json:"relayHostEnabled"`

	// Git
	GitStatus  bool   `json:"gitStatus"`  // each pane's branch and changes, which kerod follows
	DiffLayout string `json:"diffLayout"` // the changes panel's diffs: "auto", "unified" or "split"
	// WorktreeBase is what a session's own worktree branches from:
	// "default", the repository's default branch, or "current", the
	// branch of the session the user is in. WorktreeDir is where its
	// worktrees go, "" for .kero/worktrees in the repository.
	WorktreeBase string `json:"worktreeBase"`
	WorktreeDir  string `json:"worktreeDir"`

	// Browser
	BlockAds bool     `json:"blockAds"` // in browser panes, with AdLists
	AdLists  []string `json:"adLists"`  // the filter lists: adblock.Catalog's IDs, or URLs

	// Keyboard: accelerators by action, over the defaults; "" unbinds.
	Shortcuts map[string]string `json:"shortcuts,omitempty"`

	// Hosts are other machines' kerods, which the app shows beside this
	// one's and the CLI reaches with -H.
	Hosts []Host `json:"hosts,omitempty"`
	// Listen are kerod's network listeners, for clients on other machines
	// (tailnet://:7373, tailnet-serve://), and ListenAllow who may connect
	// besides the machine's owner: tailnet logins, tag:name, or *.
	Listen      []string `json:"listen,omitempty"`
	ListenAllow []string `json:"listenAllow,omitempty"`
	// RemoteUpdates lets Kero on another machine that connects update the
	// app here to its version, and restart kerod into it, as it can a
	// server build: off unless the user turns it on here.
	RemoteUpdates bool `json:"remoteUpdates,omitempty"`
}

// Host is a machine whose kerod the app shows: its name, and its address
// (package remote).
type Host struct {
	Name string `json:"name"`
	// DisplayName is the original human-facing name; an empty value uses Name.
	DisplayName string `json:"displayName,omitempty"`
	// UUID retains the original Swift host identity when one was saved.
	UUID string `json:"uuid,omitempty"`
	// Directory is the host's absolute startup directory, or empty for home.
	Directory string `json:"directory,omitempty"`
	Addr      string `json:"addr"`
	// RemoteControl lets the host's programs drive the app, as kero focus
	// and kero do, which remote-control lets this machine's: off unless the
	// user trusts the host with it.
	RemoteControl bool `json:"remoteControl,omitempty"`
	// Color marks the host's sessions in the sidebar and its panes: one of
	// HostColors, "" for the one its name picks.
	Color string `json:"color,omitempty"`
}

// HostColors are the colors a host takes.
var HostColors = []string{"red", "orange", "amber", "green", "teal", "blue", "purple", "pink"}

// Host returns the host of a name, else nil.
func (s *Settings) Host(name string) *Host {
	for i := range s.Hosts {
		if strings.EqualFold(s.Hosts[i].Name, name) {
			return &s.Hosts[i]
		}
	}
	return nil
}

// Default returns the settings of a new install.
func Default() Settings {
	return Settings{
		NewSessionDir:   "current",
		SessionName:     proto.NameFocused,
		SidebarRows:     "detailed",
		ConfirmClose:    true,
		RestoreSessions: true,
		ResumeAgents:    true,
		QuitConfirm:     true,
		AppIcon:         "dock-and-menubar",
		Appearance:      "system",
		Language:        "system",
		Vibrancy:        true,
		TerminalBackend: "libghostty",
		DimUnfocused:    true,
		FontSize:        13,
		LineHeight:      1.22,
		FontWeight:      400,
		Ligatures:       true,
		MinContrast:     3,
		Cursor:          "block",
		CursorBlink:     true,
		LightTheme:      "paper",
		DarkTheme:       "paper",
		Clipboard:       "ask",
		RightClick:      "menu",
		ScrollPrecision: 1,
		ScrollDiscrete:  3,
		Scrollback:      4,
		NotifyWaiting:   true,
		NotifyDone:      true,
		NotifyFailed:    true,
		DockBadge:       true,
		RemoteControl:   true,
		GitStatus:       true,
		DiffLayout:      "auto",
		WorktreeBase:    "default",
		BlockAds:        true,
		AdLists:         slices.Clone(adblock.DefaultLists),
	}
}

// MinScrollMultiplier and MaxScrollMultiplier bound ScrollPrecision and
// ScrollDiscrete, as Ghostty bounds mouse-scroll-multiplier.
const (
	MinScrollMultiplier = 0.01
	MaxScrollMultiplier = 10000
)

// Languages are the languages the app is written in, as the catalogs of
// kero/locales name them.
var Languages = []string{"en", "ja", "zh-Hans"}

// AppIcons are where the app's icon shows on macOS: the Dock and the menu
// bar, the Dock alone, or the menu bar alone.
var AppIcons = []string{"dock-and-menubar", "dock", "menubar"}

// KeroThemes are kero's themes: the wash each shows under the window's
// cards, and its name in the configuration.
var KeroThemes = []struct{ ID, Name string }{
	{"rex", "petal"},
	{"mist", "mist"},
	{"meadow", "meadow"},
	{"dusk", "dusk"},
	{"tide", "tide"},
	{"apricot", "apricot"},
	{"aurora", "aurora"},
	{"dune", "dune"},
	{"paper", "paper"},
	{"plain", "plain"},
}

// Path returns the settings' file, the configuration (ConfigPath).
func Path() string { return ConfigPath() }

// legacyPath is where kero kept its settings before the configuration
// file, as JSON, which the first Load moves into it.
func legacyPath() string { return filepath.Join(proto.Dir(), "settings.json") }

var (
	mu       sync.Mutex
	cache    *Settings
	mtime    int64
	problems []string
)

// Load returns the settings, the defaults where the file says nothing.
// It reads the file again when it changed, so that a long-running reader,
// as kerod, sees the app's changes, and the user's.
func Load() Settings {
	mu.Lock()
	defer mu.Unlock()
	migrationProblems := migrate()
	st, err := os.Stat(Path())
	if err != nil {
		cache, problems = nil, migrationProblems
		return Default()
	}
	if cache != nil && st.ModTime().UnixNano() == mtime {
		return clone(*cache)
	}
	b, err := os.ReadFile(Path())
	if err != nil {
		return Default()
	}
	s, probs := parse(string(b))
	cache, mtime, problems = &s, st.ModTime().UnixNano(), probs
	return clone(s)
}

// Problems returns what the file got wrong, as of the last Load: keys
// kero does not know, and values it cannot take, which keep their
// defaults.
func Problems() []string {
	mu.Lock()
	defer mu.Unlock()
	return slices.Clone(problems)
}

// migrate moves the settings of the JSON file kero kept before into the
// configuration, once; mu is held.
func migrate() []string {
	if _, err := os.Lstat(Path()); err == nil || !os.IsNotExist(err) {
		return nil
	}
	b, err := os.ReadFile(legacyPath())
	if os.IsNotExist(err) {
		return migrateSwift()
	}
	if err != nil {
		return nil
	}
	// Then, the themes were "kero" for background's.
	old := struct {
		Settings
		Background string `json:"background"`
	}{Settings: Default()}
	old.LightTheme, old.DarkTheme = "kero", "kero"
	if json.Unmarshal(b, &old) != nil {
		return nil
	}
	s := old.Settings
	if bg := keroThemeName(old.Background); bg != "" {
		s.LightTheme, s.DarkTheme = keroTheme(s.LightTheme, bg), keroTheme(s.DarkTheme, bg)
	}
	s.normalize()
	if writeNew(s) == nil {
		os.Rename(legacyPath(), legacyPath()+".migrated")
	}
	return nil
}

// Save writes the settings into the configuration, keeping what the user
// wrote around them (see format).
func Save(s Settings) error {
	mu.Lock()
	defer mu.Unlock()
	if migrationProblems := migrate(); len(migrationProblems) != 0 {
		return fmt.Errorf("cannot save while Swift migration needs attention: %s", strings.Join(migrationProblems, "; "))
	}
	s.normalize()
	if err := write(s); err != nil {
		return err
	}
	c := clone(s)
	cache, problems = &c, nil
	if st, err := os.Stat(Path()); err == nil {
		mtime = st.ModTime().UnixNano()
	}
	return nil
}

// write writes the configuration; mu is held. A configuration that is a
// symlink, as one kept in a dotfiles repository is, stays one: the file it
// points to is what changes.
func write(s Settings) error {
	path := Target()
	old, _ := os.ReadFile(path)
	data := format(s, string(old))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	mode := os.FileMode(0o644)
	if st, err := os.Stat(path); err == nil {
		mode = st.Mode().Perm()
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(data), mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Target returns the file the configuration is in: Path, or the file it
// is a symlink to, as one kept in a dotfiles repository.
func Target() string { return target(Path()) }

// target returns the file a path's symlinks lead to, even one not there
// yet, else the path itself.
func target(path string) string {
	for range 40 {
		dest, err := os.Readlink(path)
		if err != nil {
			return path
		}
		if !filepath.IsAbs(dest) {
			dest = filepath.Join(filepath.Dir(path), dest)
		}
		path = dest
	}
	return path
}

// Clone returns a copy that shares nothing with s.
func (s Settings) Clone() Settings { return clone(s) }

// ScrollbackBytes is a terminal's terminal.Options.Scrollback for the
// scrollback-limit, the same in kerod's copy of a pane and the app's: -1
// keeps none, as 0 would take the terminal's default.
func (s Settings) ScrollbackBytes() int {
	if s.Scrollback == 0 {
		return -1
	}
	return s.Scrollback << 20
}

func clone(s Settings) Settings {
	s.Env = append([]string(nil), s.Env...)
	s.AdLists = slices.Clone(s.AdLists)
	s.Hosts = slices.Clone(s.Hosts)
	s.Listen = slices.Clone(s.Listen)
	s.ListenAllow = slices.Clone(s.ListenAllow)
	if s.Shortcuts != nil {
		m := make(map[string]string, len(s.Shortcuts))
		for k, v := range s.Shortcuts {
			m[k] = v
		}
		s.Shortcuts = m
	}
	return s
}

// normalize keeps values in range, as a file edited by hand may not.
func (s *Settings) normalize() {
	d := Default()
	oneOf := func(v *string, def string, ok ...string) {
		for _, o := range ok {
			if *v == o {
				return
			}
		}
		*v = def
	}
	oneOf(&s.NewSessionDir, d.NewSessionDir, "current", "project", "home")
	oneOf(&s.SidebarRows, d.SidebarRows, "detailed", "compact")
	oneOf(&s.Appearance, d.Appearance, "system", "light", "dark")
	oneOf(&s.Language, d.Language, append([]string{"system"}, Languages...)...)
	oneOf(&s.TerminalBackend, d.TerminalBackend, "libghostty", "alacritty")
	oneOf(&s.Cursor, d.Cursor, "block", "bar", "underline")
	oneOf(&s.Clipboard, d.Clipboard, "ask", "allow", "deny")
	oneOf(&s.RightClick, d.RightClick, "menu", "paste", "copyOrPaste")
	oneOf(&s.DiffLayout, d.DiffLayout, "auto", "unified", "split")
	oneOf(&s.WorktreeBase, d.WorktreeBase, "default", "current")
	oneOf(&s.AppIcon, d.AppIcon, AppIcons...)
	if s.FontSize < 8 || s.FontSize > 36 {
		s.FontSize = d.FontSize
	}
	if s.LineHeight < 0.8 || s.LineHeight > 2.5 {
		s.LineHeight = d.LineHeight
	}
	if s.FontWeight < 100 || s.FontWeight > 900 {
		s.FontWeight = d.FontWeight
	}
	if s.ScrollPrecision < MinScrollMultiplier || s.ScrollPrecision > MaxScrollMultiplier {
		s.ScrollPrecision = d.ScrollPrecision
	}
	if s.ScrollDiscrete < MinScrollMultiplier || s.ScrollDiscrete > MaxScrollMultiplier {
		s.ScrollDiscrete = d.ScrollDiscrete
	}
	if s.Scrollback < 0 || s.Scrollback > 256 {
		s.Scrollback = d.Scrollback
	}
	s.LightTheme, s.DarkTheme = keroTheme(s.LightTheme, d.LightTheme), keroTheme(s.DarkTheme, d.DarkTheme)
}

// keroTheme is a theme as kero had it before theme took kero's themes by
// name: "kero" was the one background chose, bg, and "" none.
func keroTheme(theme, bg string) string {
	if theme == "" || theme == "kero" {
		return bg
	}
	return theme
}

// keroThemeName is the name of one of kero's themes as background, which
// theme followed before it took them by name, wrote it: "rex" in the JSON
// settings, else as theme does; "" for none.
func keroThemeName(bg string) string {
	for _, t := range KeroThemes {
		if bg == t.ID || bg == t.Name {
			return t.Name
		}
	}
	return ""
}

// ParseHost reads a name=address followed by host options. Metadata values
// use unpadded URL-safe base64 so arbitrary UTF-8 survives the line format.
func ParseHost(line string) (Host, error) {
	name, rest, ok := strings.Cut(strings.TrimSpace(line), "=")
	name = strings.TrimSpace(name)
	fields := strings.Fields(rest)
	if !ok || len(fields) == 0 {
		return Host{}, fmt.Errorf("%q is not name=address", line)
	}
	if !remote.ValidName(name) {
		return Host{}, fmt.Errorf("%q can't name a host: use letters, digits, dots and dashes (and not local)", name)
	}
	a, err := remote.ParseAddr(fields[0])
	if err != nil {
		return Host{}, err
	}
	h := Host{Name: name, Addr: a.String()}
	for _, o := range fields[1:] {
		switch k, v, _ := strings.Cut(o, "="); {
		case o == "remote-control":
			h.RemoteControl = true
		case k == "color" && slices.Contains(HostColors, v):
			h.Color = v
		case k == "display-name64" || k == "uuid64" || k == "directory64":
			value, err := base64.RawURLEncoding.DecodeString(v)
			if err != nil {
				return Host{}, fmt.Errorf("%s: invalid %s encoding: %w", name, k, err)
			}
			switch k {
			case "display-name64":
				h.DisplayName = string(value)
			case "uuid64":
				h.UUID = string(value)
			case "directory64":
				h.Directory = string(value)
				if h.Directory != "" && (!strings.HasPrefix(h.Directory, "/") || strings.ContainsRune(h.Directory, 0)) {
					return Host{}, fmt.Errorf("%s: startup directory must be absolute and contain no NUL", name)
				}
			}
		case k == "color":
			return Host{}, fmt.Errorf("%s: no color %q (%s)", name, v, strings.Join(HostColors, ", "))
		default:
			return Host{}, fmt.Errorf("%s: no option %q (remote-control, color=…, display-name64=…, uuid64=…, directory64=…)", name, o)
		}
	}
	return h, nil
}
