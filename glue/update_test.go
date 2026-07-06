package main

import (
	"testing"

	"github.com/gluestick-sh/core/engine"
)

func TestSelectUpdateTargets_allFlag(t *testing.T) {
	updates := []engine.PackageUpdate{
		{Name: "git", InstalledVersion: "2.44", LatestVersion: "2.45"},
		{Name: "7zip", InstalledVersion: "23.0", LatestVersion: "24.0"},
	}
	got := selectUpdateTargets(updates, nil, true)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2", len(got))
	}
}

func TestSelectUpdateTargets_starArg(t *testing.T) {
	updates := []engine.PackageUpdate{{Name: "git"}}
	got := selectUpdateTargets(updates, []string{"*"}, false)
	if len(got) != 1 {
		t.Fatalf("len = %d, want 1", len(got))
	}
}

func TestSelectUpdateTargets_listOnly(t *testing.T) {
	updates := []engine.PackageUpdate{{Name: "git"}}
	if got := selectUpdateTargets(updates, nil, false); got != nil {
		t.Fatalf("expected nil targets for list-only mode, got %v", got)
	}
}
