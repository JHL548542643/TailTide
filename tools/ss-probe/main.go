package main

import (
	"bufio"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha1"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

type nodeConfig struct {
	Name     string
	Server   string
	Port     int
	Cipher   string
	Password string
}

func loadNode(path string) (*nodeConfig, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var raw map[string]interface{}
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, err
	}
	n := &nodeConfig{}
	n.Name, _ = raw["name"].(string)
	n.Server, _ = raw["server"].(string)
	n.Cipher, _ = raw["cipher"].(string)
	n.Password, _ = raw["password"].(string)
	if p, ok := raw["port"].(float64); ok {
		n.Port = int(p)
	}
	if n.Server == "" || n.Port <= 0 || n.Cipher == "" || n.Password == "" {
		return nil, errors.New("node config missing server/port/cipher/password")
	}
	return n, nil
}

func keyLenFor(cipherName string) (int, error) {
	switch strings.ToLower(cipherName) {
	case "aes-256-gcm":
		return 32, nil
	case "aes-128-gcm":
		return 16, nil
	default:
		return 0, fmt.Errorf("unsupported cipher %q (probe supports aes-128-gcm/aes-256-gcm)", cipherName)
	}
}

func evpBytesToKey(password string, keyLen int) []byte {
	var prev []byte
	var out []byte
	for len(out) < keyLen {
		h := md5.New()
		h.Write(prev)
		h.Write([]byte(password))
		prev = h.Sum(nil)
		out = append(out, prev...)
	}
	return out[:keyLen]
}

func hkdfSHA1(ikm, salt, info []byte, length int) []byte {
	extract := hmac.New(sha1.New, salt)
	extract.Write(ikm)
	prk := extract.Sum(nil)
	var t []byte
	var out []byte
	for i := byte(1); len(out) < length; i++ {
		h := hmac.New(sha1.New, prk)
		h.Write(t)
		h.Write(info)
		h.Write([]byte{i})
		t = h.Sum(nil)
		out = append(out, t...)
	}
	return out[:length]
}

type ssConn struct {
	conn       net.Conn
	key        []byte
	keyLen     int
	writeAEAD  cipher.AEAD
	readAEAD   cipher.AEAD
	writeNonce [12]byte
	readNonce  [12]byte
	readInit   bool
	pending    []byte
}

func newSSConn(conn net.Conn, key []byte, keyLen int) (*ssConn, error) {
	salt := make([]byte, keyLen)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}
	subkey := hkdfSHA1(key, salt, []byte("ss-subkey"), keyLen)
	block, err := aes.NewCipher(subkey)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if _, err := conn.Write(salt); err != nil {
		return nil, err
	}
	return &ssConn{conn: conn, key: key, keyLen: keyLen, writeAEAD: aead}, nil
}

func (s *ssConn) initRead() error {
	if s.readInit {
		return nil
	}
	salt := make([]byte, s.keyLen)
	if _, err := io.ReadFull(s.conn, salt); err != nil {
		return err
	}
	subkey := hkdfSHA1(s.key, salt, []byte("ss-subkey"), s.keyLen)
	block, err := aes.NewCipher(subkey)
	if err != nil {
		return err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return err
	}
	s.readAEAD = aead
	s.readInit = true
	return nil
}

func (s *ssConn) incNonce(n *[12]byte) {
	for i := 0; i < len(n); i++ {
		n[i]++
		if n[i] != 0 {
			return
		}
	}
}

func (s *ssConn) sealChunk(payload []byte) ([]byte, error) {
	if len(payload) > 0x3FFF {
		return nil, errors.New("chunk too large")
	}
	var length [2]byte
	binary.BigEndian.PutUint16(length[:], uint16(len(payload)))
	encLen := s.writeAEAD.Seal(nil, s.writeNonce[:], length[:], nil)
	s.incNonce(&s.writeNonce)
	encPayload := s.writeAEAD.Seal(nil, s.writeNonce[:], payload, nil)
	s.incNonce(&s.writeNonce)
	out := make([]byte, 0, len(encLen)+len(encPayload))
	out = append(out, encLen...)
	out = append(out, encPayload...)
	return out, nil
}

func (s *ssConn) Write(p []byte) (int, error) {
	total := 0
	for len(p) > 0 {
		n := len(p)
		if n > 0x3FFF {
			n = 0x3FFF
		}
		chunk, err := s.sealChunk(p[:n])
		if err != nil {
			return total, err
		}
		if _, err := s.conn.Write(chunk); err != nil {
			return total, err
		}
		total += n
		p = p[n:]
	}
	return total, nil
}

func (s *ssConn) readChunk() ([]byte, error) {
	if err := s.initRead(); err != nil {
		return nil, err
	}
	var encLen [2 + 16]byte
	if _, err := io.ReadFull(s.conn, encLen[:]); err != nil {
		return nil, err
	}
	lenBytes, err := s.readAEAD.Open(nil, s.readNonce[:], encLen[:], nil)
	if err != nil {
		return nil, err
	}
	s.incNonce(&s.readNonce)
	if len(lenBytes) != 2 {
		return nil, errors.New("bad length field")
	}
	length := int(binary.BigEndian.Uint16(lenBytes))
	if length > 0x3FFF {
		return nil, errors.New("bad chunk length")
	}
	buf := make([]byte, length+16)
	if _, err := io.ReadFull(s.conn, buf); err != nil {
		return nil, err
	}
	payload, err := s.readAEAD.Open(nil, s.readNonce[:], buf, nil)
	if err != nil {
		return nil, err
	}
	s.incNonce(&s.readNonce)
	return payload, nil
}

