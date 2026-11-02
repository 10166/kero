package cli

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"

	"kero/internal/settings"
)

// configCmd shows, opens and checks the configuration file.
func configCmd(args []string) error {
	f, err := parse(args, nil, map[string]string{"defaults": "defaults", "d": "defaults"})
	if err != nil {
		return err
	}
	sub := "path"
	if len(f.pos) > 0 {
		sub = f.pos[0]
	}
	switch sub {
	case "path":
		fmt.Println(settings.Path())
		return nil
	case "show":
		s := settings.Load()
		if f.set["defaults"] {
			s = settings.Default()
		}
		fmt.Print(settings.Reference(s))
		return nil
	case "check":
		settings.Load()
		problems := settings.Problems()
		if len(problems) == 0 {
			fmt.Println("ok:", settings.Path())
			return nil
		}
		for _, p := range problems {
			fmt.Println(p)
		}
		return errors.New(fmt.Sprintf("%d problem(s) in %s", len(problems), settings.Path()))
	case "edit":
		if _, err := os.Stat(settings.Path()); err != nil {
			if err := settings.Save(settings.Load()); err != nil {
				return err
			}
		}
		editor := os.Getenv("VISUAL")
		if editor == "" {
			editor = os.Getenv("EDITOR")
		}
		var cmd *exec.Cmd
		if editor != "" {
			parts := strings.Fields(editor)
			cmd = exec.Command(parts[0], append(parts[1:], settings.Path())...)
		} else {
			cmd = textEditor(settings.Path())
		}
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		return cmd.Run()
	}
	return usageErr("kero config path|show [--defaults]|edit|check")
}

// textEditor opens a text file in the system's text editor.
func textEditor(path string) *exec.Cmd {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("/usr/bin/open", "-t", path)
	case "windows":
		return exec.Command("notepad.exe", path)
	}
	return exec.Command("xdg-open", path)
}
