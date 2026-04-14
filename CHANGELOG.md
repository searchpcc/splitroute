# Changelog

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
