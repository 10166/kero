package settings

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/BurntSushi/toml"

	"kero/internal/proto"
	"kero/internal/remote"
)

// writeNew publishes a complete file only if no configuration already exists.
// The hard link makes concurrent first launches and an existing symlink safe.
func writeNew(s Settings) error {
	path := Path()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".kero-migrate-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(0o644); err == nil {
		_, err = f.WriteString(format(s, ""))
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Link(f.Name(), path)
}

// Swift stored its data under HOME regardless of XDG. Explicit configuration
// overrides are isolated and must not import a different installation's data.
func migrateSwift() []string {
	if os.Getenv("KERO_CONFIG") != "" || os.Getenv("XDG_CONFIG_HOME") != "" {
		return nil
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return nil
	}
	dir := filepath.Join(home, ".config", proto.Name())
	configPath, hostsPath := filepath.Join(dir, "config.toml"), filepath.Join(dir, "ssh-hosts.json")
	config, configErr := os.ReadFile(configPath)
	hosts, hostsErr := os.ReadFile(hostsPath)
	if configErr != nil && !os.IsNotExist(configErr) {
		return []string{fmt.Sprintf("read %s: %v", configPath, configErr)}
	}
	if hostsErr != nil && !os.IsNotExist(hostsErr) {
		return []string{fmt.Sprintf("read %s: %v", hostsPath, hostsErr)}
	}
	if configErr != nil && hostsErr != nil {
		return nil
	}
	s := Default()
	if configErr == nil {
		var values map[string]interface{}
		if _, err := toml.Decode(string(config), &values); err != nil {
			return []string{fmt.Sprintf("fix %s: %v", configPath, err)}
		}
		swiftSettings(&s, values)
	}
	if hostsErr == nil {
		var entries []json.RawMessage
		if err := json.Unmarshal(hosts, &entries); err != nil {
			return []string{fmt.Sprintf("fix %s: %v", hostsPath, err)}
		}
		if entries == nil && strings.TrimSpace(string(hosts)) != "[]" {
			return []string{fmt.Sprintf("fix %s: expected an array of hosts", hostsPath)}
		}
		if errs := swiftHosts(&s, entries); len(errs) != 0 {
			for i := range errs {
				errs[i] = fmt.Sprintf("fix %s: %s", hostsPath, errs[i])
			}
			return errs
		}
	}
	if err := writeNew(s); err != nil && !os.IsExist(err) {
		return []string{fmt.Sprintf("write migrated configuration %s: %v", Path(), err)}
	}
	return nil
}

func swiftSettings(s *Settings, values map[string]interface{}) {
	str := func(m map[string]interface{}, key string) string {
		v, _ := m[key].(string)
		if strings.ContainsAny(v, "\r\n") {
			return ""
		}
		return v
	}
	if v := str(values, "theme"); v == "system" || v == "light" || v == "dark" {
		s.Appearance = v
	}
	// Swift's built-in themes are based on these Ghostty catalog themes.
	s.LightTheme, s.DarkTheme = "GitHub Light Default", "GitHub Dark Default"
	if v := str(values, "theme-light"); v != "" {
		s.LightTheme = v
	}
	if v := str(values, "theme-dark"); v != "" {
		s.DarkTheme = v
	}
	if s.LightTheme == "Default Light" {
		s.LightTheme = "GitHub Light Default"
	}
	if s.DarkTheme == "Default Dark" {
		s.DarkTheme = "GitHub Dark Default"
	}
	s.FontFamily = str(values, "font-family")
	var size float64
	switch v := values["font-size"].(type) {
	case int64:
		size = float64(v)
	case float64:
		size = v
	}
	if !math.IsNaN(size) && size >= 8 && size <= 32 {
		s.FontSize = float32(size)
	}
	terminal, _ := values["terminal"].(map[string]interface{})
	if v := str(terminal, "backend"); v == "libghostty" || v == "alacritty" {
		s.TerminalBackend = v
	}
	if v, ok := terminal["font-thicken"].(bool); ok {
		s.Thicken = v
	} else if v, ok := values["font-thicken"].(bool); ok {
		s.Thicken = v
	}
	if v := str(terminal, "cursor-shape"); v == "block" || v == "bar" || v == "underline" {
		s.Cursor = v
	}
	if v, ok := terminal["cursor-blinking"].(bool); ok {
		s.CursorBlink = v
	}
	if v, ok := terminal["macos-option-as-alt"].(bool); ok {
		s.OptionAsAlt = v
	}
	remoteValues, _ := values["remote"].(map[string]interface{})
	s.RelayURL = str(remoteValues, "relay-url")
	if v, ok := remoteValues["host-enabled"].(bool); ok {
		s.RelayHostEnabled = v
	}
}

func swiftHosts(s *Settings, entries []json.RawMessage) []string {
	var problems []string
	for i, data := range entries {
		var old struct {
			ID          *string `json:"id"`
			Name        *string `json:"name"`
			Destination *string `json:"destination"`
			Port        *int    `json:"port"`
			Directory   *string `json:"directory"`
		}
		issue := func(err string) { problems = append(problems, fmt.Sprintf("host %d: %s", i+1, err)) }
		if err := json.Unmarshal(data, &old); err != nil {
			issue(err.Error())
			continue
		}
		if old.Name == nil || old.Destination == nil {
			issue("name and destination must be strings")
			continue
		}
		id := ""
		if old.ID != nil {
			id = *old.ID
			if len(id) != 36 || id[8] != '-' || id[13] != '-' || id[18] != '-' || id[23] != '-' {
				issue("id must be a UUID")
				continue
			}
			if _, err := hex.DecodeString(strings.ReplaceAll(id, "-", "")); err != nil {
				issue("id must be a UUID")
				continue
			}
		}
		directory := ""
		if old.Directory != nil {
			directory = *old.Directory
			if directory != "" && (!strings.HasPrefix(directory, "/") || strings.ContainsRune(directory, 0)) {
				issue("directory must be absolute and contain no NUL")
				continue
			}
		}
		addr, err := remote.ParseAddr(*old.Destination)
		if err != nil {
			issue(fmt.Sprintf("invalid destination %q: %v", *old.Destination, err))
			continue
		}
		if addr.Scheme != "ssh" {
			issue(fmt.Sprintf("destination %q must be SSH", *old.Destination))
			continue
		}
		if old.Port != nil {
			if *old.Port < 0 || *old.Port > 65535 {
				issue("port must be between 0 and 65535")
				continue
			}
			if *old.Port != 0 {
				addr.Port = strconv.Itoa(*old.Port)
			}
		}
		name := strings.TrimSpace(*old.Name)
		if !remote.ValidName(name) {
			name = fmt.Sprintf("host-%d", i+1)
		}
		base := name
		for n := 2; s.Host(name) != nil; n++ {
			suffix := fmt.Sprintf("-%d", n)
			name = base[:min(len(base), 64-len(suffix))] + suffix
		}
		s.Hosts = append(s.Hosts, Host{Name: name, Addr: addr.String(), DisplayName: *old.Name, UUID: id, Directory: directory})
	}
	return problems
}
