package main

import (
	"bufio"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const localProxyListen = "127.0.0.1:7899"

type localUpstream interface {
	name() string
	dial(host string, port int) (io.ReadWriteCloser, error)
}

type directUpstream struct{}

func (directUpstream) name() string { return "direct" }

func (directUpstream) dial(host string, port int) (io.ReadWriteCloser, error) {
	return net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), 10*time.Second)
}

type externalUpstream struct {
	proxyURL *url.URL
}

func (u *externalUpstream) name() string { return "external" }

func (u *externalUpstream) dial(host string, port int) (io.ReadWriteCloser, error) {
	scheme := strings.ToLower(u.proxyURL.Scheme)
	addr := u.proxyURL.Host
	if u.proxyURL.Port() == "" {
		if scheme == "https" {
			addr = net.JoinHostPort(u.proxyURL.Hostname(), "443")
		} else {
			addr = net.JoinHostPort(u.proxyURL.Hostname(), "80")
		}
	}
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	var conn net.Conn
	var err error
	if scheme == "https" {
		conn, err = tls.DialWithDialer(dialer, "tcp", addr, &tls.Config{ServerName: u.proxyURL.Hostname()})
	} else {
		conn, err = dialer.Dial("tcp", addr)
	}
	if err != nil {
		return nil, err
	}
	target := net.JoinHostPort(host, strconv.Itoa(port))
	if _, err := fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target, target); err != nil {
		conn.Close()
		return nil, err
	}
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodConnect})
	if err != nil {
		conn.Close()
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		resp.Body.Close()
		conn.Close()
		return nil, fmt.Errorf("external proxy CONNECT returned %d", resp.StatusCode)
	}
	return &bufferedConn{Conn: conn, r: br}, nil
}

type bufferedConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) {
	return c.r.Read(p)
}

type localProxy struct {
	upstream localUpstream
}

func (p *localProxy) serve(l net.Listener) error {
	for {
		c, err := l.Accept()
		if err != nil {
			return err
		}
		go p.handle(c)
	}
}

func (p *localProxy) handle(c net.Conn) {
	defer c.Close()
	br := bufio.NewReader(c)
	req, err := http.ReadRequest(br)
	if err != nil {
		return
	}
	if req.Method != http.MethodConnect {
		fmt.Fprint(c, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
		return
	}
	target := req.Host
	if target == "" && req.URL != nil {
		target = req.URL.Host
	}
	host, portStr, err := net.SplitHostPort(target)
	if err != nil {
		host = strings.Trim(target, "[]")
		portStr = "443"
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port <= 0 || port > 65535 {
		fmt.Fprint(c, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
		return
	}
	up, err := p.upstream.dial(host, port)
	if err != nil {
		logf("local proxy CONNECT %s:%d failed (upstream=%s): %v", host, port, p.upstream.name(), err)
		fmt.Fprint(c, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
		return
	}
	defer up.Close()
	logf("local proxy CONNECT %s:%d via %s", host, port, p.upstream.name())
	fmt.Fprint(c, "HTTP/1.1 200 Connection Established\r\n\r\n")
	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(up, br)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(c, up)
		done <- struct{}{}
	}()
	<-done
}

var (
	localProxyMu       sync.Mutex
	localProxyListener net.Listener
	localProxyRunning  bool
)

func startLocalProxy(upstream localUpstream) error {
	localProxyMu.Lock()
	defer localProxyMu.Unlock()
	if localProxyRunning {
		stopLocalProxyLocked()
	}
	p := &localProxy{upstream: upstream}
	var l net.Listener
	var err error
	for i := 0; i < 5; i++ {
		l, err = net.Listen("tcp", localProxyListen)
		if err == nil {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if err != nil {
		return err
	}
	localProxyListener = l
	localProxyRunning = true
	go func() {
		if err := p.serve(l); err != nil {
			logf("local proxy serve stopped: %v", err)
		}
	}()
	os.Setenv("HTTPS_PROXY", "http://"+localProxyListen)
	os.Setenv("HTTP_PROXY", "http://"+localProxyListen)
	logf("local proxy started upstream=%s listen=%s", upstream.name(), localProxyListen)
	return nil
}

func stopLocalProxyLocked() {
	if localProxyListener != nil {
		_ = localProxyListener.Close()
		localProxyListener = nil
	}
	if localProxyRunning {
		logf("local proxy stopped")
	}
	localProxyRunning = false
}

func stopLocalProxy() {
	localProxyMu.Lock()
	defer localProxyMu.Unlock()
	stopLocalProxyLocked()
}

func sameSSNode(a, b *ssNode) bool {
	return a.Server == b.Server && a.Port == b.Port
}

func buildLocalUpstream(stateDir string, externalURL string) (localUpstream, string, error) {
	ssPath := filepath.Join(stateDir, "ss-node.json")
	if _, err := os.Stat(ssPath); err == nil {
		primary, err := loadSSNode(ssPath)
		if err != nil {
			logf("local proxy: ss-node.json invalid: %v", err)
		} else {
			nodes := []*ssNode{primary}
			yamlPath := filepath.Join(stateDir, "clash-config.yaml")
			if candidates, err := ssNodesFromYAML(yamlPath); err == nil {
				for _, n := range candidates {
					if !sameSSNode(n, primary) {
						nodes = append(nodes, n)
					}
				}
			} else {
				logf("local proxy: no yaml candidates: %v", err)
			}
			return &ssUpstream{nodes: nodes}, fmt.Sprintf("ss(%d)", len(nodes)), nil
		}
	}
	if strings.TrimSpace(externalURL) != "" {
		u, err := url.Parse(strings.TrimSpace(externalURL))
		if err != nil || u.Host == "" || (strings.ToLower(u.Scheme) != "http" && strings.ToLower(u.Scheme) != "https") {
			return nil, "", fmt.Errorf("invalid external proxy %q", externalURL)
		}
		return &externalUpstream{proxyURL: u}, "external", nil
	}
	return &directUpstream{}, "direct", nil
}
