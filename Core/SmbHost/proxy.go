package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"time"
)

var proxyV2 = []byte("\r\n\r\n\000\r\nQUIT\n")

type ownerListener struct {
	net.Listener
	admit func(source, destination netip.AddrPort) bool
}

func (listener ownerListener) Accept() (net.Conn, error) {
	for {
		connection, err := listener.Listener.Accept()
		if err != nil {
			return nil, err
		}
		_ = connection.SetReadDeadline(time.Now().Add(time.Second))
		from, to, err := readProxy(connection)
		_ = connection.SetReadDeadline(time.Time{})
		if err == nil && listener.admit(from, to) {
			return tailConnection{Conn: connection, from: from}, nil
		}
		_ = connection.Close()
	}
}

type tailConnection struct {
	net.Conn
	from netip.AddrPort
}

func (c tailConnection) RemoteAddr() net.Addr {
	return net.TCPAddrFromAddrPort(c.from)
}

func readProxy(input io.Reader) (source, destination netip.AddrPort, err error) {
	var header [16]byte
	if _, err = io.ReadFull(input, header[:]); err != nil {
		return
	}
	if !bytes.Equal(header[:12], proxyV2) || header[12] != 0x21 {
		err = errors.New("invalid Tailscale proxy header")
		return
	}
	length := int(binary.BigEndian.Uint16(header[14:]))
	if length > 512 {
		err = errors.New("oversized Tailscale proxy header")
		return
	}
	body := make([]byte, length)
	if _, err = io.ReadFull(input, body); err != nil {
		return
	}
	var addressSize int
	switch header[13] {
	case 0x11:
		addressSize = 4
	case 0x21:
		addressSize = 16
	default:
		err = errors.New("Tailscale proxy requires TCP over IPv4 or IPv6")
		return
	}
	if length < addressSize*2+4 {
		err = errors.New("truncated Tailscale proxy address")
		return
	}
	from, _ := netip.AddrFromSlice(body[:addressSize])
	to, _ := netip.AddrFromSlice(body[addressSize : addressSize*2])
	source = netip.AddrPortFrom(from.Unmap(), binary.BigEndian.Uint16(body[addressSize*2:]))
	destination = netip.AddrPortFrom(to.Unmap(), binary.BigEndian.Uint16(body[addressSize*2+2:]))
	return
}
