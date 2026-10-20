#!/usr/bin/env python3
"""Select a Shadowsocks node from a Clash YAML and write a local JSON config.

The output contains the node password and must stay in .cache (gitignored).
Only classic SS AEAD with aes-256-gcm and no plugin are accepted by the probe.
"""

import argparse
import json
import os
import sys

import yaml

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def candidates(doc):
    proxies = doc.get("proxies") or []
    out = []
    for p in proxies:
        if p.get("type") != "ss":
            continue
        if str(p.get("cipher", "")).lower() != "aes-256-gcm":
            continue
        if p.get("plugin"):
            continue
        if not p.get("server") or not p.get("port") or not p.get("password"):
            continue
        out.append(p)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.path.join(".cache", "clash-config.yaml"))
    ap.add_argument("--name", required=True)
    ap.add_argument("--out", default=os.path.join(".cache", "ss-node.json"))
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    with open(args.config, "r", encoding="utf-8") as f:
        doc = yaml.safe_load(f)

    nodes = candidates(doc)
    if args.list:
        for i, p in enumerate(nodes):
            print(i, p.get("name"), "port=" + str(p.get("port")), "cipher=" + str(p.get("cipher")))
        return

    match = [p for p in nodes if p.get("name") == args.name]
    if not match:
        match = [p for p in nodes if args.name in str(p.get("name", ""))]
    if not match:
        print("node not found:", args.name)
        print("available:")
        for i, p in enumerate(nodes):
            print(i, p.get("name"), "port=" + str(p.get("port")))
        sys.exit(1)

    p = match[0]
    out = {
        "name": str(p.get("name")),
        "server": str(p.get("server")),
        "port": int(p.get("port")),
        "cipher": str(p.get("cipher")),
        "password": str(p.get("password")),
    }
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print("wrote", args.out, "node=" + out["name"], "port=" + str(out["port"]), "cipher=" + out["cipher"])


if __name__ == "__main__":
    main()