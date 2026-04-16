# Changelog

## [1.4.0] - 2026-04-17

### Added

- `splitroute domain add` now accepts an IPv4 address or CIDR. Such entries generate only a PAC `isInNet` DIRECT rule — no macOS route is installed. Useful when the VPN client already owns the route for that IP/subnet (e.g. internal CIDRs pushed via IKEv2 / WireGuard AllowedIPs, or full-tunnel VPN) and you only need the browser to stop handing those requests to the upstream proxy (Clash Verge etc.). For the common case where splitroute must install the VPN route itself, keep using `splitroute add <IP>` — it writes both the macOS route and the PAC entry. `splitroute domain list` now prints domain patterns and PAC-only IPs in separate sections, and `status` / `doctor` / `pac show` counters include PAC-only IPs alongside domains.

### Fixed

- Previously, passing an IP to `splitroute domain add` wrote a `domain: <ip>` line that silently did nothing (PAC `shExpMatch` did not match hostnames by IP). Those legacy entries are now interpreted correctly as PAC-only IP rules.

## [1.3.0] - 2026-04-17

### Added

- **Browser split routing via PAC**: splitroute now serves a Proxy Auto-Config file on `http://127.0.0.1:7899/proxy.pac` and sets it as the system auto-proxy URL across all active network services. Chrome, Safari, and other PAC-aware apps will send configured domains/IP ranges through the VPN (`DIRECT` → OS routing table → VPN) while all other traffic falls back to the user's existing HTTP proxy (e.g. Clash Verge on `127.0.0.1:7890`). No Clash config changes required.
- `splitroute domain add|remove|list` — manage PAC domain rules (shExpMatch patterns like `*.company.com`). Hot-reloads within 30s.
- `splitroute dns add <suffix> [<nameserver>|auto] / remove / list` — maintain `/etc/resolver/<suffix>` entries so internal-only company DNS names resolve through the VPN-pushed nameserver. `auto` reads the nameserver from `scutil --dns` after VPN comes up.
- `splitroute pac [url|show|status]` — inspect PAC endpoint and generated file
- `splitroute doctor` gains a 7th step: PAC server reachability + autoproxy URL verification on active services, with `--fix` re-applying the autoproxy URL.
- `splitroute-priv`: narrow, marker-aware privileged helper (`write-resolver` / `delete-resolver` / `cleanup-resolver`). Only touches `/etc/resolver/<suffix>` files it has previously marked.
- Config additions: `domain:`, `dns:`, `pac_enabled`, `pac_port`, `upstream_proxy`, `manage_resolver`, `auto_set_system_proxy`. All have sensible defaults; typical use requires only `domain:` lines.
- `auto` upstream-proxy probe: detects Clash Verge / ClashX Meta / Surge on common ports (`7890`, `7897`, `6152`) and uses whichever is listening.
- Auto network-service sync: PAC URL is re-applied every 30 seconds, catching WiFi ↔ ethernet switches.
- Hot reload: watch re-reads `splitroute.conf` on mtime change and refreshes PAC + resolver + autoproxy without restart.

### Changed

- Sudoers file now additionally permits `/usr/local/bin/splitroute-priv` (input-validated helper); existing `/sbin/route` and `/usr/sbin/networksetup` entries unchanged.

## [1.2.1] - 2026-04-14

### Fixed

- `splitroute reload` intermittently failed with `Load failed: 5: Input/output error` and often needed 2–3 retries. Root cause: `launchctl bootout` is asynchronous — it signals SIGTERM and returns before the service actually exits, so the immediately-following `launchctl bootstrap` hit an already-bootstrapped label and returned EIO. Now `reload`, `uninstall`, and the installer poll `launchctl print` until the label is gone (timeout 5s) before bootstrapping
- `splitroute reload` printed "Service reloaded" even when both the new and legacy load APIs failed. It now only reports success when the service actually loaded, and prints an actionable error otherwise (exit code 1)

## [1.2.0] - 2026-04-14

### Added

- `splitroute doctor` now includes a 6th step, `Proxy listener`: when `proxy = true`, probes the configured HTTP/SOCKS ports on `127.0.0.1` and reports whether the proxy tool is actually running. Handles mixed-port configs (e.g. Clash Verge `7897`) by only probing once when HTTP and SOCKS ports match
- Interactive installer prints a proxy-port reference table (ClashX Meta / Stash, Clash Verge, Surge) before prompting for ports, so users can pick the right port for their proxy tool without leaving the terminal

## [1.1.0] - 2026-03-11

### Added

- `splitroute doctor [--fix]`: 5-step diagnostic (daemon, config, VPN, routes, connectivity) with optional auto-repair
- `splitroute apply`: manually inject routes without waiting for the watch daemon
- `[OK]`/`[STALE]` per-route markers in `splitroute status`
- Periodic route verification every 30s in the watch daemon as a safety net

### Fixed

- VPN reconnect route loss: the watch daemon now tracks the specific VPN interface name (e.g. `utun3`) instead of only checking "is VPN connected", so routes are re-applied when the interface changes across reconnects (e.g. `utun3` → `utun5`)

## [1.0.0] - 2026-03-07

### Added

- Automated split tunneling for macOS VPN (L2TP/IPsec, IKEv2, WireGuard, OpenVPN)
- Support for third-party VPN clients (WireGuard App, Tunnelblick, OpenVPN Connect) via utun P2P detection
- External config file (`~/.splitroute/splitroute.conf`) with IP and CIDR routing rules
- Simple config format: plain text with one IP per line (also supports legacy bash array format)
- `splitroute` CLI with subcommands: `add`, `remove`, `list`, `edit`, `test`, `status`, `logs`, `version`, `reload`, `uninstall`, `help`
- Interactive first-time setup: installer prompts for IPs and proxy settings
- One-line remote installer: `curl -fsSL .../install.sh | bash`
- Background watch daemon with launchd KeepAlive (`com.splitroute.watch`)
- Optional proxy bridging for local proxy tools (ClashX, Surge, Stash, etc.)
- Automatic proxy cleanup on VPN disconnect
- Idempotent route checks (fixed-string matching) — no duplicate entries
- VPN interface retry with 15-second timeout and 2-second stabilization wait
- Auto log rotation (clears at 1MB)
- Shared function library (`splitroute-lib.sh`) for consistent VPN detection and logging
- `set -u` in route script to catch undefined variable errors
- Structured log timestamps with timezone (`%Y-%m-%d %H:%M:%S %Z`)
- launchd `ThrottleInterval` (10s) to prevent rapid restart loops
- `launchctl bootstrap/bootout` API with legacy `load/unload` fallback
- Makefile with install / uninstall / status / logs / version targets
- GitHub Actions ShellCheck CI (`--severity=warning`)
- `.editorconfig` and `.shellcheckrc` for contributor consistency
- GitHub issue templates (bug report and feature request)
- DNS troubleshooting documentation
- MIT License
