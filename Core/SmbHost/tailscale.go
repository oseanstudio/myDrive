package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"time"
)

const sharePort = "445"

type tailscale struct {
	executable string
	owner      uint64
	addresses  []netip.Addr
}

func connectTailscale() (*tailscale, error) {
	var candidates []string
	switch runtime.GOOS {
	case "windows":
		for _, key := range []string{"ProgramFiles", "ProgramFiles(x86)"} {
			if directory := os.Getenv(key); directory != "" {
				candidates = append(candidates, filepath.Join(directory, "Tailscale", "tailscale.exe"))
			}
		}
	case "darwin":
		candidates = append(candidates, "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
			"/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale")
	}
	candidates = append(candidates, "tailscale")
	for _, candidate := range candidates {
		executable, err := exec.LookPath(candidate)
		if err != nil {
			continue
		}
		client := &tailscale{executable: executable}
		var state struct {
			BackendState string
			Self         struct {
				UserID       uint64
				Tags         []string
				TailscaleIPs []netip.Addr
			}
		}
		if client.query(&state, "status", "--json", "--peers=false") == nil &&
			state.BackendState == "Running" && state.Self.UserID != 0 &&
			len(state.Self.Tags) == 0 && len(state.Self.TailscaleIPs) != 0 {
			client.owner = state.Self.UserID
			client.addresses = state.Self.TailscaleIPs
			return client, nil
		}
	}
	return nil, errors.New("Connect Tailscale on this computer with your personal account before sharing.")
}

func (t *tailscale) command(ctx context.Context, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, t.executable, args...)
	cmd.Env = append(os.Environ(), "TAILSCALE_BE_CLI=1")
	hideConsole(cmd)
	return cmd
}

func (t *tailscale) query(result any, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	output, err := t.command(ctx, args...).Output()
	if err != nil {
		return err
	}
	return json.Unmarshal(output, result)
}

func (t *tailscale) admits(source, destination netip.AddrPort) bool {
	if destination.Port() != 445 || !slices.Contains(t.addresses, destination.Addr().Unmap()) {
		return false
	}
	var identity struct {
		Node struct {
			User      uint64
			Tags      []string
			Addresses []netip.Prefix
		}
		UserProfile struct{ ID uint64 }
	}
	address := source.Addr().Unmap()
	if t.query(&identity, "whois", "--json", address.String()) != nil ||
		identity.UserProfile.ID != t.owner || identity.Node.User != t.owner || len(identity.Node.Tags) != 0 {
		return false
	}
	// A network advertised by a subnet router is not an address of the device itself.
	return slices.Contains(identity.Node.Addresses, netip.PrefixFrom(address, address.BitLen()))
}

type serveHandler struct {
	TCPForward    string
	ProxyProtocol int
	TerminateTLS  string
}

type serveConfig struct {
	TCP         map[string]serveHandler
	AllowFunnel map[string]bool
	Foreground  map[string]serveConfig
}

func (t *tailscale) configuration() (serveConfig, error) {
	var config serveConfig
	err := t.query(&config, "serve", "status", "--json")
	return config, err
}

func (c serveConfig) routes() (reserved int, private []serveHandler, public bool) {
	if handler, inUse := c.TCP[sharePort]; inUse {
		reserved++
		if handler.TCPForward != "" {
			private = append(private, handler)
		}
	}
	for endpoint, enabled := range c.AllowFunnel {
		if _, port, err := net.SplitHostPort(endpoint); err == nil && port == sharePort && enabled {
			public = true
		}
	}
	for _, foreground := range c.Foreground {
		count, handlers, funnel := foreground.routes()
		reserved += count
		private = append(private, handlers...)
		public = public || funnel
	}
	return reserved, private, public
}

type tailRoute struct {
	cancel context.CancelFunc
	done   chan struct{}
}

func (t *tailscale) publish(address string) (*tailRoute, error) {
	existing, err := t.configuration()
	if err != nil {
		return nil, errors.New("myDrive could not read Tailscale Serve settings. Update Tailscale and try again.")
	}
	if count, _, funnel := existing.routes(); count != 0 || funnel {
		return nil, errors.New("Tailscale Serve already uses port 445 on this device.")
	}

	// The foreground route belongs to this process and is withdrawn when its
	// local API connection closes, including if myDrive exits unexpectedly.
	ctx, cancel := context.WithCancel(context.Background())
	cmd := t.command(ctx, "serve", "--tcp="+sharePort, "--proxy-protocol=2", "tcp://"+address)
	if err := cmd.Start(); err != nil {
		cancel()
		return nil, errors.New("myDrive could not start Tailscale Serve.")
	}
	route := &tailRoute{cancel: cancel, done: make(chan struct{})}
	go func() {
		_ = cmd.Wait()
		close(route.done)
	}()
	deadline := time.Now().Add(10 * time.Second)
	expected := serveHandler{TCPForward: address, ProxyProtocol: 2}
	for time.Now().Before(deadline) {
		select {
		case <-route.done:
			cancel()
			return nil, errors.New("Tailscale would not start private TCP forwarding. Check Serve permissions and update Tailscale.")
		case <-time.After(200 * time.Millisecond):
		}
		active, err := t.configuration()
		if err == nil {
			count, handlers, funnel := active.routes()
			// Confirm the mapping is a foreground instance that this process owns.
			if count == 1 && len(handlers) == 1 && handlers[0] == expected && !funnel && active.TCP[sharePort] == (serveHandler{}) {
				return route, nil
			}
			if funnel || (count > 0 && !slices.Contains(handlers, expected)) {
				break
			}
		}
	}
	route.close()
	return nil, fmt.Errorf("myDrive could not verify private Tailscale forwarding on port %s.", sharePort)
}

func (r *tailRoute) close() {
	r.cancel()
	<-r.done
}

func (t *tailscale) host() string {
	for _, address := range t.addresses {
		if address.Is4() {
			return address.String()
		}
	}
	return "[" + t.addresses[0].String() + "]"
}
