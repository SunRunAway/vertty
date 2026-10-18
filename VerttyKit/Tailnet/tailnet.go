// Package main is the Tailscale device Vertty embeds (tsnet), built as a C
// static library for VerttyKit's VerttyTailnet (scripts/build-tailnet.sh).
//
// One device per app. A computer serves its remote connections on it,
// forwarding them to the remote server on 127.0.0.1 once it has checked the
// other device belongs to the same user. A client dials a computer through
// it and gets a one-time port on 127.0.0.1 to open the WebSocket on.
//
// Strings returned to C are malloc'ed: free them with VTFree.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"runtime"
	"strconv"
	"sync"
	"syscall"
	"time"
	"unsafe" // also for go:linkname

	"tailscale.com/client/local"
	"tailscale.com/tsnet"
)

func init() {
	// Don't upload the device's logs to Tailscale.
	os.Setenv("TS_NO_LOGS_NO_SUPPORT", "true")
	// Started again, Tailscale would report running at once with the
	// network map it cached on disk, before the live one comes in; the
	// cached one lists no other devices, so the computer to connect to
	// looked gone. Without it, running means the list is the live one.
	os.Setenv("TS_USE_CACHED_NETMAP", "false")
	// On the Mac, Tailscale's peer API (Taildrop and the like) would also
	// listen on a port of every interface, where the firewall asks about
	// it. When that listener can't be made, tsnet serves the peer API in
	// its user-space network stack alone, on the tailnet. (Failing the hook
	// itself instead crashes Tailscale; iOS has no fallback, and no
	// firewall to ask.)
	if runtime.GOOS == "darwin" {
		peerAPIListenConfig = func(config *net.ListenConfig, _ netip.Addr, _ int) error {
			config.Control = func(string, string, syscall.RawConn) error {
				return errors.New("the peer API is served on the tailnet only")
			}
			return nil
		}
	}
}

// The hook ipnlocal calls before the peer API's kernel listener; set in
// init. Linking to it fails the build if Tailscale renames it.
//
//go:linkname peerAPIListenConfig tailscale.com/ipn/ipnlocal.initListenConfig
var peerAPIListenConfig func(config *net.ListenConfig, addr netip.Addr, tunIfIndex int) error

var (
	mu      sync.Mutex
	srv     *tsnet.Server
	lc      *local.Client
	serving net.Listener
)

func cstr(s string) *C.char { return C.CString(s) }

func cerr(err error) *C.char {
	if err == nil {
		return nil
	}
	return cstr(err.Error())
}

func current() (*tsnet.Server, *local.Client, error) {
	mu.Lock()
	defer mu.Unlock()
	if srv == nil {
		return nil, nil, errors.New("Tailscale isn't running")
	}
	return srv, lc, nil
}

//export VTFree
func VTFree(p *C.char) { C.free(unsafe.Pointer(p)) }

// VTStart starts the device with its state in dir. Does nothing if it's
// running. Without a saved login it waits for one (see VTStatus).
//
//export VTStart
func VTStart(dir, hostname *C.char) *C.char {
	mu.Lock()
	defer mu.Unlock()
	if srv != nil {
		return nil
	}
	s := &tsnet.Server{
		Dir:      C.GoString(dir),
		Hostname: C.GoString(hostname),
		Logf:     func(string, ...any) {},
		UserLogf: func(string, ...any) {},
	}
	if err := s.Start(); err != nil {
		s.Close()
		return cerr(err)
	}
	c, err := s.LocalClient()
	if err != nil {
		s.Close()
		return cerr(err)
	}
	srv, lc = s, c
	return nil
}

//export VTStop
func VTStop() {
	mu.Lock()
	s := srv
	srv, lc = nil, nil
	if serving != nil {
		serving.Close()
		serving = nil
	}
	mu.Unlock()
	if s != nil {
		s.Close()
	}
}

type peer struct {
	ID       string `json:"id"`
	HostName string `json:"hostName"`
	DNSName  string `json:"dnsName"`
	OS       string `json:"os"`
	Online   bool   `json:"online"`
	SameUser bool   `json:"sameUser"`
	IP       string `json:"ip"`
}

type status struct {
	// "Stopped" when not started, else the backend's state: NoState,
	// Starting, NeedsLogin, NeedsMachineAuth, Stopped or Running.
	State   string `json:"state"`
	AuthURL string `json:"authURL,omitempty"`
	User    string `json:"user,omitempty"`
	Name    string `json:"name,omitempty"`
	Peers   []peer `json:"peers"`
	Error   string `json:"error,omitempty"`
}

