# splitroute

[![ShellCheck](https://github.com/searchpcc/splitroute/actions/workflows/lint.yml/badge.svg)](https://github.com/searchpcc/splitroute/actions/workflows/lint.yml)
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
splitroute add <IP>       Add an IP or subnet to route through VPN
splitroute remove <IP>    Remove an IP or subnet
splitroute list           List all configured routes
splitroute edit           Open config file in editor
splitroute status         Show service, VPN, and route status
splitroute test <IP>      Check how an IP is currently routed
splitroute logs           Show recent log entries
splitroute reload         Restart the background service
splitroute uninstall      Uninstall splitroute
splitroute help           Show all commands
```

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

splitroute handles routing only, not DNS. To resolve internal domains through VPN DNS:

```bash
sudo mkdir -p /etc/resolver
echo "nameserver 10.0.0.1" | sudo tee /etc/resolver/internal.company.com
```

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
