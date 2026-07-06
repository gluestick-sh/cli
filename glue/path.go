//go:build windows

package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
	"github.com/gluestick-sh/core/shim"
)

var pathCmd = &cobra.Command{
	Use:   "path",
	Short: "Manage PATH integration",
}

var pathShowCmd = &cobra.Command{
	Use:   "show",
	Short: "Show the PATH entry for glue",
	RunE: func(cmd *cobra.Command, args []string) error {
		root := glueRoot()

		shimMgr, err := shim.NewManager(root)
		if err != nil {
			return fmt.Errorf("initialize shim manager: %w", err)
		}

		fmt.Println(shimMgr.BinDir())
		return nil
	},
}

var pathCheckCmd = &cobra.Command{
	Use:   "check",
	Short: "Check if Glue is in PATH",
	RunE: func(cmd *cobra.Command, args []string) error {
		root := glueRoot()

		shimMgr, err := shim.NewManager(root)
		if err != nil {
			return fmt.Errorf("initialize shim manager: %w", err)
		}

		if shimMgr.InPath() {
			fmt.Println(markSuccess + " Glue is in PATH")
			return nil
		}

		fmt.Println(markFail + " Glue is NOT in PATH")
		fmt.Println("\nAdd the following to your PATH:")
		fmt.Println(shimMgr.BinDir())
		fmt.Println("\nOr run from PowerShell (requires admin):")
		fmt.Printf("[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ';%s', 'User')\n", shimMgr.BinDir())
		return reportedFail()
	},
}

var pathSetupCmd = &cobra.Command{
	Use:   "setup",
	Short: "Add glue to PATH (no admin required on Windows)",
	RunE: func(cmd *cobra.Command, args []string) error {
		root := glueRoot()

		shimMgr, err := shim.NewManager(root)
		if err != nil {
			return fmt.Errorf("initialize shim manager: %w", err)
		}

		if shimMgr.InPath() {
			fmt.Println(markSuccess + " glue is already in PATH")
			return nil
		}

		return addToUserPath(shimMgr.BinDir())
	},
}

// addToUserPath adds a directory to the user PATH on Windows (registry User Environment).
func addToUserPath(dir string) error {
	fmt.Printf("Adding %s to user PATH...\n", dir)
	if err := appendToUserPath(dir); err != nil {
		return err
	}
	// Refresh current process PATH for this session.
	if cur := os.Getenv("PATH"); cur != "" {
		_ = os.Setenv("PATH", cur+";"+dir)
	} else {
		_ = os.Setenv("PATH", dir)
	}
	fmt.Println(markSuccess + " Added to user PATH")
	fmt.Println("\n⚠ Restart your terminal for changes to take effect")
	return nil
}

func init() {
	rootCmd.AddCommand(pathCmd)
	pathCmd.AddCommand(pathShowCmd)
	pathCmd.AddCommand(pathCheckCmd)
	pathCmd.AddCommand(pathSetupCmd)
}