func (s *ssConn) Read(p []byte) (int, error) {
	for len(s.pending) == 0 {
		chunk, err := s.readChunk()
		if err != nil {
			return 0, err
		}
		s.pending = chunk
	}
	n := copy(p, s.pending)
	s.pending = s.pending[n:]
	return n, nil
}

func (s *ssConn) Close() error {
	return s.conn.Close()
}

func addrHeader(host string, port int) ([]byte, error) {
	host = strings.Trim(host, "[]")
	var b []byte
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			b = append(b, 0x01)
			b = append(b, v4...)
		} else {
			b = append(b, 0x04)
			b = append(b, ip.To16()...)
		}
	} else {
		if len(host) == 0 || len(host) > 255 {
			return nil, fmt.Errorf("bad domain length %d", len(host))
		}
		b = append(b, 0x03, byte(len(host)))
		b = append(b, []byte(host)...)
	}
	var p [2]byte
	binary.BigEndian.PutUint16(p[:], uint16(port))
	b = append(b, p[:]...)
	return b, nil
}

func dialSS(node *nodeConfig, key []byte, keyLen int, host string, port int) (*ssConn, error) {
	serverAddr := net.JoinHostPort(node.Server, strconv.Itoa(node.Port))
	conn, err := net.DialTimeout("tcp", serverAddr, 10*time.Second)
	if err != nil {
		return nil, err
	}
	ss, err := newSSConn(conn, key, keyLen)
	if err != nil {
		conn.Close()
		return nil, err
	}
	header, err := addrHeader(host, port)
	if err != nil {
		ss.Close()
		return nil, err
	}
	if _, err := ss.Write(header); err != nil {
		ss.Close()
		return nil, err
	}
	return ss, nil
}

type ssProxy struct {
	node   *nodeConfig
	key    []byte
	keyLen int
}

func (p *ssProxy) serve(l net.Listener) error {
	for {
		c, err := l.Accept()
		if err != nil {
			return err
		}
		go p.handle(c)
	}
}

func (p *ssProxy) handle(c net.Conn) {
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
	ss, err := dialSS(p.node, p.key, p.keyLen, host, port)
	if err != nil {
		log.Printf("CONNECT %s:%d failed: %v", host, port, err)
		fmt.Fprint(c, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
		return
	}
	defer ss.Close()
	log.Printf("CONNECT %s:%d", host, port)
	fmt.Fprint(c, "HTTP/1.1 200 Connection Established\r\n\r\n")
	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(ss, br)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(c, ss)
		done <- struct{}{}
	}()
	<-done
}

func maskServer(s string) string {
	if len(s) <= 6 {
		return "***"
	}
	return s[:3] + "***" + s[len(s)-2:]
}

func runTest(listen, target string, timeout time.Duration) error {
	proxyURL, err := url.Parse("http://" + listen)
	if err != nil {
		return err
	}
	tr := &http.Transport{
		Proxy:                  http.ProxyURL(proxyURL),
		TLSHandshakeTimeout:    timeout,
		ResponseHeaderTimeout:  timeout,
	}
	client := &http.Client{Transport: tr, Timeout: timeout}
	start := time.Now()
	resp, err := client.Get(target)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 200))
	log.Printf("test OK target=%s status=%s time=%s body=%q", target, resp.Status, time.Since(start).Round(time.Millisecond), string(body))
	return nil
}

func main() {
	nodePath := flag.String("node", ".cache/ss-node.json", "node JSON path")
	listen := flag.String("listen", "127.0.0.1:7899", "local HTTP proxy listen address")
	runTestFlag := flag.Bool("test", false, "run a control plane test and exit")
	target := flag.String("target", "https://controlplane.tailscale.com/", "test target")
	timeout := flag.Duration("timeout", 25*time.Second, "test timeout")
	flag.Parse()

	node, err := loadNode(*nodePath)
	if err != nil {
		log.Fatalf("load node: %v", err)
	}
	keyLen, err := keyLenFor(node.Cipher)
	if err != nil {
		log.Fatalf("cipher: %v", err)
	}
	key := evpBytesToKey(node.Password, keyLen)
	p := &ssProxy{node: node, key: key, keyLen: keyLen}
	l, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("listen %s: %v", *listen, err)
	}
	log.Printf("ss-probe node=%s server=%s:%d cipher=%s listen=%s", node.Name, maskServer(node.Server), node.Port, node.Cipher, *listen)
	go func() {
		if err := p.serve(l); err != nil {
			log.Printf("serve stopped: %v", err)
		}
	}()
	if *runTestFlag {
		time.Sleep(100 * time.Millisecond)
		if err := runTest(*listen, *target, *timeout); err != nil {
			log.Fatalf("test failed: %v", err)
		}
		return
	}
	select {}
}
