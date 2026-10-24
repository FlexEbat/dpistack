// Command panel is the dpistack web panel. The installer's systemd unit
// passes the resolved ACCESS_MODE, LAN_CIDR and PANEL_PORT as flags.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/api"
	"github.com/FlexEbat/dpistack/panel/internal/auth"
	"github.com/FlexEbat/dpistack/panel/internal/ctl"
	"github.com/FlexEbat/dpistack/panel/internal/eve"
	"github.com/FlexEbat/dpistack/panel/internal/export"
	"github.com/FlexEbat/dpistack/panel/internal/metrics"
	"github.com/FlexEbat/dpistack/panel/web"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "panel:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("panel", flag.ContinueOnError)
	addr := fs.String("addr", "127.0.0.1:9800", "listen address")
	access := fs.String("access", "localhost", "ACCESS_MODE: localhost, lan or nginx")
	lanCIDR := fs.String("lan-cidr", "", "LAN_CIDR resolved to an address/length; required for lan")
	authFile := fs.String("auth-file", "/etc/dpistack/panel.auth", "argon2id hash of the panel password")
	healthFile := fs.String("health-file", "/var/lib/dpistack/health.json", "watchdog report")
	ctlPath := fs.String("ctl", "/usr/local/sbin/dpistack", "dpistack path")
	eveFile := fs.String("eve-file", "", "eve.json to show on the Events screen; empty turns the viewer off (EVE_FILE=no)")
	metricsFile := fs.String("metrics-file", "", "metrics.json: the graph history is restored from it and saved to it; empty keeps it in memory only")
	tokenFile := fs.String("metrics-token-file", "", "file with the bearer token of GET /metrics; empty switches /metrics off (METRICS_EXPORT=no)")
	testsFile := fs.String("tests-file", "", "tests-last.json: the Tests screen and the test metrics")
	eventsFile := fs.String("events-file", "", "events.jsonl: the Alerts screen")
	rulesFile := fs.String("rules-file", "", "suricata.rules, for its age")
	diskPaths := fs.String("disk-paths", "", "comma-separated directories whose free space /metrics reports")
	lite := fs.Bool("lite", false, "lite edition (PANEL_EDITION=lite): the same features with a plain, light page")
	ctlPrefix := fs.String("ctl-prefix", "", "comma-separated command that runs dpistack on the host from a container, e.g. nsenter,-t,1,-m,-u,-i,-n,-p,--; replaces sudo")
	useSudo := fs.Bool("sudo", true, "run dpistack through sudo -n")
	if err := fs.Parse(args); err != nil {
		return err
	}

	policy, err := auth.NewPolicy(*access, *lanCIDR)
	if err != nil {
		return err
	}
	ap, err := netip.ParseAddrPort(*addr)
	if err != nil {
		return fmt.Errorf("addr %q: %w", *addr, err)
	}
	// With localhost and nginx the only legitimate peer is local; binding
	// elsewhere would expose the panel without the address policy's intent.
	if *access != "lan" && !ap.Addr().IsLoopback() {
		return fmt.Errorf("access mode %s requires a loopback addr, got %s", *access, ap.Addr())
	}

	var events *eve.Reader
	if *eveFile != "" {
		events = eve.New(*eveFile)
	}

	inputs := metrics.Inputs{Proc: metrics.Proc}
	if events != nil {
		inputs.Stats = metrics.EveStats(events)
		inputs.EveSize = metrics.FileSize(*eveFile)
		inputs.DiskFree = metrics.DiskFree(*eveFile)
	}
	collector := metrics.New(metrics.Config{Inputs: inputs, File: *metricsFile, Logf: log.Printf})

	// The token comes from a file, never from a flag: flags show in ps and in
	// the unit. A file that was asked for and cannot be used stops the panel,
	// because a /metrics that quietly accepts anyone would be worse.
	var exporter *export.Exporter
	var token string
	if *tokenFile != "" {
		data, err := os.ReadFile(*tokenFile)
		if err != nil {
			return fmt.Errorf("metrics token: %w", err)
		}
		token = strings.TrimSpace(string(data))
		if token == "" {
			return fmt.Errorf("metrics token: %s is empty", *tokenFile)
		}
		var paths []string
		for _, p := range strings.Split(*diskPaths, ",") {
			if p = strings.TrimSpace(p); p != "" {
				paths = append(paths, p)
			}
		}
		exporter = export.New(export.Config{
			HealthFile: *healthFile, TestsFile: *testsFile, RulesFile: *rulesFile, EveFile: *eveFile,
			DiskPaths: paths, Eve: events, Proc: metrics.Proc,
		})
	}

	handler := api.New(api.Config{
		Policy:      policy,
		AuthFile:    *authFile,
		HealthFile:  *healthFile,
		Lite:        *lite,
		Ctl:         &ctl.Runner{Path: *ctlPath, Sudo: *useSudo, Prefix: splitPrefix(*ctlPrefix)},
		Eve:         events,
		Metrics:     collector,
		TestsFile:   *testsFile,
		EventsFile:  *eventsFile,
		Export:      exporter,
		ExportToken: token,
		Web:         web.Files,
	})
	srv := &http.Server{
		Addr:              *addr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       2 * time.Minute,
		MaxHeaderBytes:    16 << 10,
	}

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		return err
	}
	log.Printf("panel listening on %s, access %s", ln.Addr(), *access)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	// The collector saves metrics.json when ctx ends; shutdown waits for it.
	sampled := make(chan struct{})
	go func() {
		collector.Run(ctx)
		close(sampled)
	}()
	done := make(chan error, 1)
	go func() { done <- srv.Serve(ln) }()

	select {
	case err := <-done:
		stop()
		<-sampled
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		err := srv.Shutdown(shutdown)
		<-sampled
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
}

// splitPrefix turns "a,b,c" into its words; empty is no prefix.
func splitPrefix(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(s, ",")
}
