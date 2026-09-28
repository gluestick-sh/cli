package main

import (
	"context"
	"fmt"
	"time"

	"github.com/spf13/cobra"
	"github.com/gluestick-sh/core/downloader"
	"github.com/gluestick-sh/core/engine"
	"github.com/gluestick-sh/core/verbose"
)

// installCmd installs one or more packages via the engine (deps, download, cache store, shims).
var installCmd = &cobra.Command{
	Use:     "install <package>...",
	Short:   "Install packages",
	Aliases: []string{"add", "i"},
	Args:    cobra.MinimumNArgs(1),
	RunE:    runInstall,
}

var (
	installWorkers     int
	installForce       bool
	installInteractive bool
	installTimings     bool
	installNoParallel  bool
)

func init() {
	rootCmd.AddCommand(installCmd)
	installCmd.SilenceUsage = true
	installCmd.SilenceErrors = true
	installCmd.Flags().IntVarP(&installWorkers, "jobs", "j", downloader.DefaultWorkers, "parallel download connections and extract/cache store workers")
	installCmd.Flags().BoolVarP(&installForce, "force", "f", false, "force reinstall: skip cache and discard partial downloads")
	installCmd.Flags().BoolVar(&installInteractive, "interactive", false, "show installer UI for packages that use installer.script (default: unattended)")
	installCmd.Flags().BoolVar(&installTimings, "timings", false, "print per-phase install timings (download/store/extract/link/shim)")
	installCmd.Flags().BoolVar(&installNoParallel, "no-parallel", false, "disable parallel range downloads (single connection; for speed tests)")
}

// installEngineConfig builds the engine config for the install command.
// Parallel range downloads come from config.json and can be disabled by
// --no-parallel; a missing or unreadable config falls back to defaults.
func installEngineConfig() *engine.EngineConfig {
	root := glueRoot()

	cfg, err := loadConfig(root)
	if err != nil {
		verbose.Progressf("  Warning: failed to read config.json: %v (using defaults)\n", err)
	}
	parallelDL := parallelDownloadEnabled(cfg)
	if installNoParallel {
		parallelDL = false
	}

	return &engine.EngineConfig{
		RootDir:  root,
		Verbose:  verbose.Enabled(),
		Workers:  installWorkers,
		Parallel: parallelDL,
	}
}

// newInstallRequest builds the engine request for one package reference,
// mapping the install flags onto request options.
func newInstallRequest(pkgRef string) *engine.InstallRequest {
	req := &engine.InstallRequest{
		Request: engine.Request{
			Name:    pkgRef,
			Force:   installForce,
			Options: map[string]string{},
		},
	}
	// --timings: the engine emits one GLUE_TIMINGS line per package
	// (see core/engine/internal/install/install_timings.go).
	if installTimings {
		req.Options["timings"] = "true"
	}
	if installInteractive {
		req.Options["interactive"] = "true"
	}
	return req
}

// installPackage installs one package and reports the outcome as a JSON item
// plus whether it failed. Human-readable progress is written here unless
// JSON output is enabled, so stdout stays machine-readable.
func installPackage(eng *engine.Engine, ctx context.Context, pkgRef string, reporter engine.ProgressReporter) (jsonResultItem, bool) {
	result, err := eng.Install(ctx, newInstallRequest(pkgRef), reporter)
	failErr := installFailureError(err, result)
	if failErr == nil {
		disableWindowsPythonAliases()
		return jsonResultItemFromInstall(pkgRef, result, nil), false
	}

	// Resolve notices carry their own formatted message, so they are not
	// printed through the generic "Failed" line below.
	if engine.IsInstallResolveNotice(failErr) {
		notice := engine.FormatInstallResolveNotice(failErr)
		if !jsonOutputEnabled() {
			verbose.Progressf("%s\n", notice)
		}
		return jsonResultItem{Ref: pkgRef, Error: notice}, true
	}

	if !jsonOutputEnabled() {
		verbose.Progressf("  %s Failed: %v\n", markFail, failErr)
	}
	return jsonResultItemFromInstall(pkgRef, result, failErr), true
}

// finishInstall emits the aggregated result and returns the command error:
// nil on full success, reportedFail() when any package failed.
func finishInstall(items []jsonResultItem, failed []string, start time.Time) error {
	if jsonOutputEnabled() {
		if err := jsonOperationResult("install", items); err != nil {
			return err
		}
		if len(failed) > 0 {
			return reportedFail()
		}
		return nil
	}

	verbose.Progressf("\n")
	if len(failed) > 0 {
		return reportedFail()
	}
	verbose.Progressf("Done in %s\n", time.Since(start).Round(time.Millisecond))
	return nil
}

func runInstall(cmd *cobra.Command, args []string) error {
	// Each package is installed sequentially; flags map to engine InstallRequest options.
	eng, err := engine.NewEngine(installEngineConfig())
	if err != nil {
		return fmt.Errorf("initialize engine: %w", err)
	}
	defer eng.Close()

	reporter := installReporter()

	var failed []string
	var items []jsonResultItem
	start := time.Now()

	for _, pkgRef := range args {
		item, ok := installPackage(eng, cmd.Context(), pkgRef, reporter)
		items = append(items, item)
		if !ok {
			failed = append(failed, pkgRef)
		}
	}

	return finishInstall(items, failed, start)
}

func installFailureError(err error, result *engine.Result) error {
	if err != nil {
		return err
	}
	if result != nil && result.Error != nil {
		return result.Error
	}
	return nil
}