// VTStatus returns the device's status as JSON (see status).
//
//export VTStatus
func VTStatus() *C.char {
	out := status{State: "Stopped", Peers: []peer{}}
	if _, c, err := current(); err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if st, err := c.Status(ctx); err != nil {
			out.Error = err.Error()
		} else {
			out.State = st.BackendState
			out.AuthURL = st.AuthURL
			if st.Self != nil {
				if u, ok := st.User[st.Self.UserID]; ok && out.State == "Running" {
					out.User = u.LoginName
				}
				out.Name = st.Self.HostName
				if n := firstLabel(st.Self.DNSName); n != "" {
					out.Name = n
				}
				for _, p := range st.Peer {
					q := peer{
						ID:       string(p.ID),
						HostName: p.HostName,
						DNSName:  p.DNSName,
						OS:       p.OS,
						Online:   p.Online,
						SameUser: p.UserID == st.Self.UserID,
					}
					for _, ip := range p.TailscaleIPs {
						if ip.Is4() {
							q.IP = ip.String()
						}
					}
					out.Peers = append(out.Peers, q)
				}
			}
		}
	}
	b, _ := json.Marshal(out)
	return cstr(string(b))
}

func firstLabel(dnsName string) string {
	for i := 0; i < len(dnsName); i++ {
		if dnsName[i] == '.' {
			return dnsName[:i]
		}
	}
	return dnsName
}

// VTLogin asks Tailscale for the sign-in URL (it reuses one it has), waits
// up to timeoutMs for it and returns it in url (malloc'ed; nil when the
// device is signed in by then). The login tsnet starts by itself when it
// starts signed out doesn't bring a URL.
//
//export VTLogin
func VTLogin(timeoutMs C.int, url **C.char) *C.char {
	_, c, err := current()
	if err != nil {
		return cerr(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	if err := c.StartLoginInteractive(ctx); err != nil {
		return cerr(err)
	}
	for {
		st, err := c.StatusWithoutPeers(ctx)
		if err != nil {
			return cerr(err)
		}
		if st.BackendState == "Running" {
			return nil
		}
		if st.AuthURL != "" {
			*url = cstr(st.AuthURL)
			return nil
		}
		select {
		case <-ctx.Done():
			return cerr(errors.New("Tailscale didn't send a sign-in page in time"))
		case <-time.After(100 * time.Millisecond):
		}
	}
}

//export VTLogout
func VTLogout() *C.char {
	_, c, err := current()
	if err != nil {
		return cerr(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return cerr(c.Logout(ctx))
}

// VTServe accepts connections on the tailnet's port and forwards those from
// the same user's devices to 127.0.0.1:localPort. Replaces an earlier
// VTServe.
//
//export VTServe
func VTServe(port, localPort C.int) *C.char {
	s, c, err := current()
	if err != nil {
		return cerr(err)
	}
	ln, err := s.Listen("tcp", ":"+strconv.Itoa(int(port)))
	if err != nil {
		return cerr(err)
	}
	mu.Lock()
	if serving != nil {
		serving.Close()
	}
	serving = ln
	mu.Unlock()
	local := net.JoinHostPort("127.0.0.1", strconv.Itoa(int(localPort)))
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go forwardIn(c, conn, local)
		}
	}()
	return nil
}

//export VTStopServing
func VTStopServing() {
	mu.Lock()
	defer mu.Unlock()
	if serving != nil {
		serving.Close()
		serving = nil
	}
}

func forwardIn(c *local.Client, conn net.Conn, local string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	who, err := c.WhoIs(ctx, conn.RemoteAddr().String())
	if err != nil || who.Node == nil {
		conn.Close()
		return
	}
	self, err := c.StatusWithoutPeers(ctx)
	if err != nil || self.Self == nil || who.Node.User != self.Self.UserID {
		conn.Close()
		return
	}
	out, err := net.DialTimeout("tcp", local, 5*time.Second)
	if err != nil {
		conn.Close()
		return
	}
	pipe(conn, out)
}

// VTDial connects to host:port on the tailnet, then listens on a port of
// 127.0.0.1 (returned in localPort) for one connection, which it joins to
// that one. The port closes after 10 seconds unused.
//
//export VTDial
func VTDial(host *C.char, port, timeoutMs C.int, localPort *C.int) *C.char {
	s, _, err := current()
	if err != nil {
		return cerr(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	remote, err := s.Dial(ctx, "tcp", net.JoinHostPort(C.GoString(host), strconv.Itoa(int(port))))
	if err != nil {
		return cerr(err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		remote.Close()
		return cerr(err)
	}
	*localPort = C.int(ln.Addr().(*net.TCPAddr).Port)
	go func() {
		defer ln.Close()
		ln.(*net.TCPListener).SetDeadline(time.Now().Add(10 * time.Second))
		conn, err := ln.Accept()
		if err != nil {
			remote.Close()
			return
		}
		pipe(conn, remote)
	}()
	return nil
}

// pipe copies both ways until either side closes.
func pipe(a, b net.Conn) {
	done := make(chan struct{}, 2)
	cp := func(dst, src net.Conn) {
		io.Copy(dst, src)
		done <- struct{}{}
	}
	go cp(a, b)
	go cp(b, a)
	<-done
	a.Close()
	b.Close()
	<-done
}

func main() {}
