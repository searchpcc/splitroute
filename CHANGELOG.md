# Changelog

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
