# Third-Party Notices

TailTide includes or depends on the following third-party software/specifications. This file is informational; the authoritative licenses are in the upstream projects.

| Component | Version / source | License | Link |
|---|---|---|---|
| Tailscale (tsnet, control client, DERP) | v1.86.5, with the patches in `patches/` | BSD-3-Clause | https://github.com/tailscale/tailscale |
| wireguard-go | as pinned by Tailscale v1.86.5 | MIT | https://github.com/tailscale/wireguard-go |
| gVisor netstack | as pinned by Tailscale v1.86.5 | Apache-2.0 | https://github.com/google/gvisor |
| go-yaml | v2.4.0 | Apache-2.0 | https://github.com/go-yaml/yaml |
| OpenHarmony Go toolchain | build dependency, not vendored | BSD-3-Clause | https://gitee.com/openharmony/third_party_go |
| Shadowsocks AEAD / SIP002 specifications | archived excerpts in `docs/references/shadowsocks/` | MIT (site footer) | https://shadowsocks.org/ |
| RFC 1928 (SOCKS5) | archived in `docs/references/shadowsocks/rfc1928.txt` | IETF Trust | https://www.rfc-editor.org/rfc/rfc1928 |
| RFC 9110 §9.3.6 (HTTP CONNECT) | summary in `docs/references/http-connect.md` | IETF Trust | https://www.rfc-editor.org/rfc/rfc9110 |

## Not redistributed

- HarmonyOS SDK declaration files and OpenHarmony documentation are **not** included in this public repository. Refer to the official Huawei/OpenHarmony documentation and your installed SDK.
- `third_party/` is not vendored; see `docs/BUILD.md`.

## Trademarks

"Tailscale" is a trademark of Tailscale Inc. This project is not affiliated with or endorsed by Tailscale Inc. "TailTide" is the name of this personal project. The purple palette is inspired by a fan support color and does not imply affiliation with any artist.
