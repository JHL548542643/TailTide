// Package main is the c-shared bridge between the HarmonyOS VPN extension
// and the Tailscale engine (tsnet).
//
// 设计纪律（见 docs/decisions/005-P2接入Tailscale官方引擎方案.md）：
//   - 所有导出函数 recover panic，以 JSON 错误返回，绝不跨 C 边界崩溃
//   - 轮询式 API（无跨线程回调）
//   - stateDir 为唯一权威状态目录；status.json 供 UI 进程读取（原子写）
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"github.com/tailscale/wireguard-go/tun"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

var (
	mu      sync.Mutex
	srv     *tsnet.Server
	logPath string
	// KickRestartEngine 内部重启时抑制 "Stopped" 落盘，避免 UI 看门狗把
	// 瞬时停止误判为扩展死亡而并发重启（竞态）。
	suppressStoppedWrite atomic.Bool
)

type result struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

type statusSnapshot struct {
	OK      bool     `json:"ok"`
	Backend string   `json:"backendState"`
	AuthURL string   `json:"authUrl"`
	IPs     []string `json:"tailscaleIps"`
	Ts      int64    `json:"ts"`
}

var (
	snapMu     sync.Mutex
	latestSnap statusSnapshot
	haveSnap   bool

	peerMu      sync.Mutex
	latestPeers []peerStatus

	// gen 为引擎生命周期代数：Stop/重启时递增，在途的 watchStatus 结果据此丢弃，
	// 避免把 "Stopped" 覆盖回 "Running"（状态假存活）。
	gen          atomic.Uint64
	logRotateCnt atomic.Uint64
)

func toJSON(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		return C.CString(`{"ok":false,"error":"json marshal failed"}`)
	}
	return C.CString(string(b))
}

func recoverToJSON(ret **C.char) {
	if r := recover(); r != nil {
		*ret = C.CString(fmt.Sprintf(`{"ok":false,"error":"panic: %v"}`, r))
	}
}

const maxEngineLogBytes = 1 << 20

func logf(format string, args ...any) {
	if logPath == "" {
		return
	}
	// 每 100 行检查一次大小，超过 1MB 轮转为 engine.log.1（避免日志无限增长）
	if logRotateCnt.Add(1)%100 == 0 {
		if fi, err := os.Stat(logPath); err == nil && fi.Size() > maxEngineLogBytes {
			_ = os.Rename(logPath, logPath+".1")
		}
	}
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", time.Now().Format(time.RFC3339), fmt.Sprintf(format, args...))
}

func snapshotEqual(a, b statusSnapshot) bool {
	if a.Backend != b.Backend || a.AuthURL != b.AuthURL || len(a.IPs) != len(b.IPs) {
		return false
	}
	for i := range a.IPs {
		if a.IPs[i] != b.IPs[i] {
			return false
		}
	}
	return true
}

func writeStatusFile(v statusSnapshot) {
	dir := filepath.Dir(logPath)
	if dir == "." || dir == "" {
		return
	}
	// ArkTS 侧对 null 的防御较弱，统一输出 [] 而不是 null
	if v.IPs == nil {
		v.IPs = []string{}
	}
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	tmp := filepath.Join(dir, "status.json.tmp")
	if err := os.WriteFile(tmp, b, 0600); err != nil {
		return
	}
	_ = os.Rename(tmp, filepath.Join(dir, "status.json"))
}

func updateSnapshot(v statusSnapshot) {
	v.Ts = time.Now().Unix()
	snapMu.Lock()
	prev := latestSnap
	first := !haveSnap
	latestSnap = v
	haveSnap = true
	snapMu.Unlock()
	// 每次调用都写文件：作为 UI 看门狗的心跳（watcher 每 5s 调一次）。
	writeStatusFile(v)
	if first || !snapshotEqual(prev, v) {
		logf("status changed: backend=%s ips=%v", v.Backend, v.IPs)
	}
}

