# splitroute

[![ShellCheck](https://github.com/searchpcc/splitroute/actions/workflows/lint.yml/badge.svg)](https://github.com/searchpcc/splitroute/actions/workflows/lint.yml)
[![Tests](https://github.com/searchpcc/splitroute/actions/workflows/test.yml/badge.svg)](https://github.com/searchpcc/splitroute/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-12%2B-black.svg)](https://www.apple.com/macos/)

[English](README.md) | [中文](README.zh-CN.md)

Automated split tunneling for macOS VPN. Route only what you need through the tunnel — everything else stays on your default network.

Works with L2TP/IPsec, IKEv2, WireGuard, and OpenVPN.

## Quick Start

### 1. Prepare your VPN

Open **System Settings > VPN**, select your VPN, and **disable** "Send all traffic over VPN connection".

### 2. Install

```bash
curl -fsSL https://raw.githubusercontent.com/searchpcc/splitroute/main/install.sh | bash
```

Or manually:

```bash
git clone https://github.com/searchpcc/splitroute.git
cd splitroute
make install
```

The installer will ask which IPs you want to route through VPN. You can also add them later.

### 3. Add routes

```bash
splitroute add 10.0.1.100        # a single server
splitroute add 192.168.0.0/16    # an entire subnet
```

### 4. Connect VPN and verify

Connect your VPN as usual, then check:

```bash
splitroute status
```

That's it. Routes are applied automatically every time VPN connects.

---

## How It Works

```
                     ┌────────────────┐
                     │  macOS Routing  │
                     └───────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
       ┌──────▼──────┐ ┌────▼────┐  ┌──────▼──────┐
       │  Your routes │ │  Other  │  │  Default    │
       │  (splitroute)│ │ traffic │  │  gateway    │
       └──────┬──────┘ └────┬────┘  └─────────────┘
              │              │
       ┌──────▼──────┐ ┌────▼────┐
       │  VPN tunnel  │ │  Direct │
       │  (ppp/utun)  │ │         │
       └─────────────┘ └─────────┘
```

1. **Route injection** — When VPN connects, splitroute adds routes for your configured IPs through the VPN interface
2. **Auto-detection** — A background service monitors VPN connect/disconnect
3. **Auto-cleanup** — Routes are removed by the OS when VPN disconnects

No startup order required. The service starts automatically on login.

## Commands

```
splitroute add <target>          Smart add — IP, CIDR, hostname, or *.pattern
splitroute remove <target>       Smart remove — same input forms as add
splitroute list                  List everything currently configured
splitroute edit                  Open config file in editor
splitroute status                Show service, VPN, route, and PAC status
splitroute test <IP|hostname>    Check how a target is currently routed
splitroute logs                  Show recent log entries
splitroute reload                Restart the background service
splitroute uninstall             Uninstall splitroute
splitroute help                  Show all commands

# Explicit subcommands (the smart `add`/`remove` above already dispatch to these)
splitroute host add <hostname>   Browser + ssh/git/curl via VPN, all in one step
splitroute host remove <name>    Remove a hostname (and its auto-added dns suffix)
splitroute host list             List hostnames and their currently resolved IPs
splitroute domain add <pat|IP>   *.pattern or IPv4/CIDR for the browser only
splitroute domain remove <pat>   Remove a pattern / PAC-only IP
splitroute domain list           List patterns and PAC-only IPs
splitroute dns add <sfx> [ns]    Map a DNS suffix to a nameserver (or 'auto')
splitroute dns remove <sfx>      Remove a DNS override
splitroute dns list              List DNS overrides
splitroute pac [url|show|status] Inspect the PAC endpoint and file
```

### One command per hostname

For the common case — "make `git.company.com` go through VPN in browser, git, and ssh" — `splitroute add` figures out the layers for you:

```bash
splitroute add git.company.com               # browser + ssh + git, all via VPN
splitroute add bastion.company.com           # ssh bastion via VPN
splitroute add git.company.com 10.0.1.5      # same, but pin to a fixed IP — no DNS lookup at all
splitroute add 10.20.0.0/16                  # any app: route the whole subnet via VPN
splitroute add '*.corp.internal'             # browser only — wildcard PAC pattern
```

A bare hostname expands into three behind-the-scenes actions:

1. PAC `DIRECT` rule — the browser bypasses Clash for this host.
2. `dns: <parent_suffix> auto` if not already set — so DIRECT lookups use the VPN-pushed DNS.
3. After VPN connects, the watch loop resolves the hostname over VPN DNS and installs `route -host` entries; it re-resolves periodically so DNS changes propagate without you running anything.

If you pass a fixed IP (`splitroute add <hostname> <ip>`), step 2 is skipped and the watch loop instead writes a marker-tagged line to `/etc/hosts` so the hostname resolves locally. Best when the IP is known and stable: VPN DNS doesn't need to be reachable, the route comes up the moment VPN connects, and there's no DNS round-trip on every lookup.

`splitroute remove git.company.com` reverses all of it (drops the auto-added `dns:` line if no other host still needs it; removes the `/etc/hosts` line on the next sync if the host was pinned).

## Configuration

Config file: `~/.splitroute/splitroute.conf`

You can manage routes with `splitroute add/remove`, or edit the config file directly:

```ini
# VPN interface detection (usually no need to change)
# auto = detect automatically | ppp = L2TP only | utun = IKEv2/WireGuard only
interface = auto

# Proxy bridging (for local proxy tool users, see below)
proxy = false
http_port = 7890
socks_port = 7891

# === Routes ===
10.0.1.100
192.168.0.0/16
```

Changes take effect on the next VPN connection. No restart needed.

### Proxy Bridging (Optional)

If you use a local proxy tool (ClashX Meta, Surge, Stash, etc.), VPN connections can break your system proxy settings. Enable proxy bridging to fix this:

```bash
splitroute edit
```

Then set:

```ini
proxy = true
http_port = 7890      # match your proxy tool
socks_port = 7891
```

Common proxy tool ports:

| Tool | HTTP | SOCKS |
|------|------|-------|
| ClashX Meta | 7890 | 7891 |
| Clash Verge | 7897 | 7897 |
| Surge | 6152 | 6153 |
| Stash | 7890 | 7891 |

> **Why?** When VPN connects, macOS creates a new network service for the tunnel. Your proxy tool only sets system proxy on Wi-Fi, not the VPN service. Proxy bridging tells splitroute to also set system proxy on the VPN service.

## Browser Split Routing (PAC)

> New in v1.3

The route table works for anything that uses the OS socket layer (SSH, `curl`, `git`, native apps). **Browsers are different.** If you run a local proxy tool like Clash Verge with "system proxy" enabled, Chrome sends every request to the proxy — so splitroute's routes never get a chance to fire, and your internal company domains get tunneled through the wrong pipe.

splitroute v1.3 solves this by serving a **PAC (Proxy Auto-Config)** file and registering it as the macOS system auto-proxy URL. The PAC tells the browser: "for company domains and IP ranges go `DIRECT` (which lets the OS routing table → splitroute → VPN), for everything else go through your existing proxy (Clash etc.)."

Clash configuration is **not** modified.

### Setup

```bash
# Domains whose traffic should go via VPN in the browser
splitroute domain add '*.company.com'
splitroute domain add '*.corp.internal'

# IP / CIDR for browser only (PAC `isInNet` DIRECT, no macOS route installed).
# Use this when the VPN client already routes the IP; if SSH/curl also need
# it via VPN, use `splitroute add <IP>` instead (writes macOS route + PAC).
splitroute domain add 10.0.1.5
splitroute domain add 10.0.2.0/24

# Internal DNS override (so DIRECT hostnames resolve via VPN-pushed DNS).
# 'auto' reads the nameserver from scutil --dns once VPN is connected.
splitroute dns add company.com auto
splitroute dns add corp.internal auto

# Verify
splitroute status
splitroute pac show     # inspect generated PAC JavaScript
splitroute doctor       # 7-step health check, incl. PAC server + autoproxy URL
```

That's it. The background service:

- Generates `~/.splitroute/pac/proxy.pac` from your config
- Runs a local HTTP server on `http://127.0.0.1:7899/proxy.pac` (Python's built-in `http.server`, bound to 127.0.0.1 only)
- Sets `networksetup -setautoproxyurl` on every active network service (Wi-Fi, Ethernet, etc.) — and re-applies every 30 seconds so adapter switches are covered
- Writes `/etc/resolver/<suffix>` entries when VPN connects; clears them on disconnect
- Hot-reloads within ~30 seconds when you edit `~/.splitroute/splitroute.conf`
- On `splitroute uninstall` (or `launchctl bootout`) restores every service's previous auto-proxy URL/state and removes its `/etc/resolver` files

### How PAC routing flows

```
Chrome → system proxy → PAC FindProxyForURL(host):
  host ~ *.company.com       → DIRECT → OS routing → splitroute VPN
  host in 10.0.0.0/8         → DIRECT → OS routing → splitroute VPN
  anything else              → PROXY 127.0.0.1:7890 (Clash etc.)
```

### When VPN is disconnected

The PAC server and auto-proxy URL stay live; the PAC still routes non-company traffic through Clash so your browser keeps working. DIRECT rules for company domains will fail to resolve (internal DNS unreachable) — the intended outcome when you're off-VPN.

### Privileged helper

`/etc/resolver/<suffix>` management uses a small helper at `/usr/local/bin/splitroute-priv` (installed by the setup script). It is sudoers-granted NOPASSWD but strictly validates its inputs (DNS-safe suffix, IPv4 nameserver) and only touches files that carry its own marker header — so it cannot be tricked into writing or deleting arbitrary paths.

### Config syntax

```ini
# ~/.splitroute/splitroute.conf — browser PAC section

# Defaults (all optional):
# pac_enabled = auto            # auto = on when any domain:/dns: line exists
# pac_port = 7899
# upstream_proxy =              # empty = auto-detect Clash (7890/7897/6152)
# auto_set_system_proxy = true
# manage_resolver = true

domain: *.company.com
domain: *.corp.internal

# IP/CIDR rules (already used for routes) also feed PAC isInNet() rules.
10.0.0.0/8
172.16.0.0/12

dns: company.com auto
dns: corp.internal auto
```

## Supported VPN Protocols

| Protocol | Interface | Status |
|----------|-----------|--------|
| L2TP/IPsec | `ppp0` | Supported |
| IKEv2 (system) | `utun*` | Supported |
| WireGuard (system) | `utun*` | Supported |
| WireGuard App | `utun*` | Supported |
| OpenVPN / Tunnelblick | `utun*` | Supported |

> IPv4 only. IPv6 routing is not currently supported.

## Requirements

- **macOS 12 Monterey or later** (tested on macOS 12–15)
- Administrator access (sudo required during installation)
- A configured VPN connection with "Send all traffic over VPN" **disabled**

> **macOS 15 Sequoia:** Apple removed built-in L2TP/IPsec in macOS 15. Use a third-party L2TP client or switch to IKEv2/WireGuard/OpenVPN.

All tools used by splitroute are built into macOS — **no external dependencies**.

## Troubleshooting

**Routes not added after VPN connects**

```bash
splitroute status     # check service and config
splitroute logs       # check for errors
```

Common causes:
- No routes configured: run `splitroute add <IP>`
- Service not running: run `splitroute reload`

**Check if a specific IP goes through VPN**

```bash
splitroute test 10.0.1.100
```

**Internal hostnames not resolving**

Since v1.3, splitroute can manage `/etc/resolver/*` for you:

```bash
splitroute dns add internal.company.com auto        # auto = use VPN-pushed DNS
# or with an explicit nameserver:
splitroute dns add internal.company.com 10.0.0.1
```

For the legacy manual approach:

```bash
sudo mkdir -p /etc/resolver
echo "nameserver 10.0.0.1" | sudo tee /etc/resolver/internal.company.com
```

**Browser still going through Clash instead of VPN**

Check `splitroute doctor` — step 7 verifies the PAC server is reachable and the auto-proxy URL is set on every active network service. If it reports a problem, `splitroute doctor --fix` re-applies. Also see `splitroute pac show` to inspect the generated PAC rules.

**Proxy tool shows disconnected after VPN connects**

Enable proxy bridging: `splitroute edit` and set `proxy = true`.

## Uninstall

```bash
splitroute uninstall
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
