package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/cloudsoda/go-smb2"
	"github.com/go-filesystems/osfs"
	"github.com/go-filesystems/smb"
)

var testFrom = netip.MustParseAddrPort("100.64.0.7:12000")
var testTo = netip.MustParseAddrPort("100.64.0.8:445")

func header(from, to netip.AddrPort) []byte {
	wire := append([]byte(nil), proxyV2...)
	wire = append(wire, 0x21, 0x11, 0, 12)
	wire = append(wire, from.Addr().AsSlice()...)
	wire = append(wire, to.Addr().AsSlice()...)
	wire = binary.BigEndian.AppendUint16(wire, from.Port())
	return binary.BigEndian.AppendUint16(wire, to.Port())
}

type observedConn struct {
	net.Conn
	encrypted atomic.Bool
}

func (c *observedConn) Write(p []byte) (int, error) {
	if bytes.HasPrefix(p, []byte{0xfd, 'S', 'M', 'B'}) || (len(p) >= 8 && bytes.Equal(p[4:8], []byte{0xfd, 'S', 'M', 'B'})) {
		c.encrypted.Store(true)
	}
	return c.Conn.Write(p)
}

func TestEncryptedTransferContinuesAfterConnectionDrops(t *testing.T) {
	directory := t.TempDir()
	root, err := osfs.Open(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	server := smb.New()
	server.EncryptData = true
	server.RequireSigning = true
	server.AddUser(username, "test only random-password")
	defer server.Close()
	if err := server.Share("fixture", root, smb.AllowUsers(username), smb.RequireEncryption()); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go server.Serve(ownerListener{Listener: listener, admit: func(from, to netip.AddrPort) bool {
		return from == testFrom && to == testTo
	}})

	for _, introduction := range [][]byte{make([]byte, 16), header(netip.MustParseAddrPort("100.64.0.9:12000"), testTo)} {
		direct, err := net.DialTimeout("tcp4", listener.Addr().String(), time.Second)
		if err != nil {
			t.Fatal(err)
		}
		_ = direct.SetDeadline(time.Now().Add(time.Second))
		_, err = direct.Write(introduction)
		if err == nil {
			_, err = direct.Read(make([]byte, 1))
		}
		direct.Close()
		if err != io.EOF {
			t.Fatalf("unverified connection did not close: %v", err)
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	connect := func(dialect uint16, secret string) (*observedConn, *smb2.Share, error) {
		socket, err := net.DialTimeout("tcp", listener.Addr().String(), time.Second)
		if err != nil {
			return nil, nil, err
		}
		if _, err = socket.Write(header(testFrom, testTo)); err != nil {
			socket.Close()
			return nil, nil, err
		}
		wire := &observedConn{Conn: socket}
		client := smb2.Dialer{
			Initiator:  &smb2.NTLMInitiator{User: username, Password: secret},
			Negotiator: smb2.Negotiator{SpecifiedDialect: dialect},
		}
		session, err := client.DialConn(ctx, wire, "fixture-host")
		if err != nil {
			wire.Close()
			return nil, nil, err
		}
		share, err := session.WithContext(ctx).Mount("fixture")
		return wire, share, err
	}
	if wire, _, err := connect(0x0210, "test only random-password"); err == nil {
		wire.Close()
		t.Fatal("SMB without encryption was admitted")
	}
	if wire, _, err := connect(0x0311, "wrong test password"); err == nil {
		wire.Close()
		t.Fatal("a wrong SMB password was admitted")
	}

	first, share, err := connect(0x0311, "test only random-password")
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	prefix := bytes.Repeat([]byte{0x24}, 512*1024)
	suffix := bytes.Repeat([]byte{0x36}, 512*1024)
	partial, err := share.Create("large.part")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := partial.Write(prefix); err != nil {
		t.Fatal(err)
	}
	if err := partial.Sync(); err != nil {
		t.Fatal(err)
	}
	if !first.encrypted.Load() {
		t.Fatal("the first write did not use an SMB3 encrypted transform")
	}
	first.Close() // Simulate losing the network with the file handle still open.

	second, share, err := connect(0x0311, "test only random-password")
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	status, err := share.Stat("large.part")
	if err != nil || status.Size() != int64(len(prefix)) {
		t.Fatalf("saved bytes were not available after reconnect: %v", err)
	}
	part, err := share.OpenFile("large.part", os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Seek(int64(len(prefix)), io.SeekStart); err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(suffix); err != nil {
		t.Fatal(err)
	}
	if err := part.Close(); err != nil {
		t.Fatal(err)
	}
	if err := share.Rename("large.part", "large.bin"); err != nil {
		t.Fatal(err)
	}
	if !second.encrypted.Load() {
		t.Fatal("resumed write did not use an SMB3 encrypted transform")
	}
	actual, err := os.ReadFile(filepath.Join(directory, "large.bin"))
	if err != nil || !bytes.Equal(actual, append(prefix, suffix...)) {
		t.Fatal("completed file differs from the bytes sent")
	}
}

func TestServeChecksBackgroundPortAndFunnel(t *testing.T) {
	c := serveConfig{
		TCP: map[string]serveHandler{"445": {TCPForward: "127.0.0.1:4567"}},
		Foreground: map[string]serveConfig{"other": {
			AllowFunnel: map[string]bool{"host.example:445": true},
		}},
	}
	count, forwards, public := c.routes()
	if count != 1 || len(forwards) != 1 || !public {
		t.Fatal("existing Serve configuration or a public route was missed")
	}
}