// engineGenerationCurrent 判断本轮 watcher 是否仍然属于当前引擎实例。
func engineGenerationCurrent(s *tsnet.Server, myGen uint64) bool {
	if gen.Load() != myGen {
		return false
	}
	mu.Lock()
	cur := srv
	mu.Unlock()
	return cur == s
}

// watchStatus 按官方 tsnet printAuthURLLoop 的机制（每 5s 轮询后端状态，
// AuthURL 由控制面异步下发）缓存状态并落盘 status.json。
func watchStatus(s *tsnet.Server, myGen uint64) {
	for {
		if !engineGenerationCurrent(s, myGen) {
			return
		}
		lc, err := s.LocalClient()
		if err == nil {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			st, err2 := lc.Status(ctx)
			cancel()
			if err2 == nil {
				// Status() 在途期间引擎可能已被停止/替换：丢弃过期结果
				if !engineGenerationCurrent(s, myGen) {
					return
				}
				ips := make([]string, 0, len(st.TailscaleIPs))
				for _, ip := range st.TailscaleIPs {
					ips = append(ips, ip.String())
				}
				updatePeers(st)
				updateSnapshot(statusSnapshot{OK: true, Backend: st.BackendState, AuthURL: st.AuthURL, IPs: ips})
			}
		}
		time.Sleep(5 * time.Second)
	}
}

// tunMTU 与 VpnConfig.mtu 保持一致。依据 Tailscale 官方安全默认值
// net/tstun/mtu.go safeTUNMTU=1280（IPv6 最小 MTU 兼容），避免 1400+80 在
// 蜂窝/PPP 路径上触发分片或 PMTUD 黑洞。
const tunMTU = 1280

// fdTun 是背靠 HarmonyOS vpn-tun 文件描述符的最小 tun.Device 实现。
// 语义镜像 wireguard-go 的参考实现（tun_linux.go）：
//   - Read 单包读入 bufs[0][offset:]，sizes[0]=n，返回 1
//   - Write 逐包写出 bufs[i][offset:]
//   - 无 vnetHdr，BatchSize=1
type fdTun struct {
	file      *os.File
	events    chan tun.Event
	closed    chan struct{}
	closeOnce sync.Once

	readOps    atomic.Uint64
	readPkts   atomic.Uint64
	readBytes  atomic.Uint64
	writeOps   atomic.Uint64
	writePkts  atomic.Uint64
	writeBytes atomic.Uint64
	pktLogCnt  atomic.Uint64
}

var currentTun atomic.Pointer[fdTun]

// kernelTunStats 返回 /proc/net/dev 中 vpn-tun 的内核计数（诊断用）。
func kernelTunStats() string {
	b, err := os.ReadFile("/proc/net/dev")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.Contains(line, "vpn-tun:") {
			return strings.TrimSpace(line)
		}
	}
	return ""
}

func newFdTun(fd int) (*fdTun, error) {
	if fd < 0 {
		return nil, errors.New("invalid tun fd")
	}
	f := os.NewFile(uintptr(fd), "vpn-tun")
	if f == nil {
		return nil, errors.New("os.NewFile returned nil")
	}
	t := &fdTun{
		file:   f,
		events: make(chan tun.Event, 5),
		closed: make(chan struct{}),
	}
	// vpn-tun 由系统创建时即处于 UP 状态，立即上报（与参考实现语义一致）。
	t.events <- tun.EventUp
	currentTun.Store(t)
	return t, nil
}

func (t *fdTun) File() *os.File { return t.file }

func (t *fdTun) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	select {
	case <-t.closed:
		return 0, os.ErrClosed
	default:
	}
	t.readOps.Add(1)
	readInto := bufs[0][offset:]
	n, err := t.file.Read(readInto)
	if err != nil {
		if errors.Is(err, syscall.EBADFD) {
			return 0, os.ErrClosed
		}
		return 0, err
	}
	sizes[0] = n
	t.readPkts.Add(1)
	t.readBytes.Add(uint64(n))
	if n >= 20 {
		t.logPacket(readInto[:n])
	}
	return 1, nil
}

