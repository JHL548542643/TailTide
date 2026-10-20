# Architecture

```
ArkTS UI (EntryAbility)
  │  status.json / vpn.json / control
  ▼
TailnetVpnAbility (VpnExtensionAbility)
  │  creates VpnConnection, passes tun FD
  ▼
Go engine (libtailscale_go.so, c-shared)
  ├─ tsnet.Server (Tailscale v1.86.5 + OHOS patch)
  ├─ tun.Device over the VPN FD, MTU 1280
  ├─ routes: 100.64.0.0/10 only (no global proxy)
  └─ local HTTP CONNECT proxy 127.0.0.1:7899
        ├─ direct upstream
        ├─ external HTTP(S) proxy (proxy.json)
        └─ minimal SS AEAD upstream (ss-node.json + YAML candidates)
```

## Data flow

1. The UI starts the VPN extension with `startVpnExtensionAbility`.
2. The extension creates a `VpnConnection` and passes the TUN FD to the Go engine.
3. The engine builds a local front proxy on `127.0.0.1:7899` and points `HTTPS_PROXY`/`HTTP_PROXY` at it. The URL is constant, so mode switches do not invalidate `tshttpproxy`'s in-process cache.
4. The local proxy selects an upstream:
   - SS: primary node from `ss-node.json`, then the remaining YAML candidates on connect/handshake failure;
   - external: HTTP CONNECT chain to the configured proxy;
   - direct: direct dial.
5. tsnet uses the local proxy only for the control plane/DERP; Tailnet data uses the TUN and the explicit `100.64.0.0/10` route.
6. The engine writes `status.json` as a heartbeat; the UI uses it plus `vpn.json` (VPN active) for the connected state.

## Deliberate limits

- No global proxy / no full-device VPN egress.
- SS support is classic AEAD (aes-128/256-gcm), no plugin, no SS2022.
- SS config stays in the app sandbox; passwords are never logged.
- Failover covers connect/handshake failures; a node that connects but cannot reach the control plane is not automatically detected.
