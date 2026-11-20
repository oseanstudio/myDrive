package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"slices"
	"strings"
	"time"

	smb2 "github.com/cloudsoda/go-smb2"
)

type peerDevice struct {
	ID           string
	HostName     string
	DNSName      string
	UserID       uint64
	Tags         []string
	TailscaleIPs []netip.Addr
	Online       bool
}

func (p peerDevice) address() netip.Addr {
	for _, address := range p.TailscaleIPs {
		if address.Is4() {
			return address
		}
	}
	if len(p.TailscaleIPs) == 0 {
		return netip.Addr{}
	}
	return p.TailscaleIPs[0]
}

func (t *tailscale) devices() ([]peerDevice, error) {
	var status struct {
		BackendState string
		Self         peerDevice
		Peer         map[string]peerDevice
	}
	if err := t.query(&status, "status", "--json"); err != nil || status.BackendState != "Running" {
		return nil, errors.New("Connect to Tailscale before browsing SMB shares.")
	}
	status.Self.Online = true
	devices := []peerDevice{status.Self}
	for _, peer := range status.Peer {
		if peer.UserID == t.owner && len(peer.Tags) == 0 && len(peer.TailscaleIPs) > 0 {
			devices = append(devices, peer)
		}
	}
	slices.SortFunc(devices, func(a, b peerDevice) int { return strings.Compare(a.DNSName, b.DNSName) })
	return devices, nil
}

func resolveDevice(devices []peerDevice, name string) (netip.Addr, error) {
	name = strings.TrimSuffix(strings.TrimSpace(name), ".")
	var matched netip.Addr
	for _, device := range devices {
		for _, address := range device.TailscaleIPs {
			if address.String() == name {
				return address, nil
			}
		}
		if !(device.HostName != "" && strings.EqualFold(device.HostName, name)) &&
			!(device.DNSName != "" && strings.EqualFold(strings.TrimSuffix(device.DNSName, "."), name)) &&
			!(device.ID != "" && device.ID == name) {
			continue
		}
		if matched.IsValid() {
			return netip.Addr{}, errors.New("More than one Tailscale device uses that name. Use its full DNS name or Tailscale IP.")
		}
		matched = device.address()
	}
	if !matched.IsValid() {
		return netip.Addr{}, errors.New("Choose a device from your personal Tailscale device list.")
	}
	return matched, nil
}

type browseRequest struct {
	Action   string `json:"action"`
	Device   string `json:"device"`
	Share    string `json:"share"`
	Path     string `json:"path"`
	Username string `json:"username"`
	Password string `json:"password"`
}

func smbPath(path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return ".", nil
	}
	parts := strings.Split(path, "/")
	for _, part := range parts {
		if part == "" || part == "." || part == ".." ||
			strings.ContainsAny(part, "\\:*?\"<>|\x00\r\n") || strings.HasSuffix(part, " ") || strings.HasSuffix(part, ".") {
			return "", errors.New("Enter a path relative to the SMB share, using forward slashes.")
		}
	}
	return strings.Join(parts, "\\"), nil
}

func browseTailnet(request browseRequest) (any, error) {
	t, err := connectTailscale()
	if err != nil {
		return nil, err
	}
	devices, err := t.devices()
	if err != nil {
		return nil, err
	}
	if request.Action == "devices" {
		result := make([]map[string]any, 0, len(devices))
		for _, device := range devices {
			result = append(result, map[string]any{"id": device.ID, "name": device.HostName,
				"dns_name": strings.TrimSuffix(device.DNSName, "."), "address": device.address(), "online": device.Online})
		}
		return result, nil
	}
	if request.Action != "shares" && request.Action != "browse" {
		return nil, errors.New("Unknown SMB browse operation.")
	}
	address, err := resolveDevice(devices, request.Device)
	if err != nil {
		return nil, err
	}
	if request.Username == "" || request.Password == "" {
		return nil, errors.New("Set MYDRIVE_SMB_USERNAME and MYDRIVE_SMB_PASSWORD for this SMB server.")
	}
	if request.Action == "browse" && (request.Share == "" || request.Share == "." || request.Share == ".." || strings.ContainsAny(request.Share, "/\\:$\x00\r\n")) {
		return nil, errors.New("Choose a shared folder name.")
	}
	path, err := smbPath(request.Path)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var dialer net.Dialer
	wire, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(address.String(), sharePort))
	if err != nil {
		return nil, errors.New("The Tailscale device did not accept an SMB connection on TCP 445.")
	}
	defer wire.Close()
	deadline, _ := ctx.Deadline()
	_ = wire.SetDeadline(deadline)
	domain, user, found := strings.Cut(request.Username, "\\")
	if !found {
		user, domain = domain, ""
	}
	client := smb2.Dialer{
		Negotiator: smb2.Negotiator{RequireMessageSigning: true, SpecifiedDialect: 0x0311},
		Initiator:  &smb2.NTLMInitiator{User: user, Domain: domain, Password: request.Password},
	}
	session, err := client.DialConn(ctx, wire, address.String())
	if err != nil {
		return nil, errors.New("SMB 3.1.1 sign-in failed. Check the share account and password.")
	}
	session = session.WithContext(ctx)
	defer session.Logoff()
	if request.Action == "shares" {
		names, err := session.ListSharenames()
		if err != nil {
			return nil, errors.New("The server could not list its shares. Browse a known share by name.")
		}
		names = slices.DeleteFunc(names, func(name string) bool { return strings.HasSuffix(name, "$") })
		slices.Sort(names)
		return names, nil
	}
	share, err := session.Mount(request.Share)
	if err != nil {
		return nil, errors.New("The SMB shared folder is unavailable for this account.")
	}
	share = share.WithContext(ctx)
	defer share.Umount()
	files, err := share.ReadDir(path)
	if err != nil {
		return nil, errors.New("Could not read that SMB folder.")
	}
	entries := make([]map[string]any, 0, min(len(files), 500))
	for _, file := range files[:min(len(files), 500)] {
		entries = append(entries, map[string]any{"name": file.Name(), "directory": file.IsDir(), "size": file.Size(), "modified": file.ModTime()})
	}
	return map[string]any{"entries": entries, "truncated": len(files) > len(entries)}, nil
}

func browseMain() {
	var request browseRequest
	output := json.NewEncoder(os.Stdout)
	if err := json.NewDecoder(io.LimitReader(os.Stdin, 64*1024)).Decode(&request); err != nil {
		_ = output.Encode(map[string]any{"error": "Invalid SMB browse request."})
		return
	}
	result, err := browseTailnet(request)
	if err != nil {
		_ = output.Encode(map[string]any{"error": err.Error()})
		return
	}
	_ = output.Encode(map[string]any{"data": result})
}