// logPacket 记录 tun 内 IPv4 包的 proto/src/dst（诊断用：前 60 个逐条，之后每 120 个抽样一条）。
func (t *fdTun) logPacket(p []byte) {
	cnt := t.pktLogCnt.Add(1)
	if cnt > 60 && cnt%120 != 0 {
		return
	}
	if p[0]>>4 != 4 {
		logf("tun pkt#%d non-IPv4 ver=%d len=%d", cnt, p[0]>>4, len(p))
		return
	}
	ihl := int(p[0]&0x0f) * 4
	if len(p) < ihl || len(p) < 20 {
		logf("tun pkt#%d short len=%d", cnt, len(p))
		return
	}
	proto := p[9]
	src := netip.AddrFrom4([4]byte{p[12], p[13], p[14], p[15]})
	dst := netip.AddrFrom4([4]byte{p[16], p[17], p[18], p[19]})
	logf("tun pkt#%d proto=%d %s -> %s len=%d", cnt, proto, src, dst, len(p))
}

func (t *fdTun) Write(bufs [][]byte, offset int) (int, error) {
	var total int
	t.writeOps.Add(1)
	for i := range bufs {
		n, err := t.file.Write(bufs[i][offset:])
		if errors.Is(err, syscall.EBADFD) {
			return total, os.ErrClosed
		}
		if err != nil {
			return total, err
		}
		t.writePkts.Add(1)
		t.writeBytes.Add(uint64(n))
		total += n
	}
	return total, nil
}

func (t *fdTun) MTU() (int, error) { return tunMTU, nil }

func (t *fdTun) Name() (string, error) { return "vpn-tun", nil }

func (t *fdTun) Events() <-chan tun.Event { return t.events }

func (t *fdTun) Close() error {
	var err error
	t.closeOnce.Do(func() {
		close(t.closed)
		close(t.events)
		err = t.file.Close()
	})
	return err
}

func (t *fdTun) BatchSize() int { return 1 }

//export StartEngine
func StartEngine(stateDir *C.char, hostname *C.char, proxyURL *C.char, tunFD C.int) (ret *C.char) {
	defer recoverToJSON(&ret)
	mu.Lock()
	defer mu.Unlock()
	if srv != nil {
		return toJSON(result{OK: false, Error: "already started"})
	}
	dir := C.GoString(stateDir)
	if dir == "" {
		return toJSON(result{OK: false, Error: "stateDir is empty"})
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return toJSON(result{OK: false, Error: "mkdir stateDir failed: " + err.Error()})
	}
	logPath = filepath.Join(dir, "engine.log")
	proxy := C.GoString(proxyURL)
	upstream, upstreamName, buildErr := buildLocalUpstream(dir, proxy)
	if buildErr != nil {
		logf("StartEngine: local proxy config failed: %v", buildErr)
		return toJSON(result{OK: false, Error: "proxy config failed: " + buildErr.Error()})
	}
	if err := startLocalProxy(upstream); err != nil {
		logf("StartEngine: startLocalProxy failed: %v", err)
		return toJSON(result{OK: false, Error: "local proxy failed: " + err.Error()})
	}
	proxy = "http://" + localProxyListen
	os.Setenv("HTTPS_PROXY", proxy)
	os.Setenv("HTTP_PROXY", proxy)
	logf("StartEngine: stateDir=%s hostname=%s proxy=%s upstream=%s tunFd=%d", dir, C.GoString(hostname), proxy, upstreamName, int(tunFD))
	s := &tsnet.Server{
		Dir:      dir,
		Hostname: C.GoString(hostname),
		Logf:     logf,
		UserLogf: logf,
	}
	if int(tunFD) >= 0 {
		tunDev, err := newFdTun(int(tunFD))
		if err != nil {
			stopLocalProxy()
			logf("StartEngine: tun setup failed: %v", err)
			return toJSON(result{OK: false, Error: "tun setup failed: " + err.Error()})
		}
		s.Tun = tunDev
	}
	srv = s
	if err := s.Start(); err != nil {
		srv = nil
		stopLocalProxy()
		logf("StartEngine: tsnet start failed: %v", err)
		return toJSON(result{OK: false, Error: "tsnet start failed: " + err.Error()})
	}
	go watchStatus(s, gen.Add(1))
	logf("StartEngine: tsnet started")
	return toJSON(result{OK: true})
}

