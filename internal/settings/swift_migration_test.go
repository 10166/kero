package settings

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

func swiftFixture(t *testing.T, config, hosts string) (string, string, string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("KERO_CONFIG", "")
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("KERO_HOME", filepath.Join(home, "go-data"))
	dir := filepath.Dir(ConfigPath())
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	configPath, hostsPath := filepath.Join(dir, "config.toml"), filepath.Join(dir, "ssh-hosts.json")
	if config != "" {
		if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if hosts != "" {
		if err := os.WriteFile(hostsPath, []byte(hosts), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return configPath, hostsPath, ConfigPath()
}

func TestSwiftMigrationConversionAndRestart(t *testing.T) {
	config := "theme = \"dark\"\ntheme-light = \"Catppuccin Latte\"\ntheme-dark = \"Catppuccin Mocha\"\nfont-family = \"Iosevka\"\nfont-size = 17.5\nterminal.backend = \"alacritty\"\nterminal.font-thicken = true\nterminal.cursor-shape = \"bar\"\nterminal.cursor-blinking = false\nterminal.macos-option-as-alt = true\nremote.relay-url = \"https://relay.example\"\nremote.host-enabled = true\neditor.wrap-lines = true\n"
	hosts := `[{"id":"ABCDEF01-2345-6789-ABCD-EF0123456789","name":" Work 名 = # ","destination":"alice@example.com","port":2222,"directory":"/src/项目 space/#foo\nbar"},{"id":"01234567-89AB-CDEF-0123-456789ABCDEF","name":"work","destination":"other"},{"name":"local","destination":"third","port":0},{"name":"work","destination":"fourth"}]`
	cp, hp, dest := swiftFixture(t, config, hosts)
	migrate()
	data, err := os.ReadFile(dest)
	if err != nil {
		t.Fatal(err)
	}
	s, problems := parse(string(data))
	if len(problems) != 0 {
		t.Fatal(problems)
	}
	if s.Appearance != "dark" || s.LightTheme != "Catppuccin Latte" || s.DarkTheme != "Catppuccin Mocha" || s.FontFamily != "Iosevka" || s.FontSize != 17.5 || s.TerminalBackend != "alacritty" || !s.Thicken || s.Cursor != "bar" || s.CursorBlink || !s.OptionAsAlt || s.RelayURL != "https://relay.example" || !s.RelayHostEnabled {
		t.Fatalf("converted settings: %+v", s)
	}
	if len(s.Hosts) != 4 || s.Hosts[0].Name != "host-1" || s.Hosts[0].Addr != "alice@example.com:2222" || s.Hosts[0].DisplayName != " Work 名 = # " || s.Hosts[0].UUID != "ABCDEF01-2345-6789-ABCD-EF0123456789" || s.Hosts[0].Directory != "/src/项目 space/#foo\nbar" || s.Hosts[1].Name != "work" || s.Hosts[2].Name != "host-3" || s.Hosts[3].Name != "work-2" || s.Hosts[3].DisplayName != "work" {
		t.Fatalf("hosts: %+v", s.Hosts)
	}
	loaded := Load()
	if !reflect.DeepEqual(loaded.Hosts, s.Hosts) {
		t.Fatalf("load: %+v", loaded.Hosts)
	}
	if err := Save(loaded); err != nil {
		t.Fatal(err)
	}
	cache = nil // Simulate a fresh process reading the saved configuration.
	if got := Load(); !reflect.DeepEqual(got.Hosts, s.Hosts) {
		t.Fatalf("restart: %+v", got.Hosts)
	}
	if got := Load(); got.TerminalBackend != "alacritty" {
		t.Fatalf("restart backend: %q", got.TerminalBackend)
	}
	data, err = os.ReadFile(dest)
	if err != nil {
		t.Fatal(err)
	}
	for path, want := range map[string]string{cp: config, hp: hosts} {
		b, err := os.ReadFile(path)
		if err != nil || string(b) != want {
			t.Fatalf("source %s changed: %q, %v", path, b, err)
		}
	}
	migrate()
	again, err := os.ReadFile(dest)
	if err != nil || string(again) != string(data) {
		t.Fatalf("restart changed config: %v", err)
	}
}

func TestSwiftMigrationPrecedenceAndIsolation(t *testing.T) {
	t.Run("existing", func(t *testing.T) {
		_, _, dest := swiftFixture(t, "font-size = 18\n", "")
		if err := os.WriteFile(dest, []byte("font-size = 19\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		migrate()
		b, _ := os.ReadFile(dest)
		if string(b) != "font-size = 19\n" {
			t.Fatalf("overwrote %q", b)
		}
	})
	t.Run("go legacy", func(t *testing.T) {
		_, _, dest := swiftFixture(t, "font-size = 18\n", "")
		if err := os.MkdirAll(filepath.Dir(legacyPath()), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(legacyPath(), []byte(`{"fontSize": 21}`), 0o600); err != nil {
			t.Fatal(err)
		}
		migrate()
		b, err := os.ReadFile(dest)
		if err != nil || !strings.Contains(string(b), "font-size = 21") {
			t.Fatalf("legacy precedence: %s %v", b, err)
		}
	})
	for _, variable := range []string{"KERO_CONFIG", "XDG_CONFIG_HOME"} {
		t.Run(variable, func(t *testing.T) {
			swiftFixture(t, "font-size = 18\n", "")
			t.Setenv(variable, filepath.Join(t.TempDir(), "isolated"))
			migrate()
			if _, err := os.Lstat(ConfigPath()); !os.IsNotExist(err) {
				t.Fatalf("imported into isolated config: %v", err)
			}
		})
	}
}

func TestSwiftMigrationMalformedAndConcurrent(t *testing.T) {
	for _, tt := range []struct{ config, hosts string }{
		{"font-size = [\n", `[]`},
		{"font-size = 18\n", `[`},
	} {
		t.Run(tt.config+tt.hosts, func(t *testing.T) {
			_, _, dest := swiftFixture(t, tt.config, tt.hosts)
			migrate()
			if _, err := os.Stat(dest); !os.IsNotExist(err) {
				t.Fatalf("malformed input created config: %v", err)
			}
		})
	}
	t.Run("concurrent", func(t *testing.T) {
		_, _, dest := swiftFixture(t, "font-size = 18\n", `[{"name":"ok","destination":"example.com"}]`)
		var wg sync.WaitGroup
		for range 20 {
			wg.Add(1)
			go func() { defer wg.Done(); migrateSwift() }()
		}
		wg.Wait()
		b, err := os.ReadFile(dest)
		if err != nil {
			t.Fatal(err)
		}
		s, probs := parse(string(b))
		if len(probs) != 0 || s.FontSize != 18 || len(s.Hosts) != 1 || s.Hosts[0].Name != "ok" {
			t.Fatalf("settings %+v, problems %v", s, probs)
		}
	})
}

func TestSwiftMigrationInvalidHostsRemainRecoverable(t *testing.T) {
	for _, host := range []string{
		`{"name":"bad","destination":"-invalid"}`,
		`{"name":"bad","destination":"host","port":70000}`,
		`{"name":"bad","destination":"host","directory":"relative"}`,
		`{"name":"bad","destination":"host","id":"not-a-uuid"}`,
		`{"name":12,"destination":"host"}`,
	} {
		t.Run(host, func(t *testing.T) {
			source := `[{"name":"good","destination":"example.com"},` + host + `]`
			_, path, dest := swiftFixture(t, "", source)
			settings := Load()
			if got := strings.Join(Problems(), "; "); !strings.Contains(got, path) || !strings.Contains(got, "host 2") {
				t.Fatalf("missing diagnostic: %q", got)
			}
			if err := Save(settings); err == nil {
				t.Fatal("saved over an incomplete migration")
			}
			if _, err := os.Stat(dest); !os.IsNotExist(err) {
				t.Fatalf("incomplete migration wrote config: %v", err)
			}
			if b, err := os.ReadFile(path); err != nil || string(b) != source {
				t.Fatalf("source changed: %s, %v", b, err)
			}
			if err := os.WriteFile(path, []byte(`[{"name":"good","destination":"example.com"}]`), 0o600); err != nil {
				t.Fatal(err)
			}
			if got := Load(); len(got.Hosts) != 1 || got.Hosts[0].DisplayName != "good" || len(Problems()) != 0 {
				t.Fatalf("recovery: %+v, %v", got.Hosts, Problems())
			}
		})
	}
}
