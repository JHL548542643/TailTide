# Privacy

## No telemetry

TailTide does not collect analytics, telemetry, advertising identifiers, or crash reports. There is no account system in the app.

## Local data

- SS node configuration (including the node password) is stored in the app's private sandbox: `filesDir/tailnet/clash-config.yaml` and `filesDir/tailnet/ss-node.json`.
- Logs are local; passwords are not logged.
- Removing the app removes its sandbox data.

## Network traffic

- Tailnet traffic is handled by the Tailscale engine (WireGuard/DERP) using the user's own Tailscale account.
- When the built-in SS egress is enabled, connections to the Tailscale control plane/DERP are relayed through the user's chosen Shadowsocks server. That server and its operator can observe connection metadata; choose a provider you trust.
- The app does not route general phone traffic through the SS server; only the Tailscale engine uses the local front proxy.

## Third parties

Tailscale, the Shadowsocks provider, and the HarmonyOS platform have their own privacy policies. This project is not affiliated with them.