//export StopEngine
func StopEngine() (ret *C.char) {
	defer recoverToJSON(&ret)
	mu.Lock()
	s := srv
	srv = nil
	mu.Unlock()
	// 代数递增：让在途 watcher 的结果失效，并清空快照/计数器，
	// 避免 GetStatusJSON 在停止后仍返回旧的 Running/陈旧 tun 计数。
	gen.Add(1)
	snapMu.Lock()
	haveSnap = false
	latestSnap = statusSnapshot{}
	snapMu.Unlock()
	currentTun.Store(nil)
	peerMu.Lock()
	latestPeers = nil
	peerMu.Unlock()
	if s == nil {
		stopLocalProxy()
		return toJSON(result{OK: false, Error: "not started"})
	}
	logf("StopEngine: closing")
	if !suppressStoppedWrite.Load() {
		writeStatusFile(statusSnapshot{OK: false, Backend: "Stopped", Ts: time.Now().Unix()})
	}
	closeErr := s.Close()
	stopLocalProxy()
	if closeErr != nil {
		return toJSON(result{OK: false, Error: "close failed: " + closeErr.Error()})
	}
	logf("StopEngine: closed")
	return toJSON(result{OK: true})
}

//export KickRestartEngine
func KickRestartEngine(stateDir *C.char, hostname *C.char, proxyURL *C.char) (ret *C.char) {
	defer recoverToJSON(&ret)
	suppressStoppedWrite.Store(true)
	stopRet := StopEngine()
	suppressStoppedWrite.Store(false)
	stopMsg := C.GoString(stopRet)
	C.free(unsafe.Pointer(stopRet))
	logf("KickRestartEngine: stop result: %s", stopMsg)
	return StartEngine(stateDir, hostname, proxyURL, -1)
}

//export StopEngineQuiet
func StopEngineQuiet() (ret *C.char) {
	defer recoverToJSON(&ret)
	suppressStoppedWrite.Store(true)
	stopRet := StopEngine()
	suppressStoppedWrite.Store(false)
	msg := C.GoString(stopRet)
	C.free(unsafe.Pointer(stopRet))
	logf("StopEngineQuiet: stop result: %s", msg)
	return toJSON(result{OK: true})
}


//export ListSSNodes
func ListSSNodes(yamlPath *C.char) (ret *C.char) {
	defer recoverToJSON(&ret)
	nodes, err := listSSNodes(C.GoString(yamlPath))
	if err != nil {
		return toJSON(result{OK: false, Error: err.Error()})
	}
	return toJSON(map[string]interface{}{"ok": true, "nodes": nodes})
}

//export SelectSSNode
func SelectSSNode(yamlPath *C.char, name *C.char) (ret *C.char) {
	defer recoverToJSON(&ret)
	if err := selectSSNode(C.GoString(yamlPath), C.GoString(name)); err != nil {
		return toJSON(result{OK: false, Error: err.Error()})
	}
	return toJSON(result{OK: true})
}

//export GetStatusJSON
func GetStatusJSON() (ret *C.char) {
	defer recoverToJSON(&ret)
	snapMu.Lock()
	if haveSnap {
		v := latestSnap
		snapMu.Unlock()
		return toJSON(buildEngineStatus(v))
	}
	snapMu.Unlock()
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return toJSON(result{OK: false, Error: "not started"})
	}
	lc, err := s.LocalClient()
	if err != nil {
		return toJSON(result{OK: false, Error: "LocalClient failed: " + err.Error()})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	st, err := lc.Status(ctx)
	if err != nil {
		return toJSON(result{OK: false, Error: "Status failed: " + err.Error()})
	}
	ips := make([]string, 0, len(st.TailscaleIPs))
	for _, ip := range st.TailscaleIPs {
		ips = append(ips, ip.String())
	}
	updatePeers(st)
	v := statusSnapshot{OK: true, Backend: st.BackendState, AuthURL: st.AuthURL, IPs: ips}
	updateSnapshot(v)
	return toJSON(buildEngineStatus(v))
}

