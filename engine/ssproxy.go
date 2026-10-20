package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha1"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

type ssNode struct {
	Name     string
	Server   string
	Port     int
	Cipher   string
	Password string
}

func loadSSNode(path string) (*ssNode, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var n ssNode
	if err := json.Unmarshal(b, &n); err != nil {
		return nil, err
	}
	if n.Server == "" || n.Port <= 0 || n.Cipher == "" || n.Password == "" {
		return nil, errors.New("ss node missing server/port/cipher/password")
	}
	return &n, nil
}

func ssKeyLen(cipherName string) (int, error) {
	switch strings.ToLower(cipherName) {
	case "aes-256-gcm":
		return 32, nil
	case "aes-128-gcm":
		return 16, nil
	default:
		return 0, fmt.Errorf("unsupported ss cipher %q", cipherName)
	}
}

func ssEVPBytesToKey(password string, keyLen int) []byte {
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

func ssHKDFSHA1(ikm, salt, info []byte, length int) []byte {
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
	subkey := ssHKDFSHA1(key, salt, []byte("ss-subkey"), keyLen)
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
	subkey := ssHKDFSHA1(s.key, salt, []byte("ss-subkey"), s.keyLen)
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
		return nil, errors.New("ss chunk too large")
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
		return nil, errors.New("ss bad length field")
	}
	length := int(binary.BigEndian.Uint16(lenBytes))
	if length > 0x3FFF {
		return nil, errors.New("ss bad chunk length")
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

func ssAddrHeader(host string, port int) ([]byte, error) {
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
			return nil, fmt.Errorf("ss bad domain length %d", len(host))
		}
		b = append(b, 0x03, byte(len(host)))
		b = append(b, []byte(host)...)
	}
	var p [2]byte
	binary.BigEndian.PutUint16(p[:], uint16(port))
	b = append(b, p[:]...)
	return b, nil
}

func ssDial(node *ssNode, key []byte, keyLen int, host string, port int) (*ssConn, error) {
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
	header, err := ssAddrHeader(host, port)
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

type ssUpstream struct {
	nodes []*ssNode
}

func (u *ssUpstream) name() string {
	return "ss"
}

func (u *ssUpstream) dial(host string, port int) (io.ReadWriteCloser, error) {
	var lastErr error
	for _, node := range u.nodes {
		keyLen, err := ssKeyLen(node.Cipher)
		if err != nil {
			lastErr = err
			continue
		}
		key := ssEVPBytesToKey(node.Password, keyLen)
		conn, err := ssDial(node, key, keyLen, host, port)
		if err == nil {
			logf("local proxy: %s:%d via ss node %s", host, port, node.Name)
			return conn, nil
		}
		lastErr = err
		logf("local proxy: ss node %s failed: %v", node.Name, err)
	}
	if lastErr == nil {
		lastErr = errors.New("no ss nodes configured")
	}
	return nil, lastErr
}
