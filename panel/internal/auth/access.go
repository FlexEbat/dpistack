package auth

import (
	"fmt"
	"net/netip"
	"strings"
)

// Policy decides which client addresses may reach the panel (tech.md 4.8).
type Policy struct {
	mode string
	lan  []netip.Prefix
}

// NewPolicy builds the policy for ACCESS_MODE. lanCIDR is required for
// "lan" and optional for "nginx", where nginx already filters the network.
// lanCIDR is one network or several separated by commas (LAN_CIDR, v0.31.0:
// for example the LAN and the network of a WireGuard container).
func NewPolicy(mode, lanCIDR string) (*Policy, error) {
	p := &Policy{mode: mode}
	switch mode {
	case "localhost":
	case "lan", "nginx":
		if lanCIDR != "" {
			for _, part := range strings.Split(lanCIDR, ",") {
				pfx, err := netip.ParsePrefix(strings.TrimSpace(part))
				if err != nil {
					return nil, fmt.Errorf("lan-cidr %q: %w", lanCIDR, err)
				}
				p.lan = append(p.lan, pfx.Masked())
			}
		} else if mode == "lan" {
			return nil, fmt.Errorf("access mode lan needs a lan-cidr")
		}
	default:
		return nil, fmt.Errorf("unknown access mode %q", mode)
	}
	return p, nil
}

// ClientIP returns the address the request comes from. X-Forwarded-For is
// read only when the connection itself comes from the loopback address,
// where the local nginx sits; from anyone else the header is a forgery. The
// last entry is the one the trusted proxy appended.
func (p *Policy) ClientIP(remoteAddr string, xff []string) (peer, client netip.Addr, err error) {
	ap, err := netip.ParseAddrPort(remoteAddr)
	if err != nil {
		return peer, client, fmt.Errorf("remote address %q: %w", remoteAddr, err)
	}
	peer = ap.Addr().Unmap()
	if !peer.IsLoopback() || len(xff) == 0 {
		return peer, peer, nil
	}
	entries := strings.Split(xff[len(xff)-1], ",")
	last := strings.TrimSpace(entries[len(entries)-1])
	client, err = netip.ParseAddr(last)
	if err != nil {
		return peer, client, fmt.Errorf("X-Forwarded-For %q: %w", last, err)
	}
	return peer, client.Unmap(), nil
}

// Allowed reports whether a request from client, arriving over a connection
// from peer, may use the panel.
func (p *Policy) Allowed(peer, client netip.Addr) bool {
	switch p.mode {
	case "localhost":
		return client.IsLoopback()
	case "lan":
		return p.inLAN(client)
	default:
		return peer.IsLoopback() && (len(p.lan) == 0 || p.inLAN(client))
	}
}

// inLAN reports whether addr is inside any of the allowed networks.
func (p *Policy) inLAN(addr netip.Addr) bool {
	for _, pfx := range p.lan {
		if pfx.Contains(addr) {
			return true
		}
	}
	return false
}