// engineStatus 在状态快照之上附加引擎侧 tun 计数器、内核计数与 peer 列表（诊断用）。
type engineStatus struct {
	OK            bool         `json:"ok"`
	Backend       string       `json:"backendState"`
	AuthURL       string       `json:"authUrl"`
	IPs           []string     `json:"tailscaleIps"`
	TunReadOps    uint64       `json:"tunReadOps"`
	TunReadPkts   uint64       `json:"tunReadPkts"`
	TunReadBytes  uint64       `json:"tunReadBytes"`
	TunWriteOps   uint64       `json:"tunWriteOps"`
	TunWritePkts  uint64       `json:"tunWritePkts"`
	TunWriteBytes uint64       `json:"tunWriteBytes"`
	KernelTun     string       `json:"kernelTun"`
	Peers         []peerStatus `json:"peers,omitempty"`
}

type peerStatus struct {
	Host    string   `json:"host"`
	OS      string   `json:"os"`
	Online  bool     `json:"online"`
	Relay   string   `json:"relay,omitempty"`
	CurAddr string   `json:"curAddr,omitempty"`
	IPs     []string `json:"ips"`
	Allowed []string `json:"allowed,omitempty"`
}

func updatePeers(st *ipnstate.Status) {
	peers := make([]peerStatus, 0, len(st.Peer))
	for _, p := range st.Peer {
		if p == nil {
			continue
		}
		ips := make([]string, 0, len(p.TailscaleIPs))
		for _, ip := range p.TailscaleIPs {
			ips = append(ips, ip.String())
		}
		allowed := make([]string, 0, 8)
		if p.AllowedIPs != nil {
			for _, pr := range p.AllowedIPs.All() {
				allowed = append(allowed, pr.String())
			}
		}
		peers = append(peers, peerStatus{
			Host:    p.HostName,
			OS:      p.OS,
			Online:  p.Online,
			Relay:   p.Relay,
			CurAddr: p.CurAddr,
			IPs:     ips,
			Allowed: allowed,
		})
	}
	peerMu.Lock()
	latestPeers = peers
	peerMu.Unlock()
}

func buildEngineStatus(v statusSnapshot) engineStatus {
	out := engineStatus{
		OK:        v.OK,
		Backend:   v.Backend,
		AuthURL:   v.AuthURL,
		IPs:       v.IPs,
		KernelTun: kernelTunStats(),
	}
	if tn := currentTun.Load(); tn != nil {
		out.TunReadOps = tn.readOps.Load()
		out.TunReadPkts = tn.readPkts.Load()
		out.TunReadBytes = tn.readBytes.Load()
		out.TunWriteOps = tn.writeOps.Load()
		out.TunWritePkts = tn.writePkts.Load()
		out.TunWriteBytes = tn.writeBytes.Load()
	}
	peerMu.Lock()
	out.Peers = append([]peerStatus(nil), latestPeers...)
	peerMu.Unlock()
	return out
}

// engineVersion 供 ArkTS 侧做 HAP/so 成对构建的版本握手（仅诊断用途）。
const engineVersion = "1.0.0+bridge4"

//export EngineVersion
func EngineVersion() (ret *C.char) {
	defer recoverToJSON(&ret)
	return C.CString(engineVersion)
}

//export FreeCString
func FreeCString(p *C.char) {
	if p == nil {
		return
	}
	C.free(unsafe.Pointer(p))
}

func main() {
	// c-shared 构建要求存在 main 函数；不执行任何逻辑。
}
