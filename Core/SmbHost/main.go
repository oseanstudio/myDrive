package main

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/go-filesystems/osfs"
	"github.com/go-filesystems/smb"
)

const username = "mydrive"

var validName = regexp.MustCompile("^[A-Za-z0-9][A-Za-z0-9 _-]{0,62}$")

type request struct {
	Action   string `json:"action"`
	Name     string `json:"name"`
	Folder   string `json:"folder"`
	Writable bool   `json:"writable"`
}

type details struct {
	Name     string `json:"name"`
	Host     string `json:"host"`
	Username string `json:"username"`
	Password string `json:"password"`
	Writable bool   `json:"writable"`
}

type reply struct {
	Error  string    `json:"error,omitempty"`
	Share  *details  `json:"share,omitempty"`
	Shares []details `json:"shares,omitempty"`
}

type service struct {
	server   *smb.Server
	listener net.Listener
	route    *tailRoute
	net      *tailscale
	password string
	shares   []details
	roots    []*osfs.FS
	mu       sync.Mutex
	closed   bool
}

func start() (*service, error) {
	t, err := connectTailscale()
	if err != nil {
		return nil, err
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, errors.New("myDrive could not start a private local SMB listener.")
	}
	server := smb.New()
	server.EncryptData = true
	server.RequireSigning = true
	server.PreAuthTimeout = 10 * time.Second
	server.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	secret := make([]byte, 24)
	rand.Read(secret)
	password := base64.RawURLEncoding.EncodeToString(secret)
	server.AddUser(username, password)
	route, err := t.publish(listener.Addr().String())
	if err != nil {
		_ = listener.Close()
		return nil, err
	}
	host := &service{server: server, listener: listener, net: t, route: route, password: password}
	go func() {
		_ = server.Serve(ownerListener{Listener: listener, admit: t.admits})
		host.close()
	}()
	go func() {
		<-route.done
		host.close()
	}()
	return host, nil
}

func (s *service) close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	defer s.mu.Unlock()
	_ = s.server.Close()
	_ = s.listener.Close()
	for _, root := range s.roots {
		_ = root.Close()
	}
	s.roots = nil
	s.shares = nil
	s.password = ""
	s.route.close()
}

func (s *service) active() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return !s.closed
}

func (s *service) add(r request) (details, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return details{}, errors.New("Tailscale sharing stopped. Connect Tailscale and try again.")
	}
	for _, share := range s.shares {
		if strings.EqualFold(share.Name, r.Name) {
			return details{}, errors.New("Choose a different name for this SMB share.")
		}
	}
	if len(s.shares) >= 32 {
		return details{}, errors.New("This session already has 32 shared folders.")
	}

	opts := []osfs.Option{osfs.MaxReadFile(16 << 20)}
	if !r.Writable {
		opts = append(opts, osfs.ReadOnly())
	}
	root, err := osfs.Open(r.Folder, opts...)
	if err != nil {
		return details{}, errors.New("myDrive could not open the selected folder.")
	}
	permissions := []smb.ShareOption{smb.AllowUsers(username), smb.RequireEncryption()}
	if !r.Writable {
		permissions = append(permissions, smb.ReadOnly())
	}
	if err := s.server.Share(r.Name, root, permissions...); err != nil {
		_ = root.Close()
		return details{}, errors.New("myDrive could not add the SMB share.")
	}
	share := details{r.Name, s.net.host(), username, s.password, r.Writable}
	s.roots = append(s.roots, root)
	s.shares = append(s.shares, share)
	return share, nil
}

func validate(r request) error {
	if !validName.MatchString(r.Name) || strings.TrimSpace(r.Name) != r.Name {
		return errors.New("Use 1–63 letters, numbers, spaces, underscores or hyphens for the share name.")
	}
	folder := filepath.Clean(r.Folder)
	if !filepath.IsAbs(folder) || filepath.Dir(folder) == folder {
		return errors.New("Select a folder inside a drive.")
	}
	entry, err := os.Stat(folder)
	if err != nil || !entry.IsDir() {
		return errors.New("Select an existing folder.")
	}
	return nil
}

func main() {
	var host *service
	defer func() {
		if host != nil {
			host.close()
		}
	}()
	lines := bufio.NewScanner(os.Stdin)
	output := json.NewEncoder(os.Stdout)
	for lines.Scan() {
		var r request
		var response reply
		var err error
		if json.Unmarshal(lines.Bytes(), &r) != nil {
			err = errors.New("Invalid SMB sharing request.")
		} else {
			switch r.Action {
			case "add":
				if err = validate(r); err == nil {
					newHost := host == nil || !host.active()
					if newHost {
						host, err = start()
					}
					if err == nil {
						var created details
						created, err = host.add(r)
						if err == nil {
							response.Share = &created
						} else if newHost {
							host.close()
							host = nil
						}
					}
				}
			case "list":
				if host != nil {
					host.mu.Lock()
					response.Shares = append([]details(nil), host.shares...)
					host.mu.Unlock()
				}
			case "stop":
				if host != nil {
					host.close()
					host = nil
				}
			default:
				err = errors.New("Unknown SMB sharing request.")
			}
		}
		if err != nil {
			response.Error = err.Error()
		}
		if output.Encode(response) != nil {
			return
		}
	}
}
