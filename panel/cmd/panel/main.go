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
	"syscall"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/api"
	"github.com/FlexEbat/dpistack/panel/internal/auth"
	"github.com/FlexEbat/dpistack/panel/internal/ctl"
	"github.com/FlexEbat/dpistack/panel/internal/eve"
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
	ctlPath := fs.String("ctl", "/usr/local/sbin/dpistack-ctl", "dpistack-ctl path")
	eveFile := fs.String("eve-file", "", "eve.json to show on the Events screen; empty turns the viewer off (EVE_FILE=no)")
	useSudo := fs.Bool("sudo", true, "run dpistack-ctl through sudo -n")
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

	handler := api.New(api.Config{
		Policy:     policy,
		AuthFile:   *authFile,
		HealthFile: *healthFile,
		Ctl:        &ctl.Runner{Path: *ctlPath, Sudo: *useSudo},
		Eve:        events,
		Web:        web.Files,
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
	done := make(chan error, 1)
	go func() { done <- srv.Serve(ln) }()

	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdown); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
}
