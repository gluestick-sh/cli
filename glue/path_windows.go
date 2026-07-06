//go:build windows

package main

import (
	"fmt"
	"strings"

	"golang.org/x/sys/windows/registry"
)

const userEnvKey = `Environment`

// appendToUserPath adds dir to the User PATH in the registry (no setx length limit).
func appendToUserPath(dir string) error {
	dir = strings.TrimSpace(dir)
	if dir == "" {
		return fmt.Errorf("empty directory")
	}

	key, err := registry.OpenKey(registry.CURRENT_USER, userEnvKey, registry.SET_VALUE|registry.QUERY_VALUE)
	if err != nil {
		return fmt.Errorf("open user Environment key: %w", err)
	}
	defer key.Close()

	current, _, err := key.GetStringValue("Path")
	if err != nil && err != registry.ErrNotExist {
		return fmt.Errorf("read user Path: %w", err)
	}

	for _, p := range splitPathList(current) {
		if strings.EqualFold(p, dir) {
			fmt.Println(markSuccess + " Already in PATH")
			return nil
		}
	}

	newPath := current
	if strings.TrimSpace(newPath) != "" {
		newPath += ";"
	}
	newPath += dir

	if err := key.SetStringValue("Path", newPath); err != nil {
		return fmt.Errorf("set user Path: %w", err)
	}
	return nil
}

func splitPathList(path string) []string {
	if path == "" {
		return nil
	}
	var out []string
	for _, p := range strings.Split(path, ";") {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
