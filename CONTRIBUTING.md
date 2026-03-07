# Contributing to splitroute

Thanks for your interest in contributing!

## Reporting Issues

Use the [issue templates](https://github.com/searchpcc/splitroute/issues/new/choose) and include:

- Your macOS version (`sw_vers`)
- Your VPN protocol (L2TP, IKEv2, WireGuard, OpenVPN)
- Relevant log output: `splitroute logs`
- Your splitroute version: `splitroute version`

## Pull Requests

1. Fork the repo and create a feature branch
2. Make sure all scripts pass ShellCheck: `shellcheck --severity=warning -s bash *.sh`
3. Test on your own macOS machine with a real VPN connection
4. Keep changes focused — one fix or feature per PR

## Code Style

- Shell scripts use bash (`#!/bin/bash`)
- Use `snake_case` for variables and functions
- Shared functions go in `splitroute-lib.sh`
- Log messages in English
- Comments for non-obvious logic only
- Follow `.editorconfig` settings (4-space indent for `.sh`, tabs for `Makefile`)

## File Structure

```
splitroute/                            (repo)
├── splitroute.sh                      # CLI entry point
├── splitroute-setup.sh                # installer (interactive)
├── splitroute-lib.sh                  # shared functions + config parser
├── splitroute-routes.sh               # core: route injection + proxy bridging
├── splitroute-watch.sh                # daemon: VPN connect/disconnect detection
├── splitroute.conf.example            # config template
├── com.splitroute.watch.plist         # launchd config template
├── install.sh                         # remote one-line installer
├── VERSION                            # version file
├── Makefile
├── .editorconfig
├── .shellcheckrc
├── .github/
│   ├── workflows/lint.yml             # ShellCheck CI
│   └── ISSUE_TEMPLATE/               # issue templates
├── CONTRIBUTING.md
├── CHANGELOG.md
├── LICENSE
├── README.md
└── README.zh-CN.md
```

After installation:

| File | Location | Purpose |
|------|----------|---------|
| Install dir | `~/.splitroute/` | All scripts, config, and VERSION |
| CLI | `/usr/local/bin/splitroute` | Global `splitroute` command |
| Config | `~/.splitroute/splitroute.conf` | Your routing rules |
| launchd | `~/Library/LaunchAgents/com.splitroute.watch.plist` | Auto-start on login |
| sudoers | `/etc/sudoers.d/splitroute` | Passwordless `route` and `networksetup` |

## Logs

| Path | Content |
|------|---------|
| `/tmp/splitroute.log` | Route additions, proxy changes, connect/disconnect events |
| `/tmp/vpn-watch-stdout.log` | Watch daemon stdout |
| `/tmp/vpn-watch-stderr.log` | Watch daemon stderr |

Logs auto-rotate at 1MB. Located in `/tmp/`, cleared on reboot.

## Config Formats

splitroute supports two config formats:

**New format (recommended)** — plain text, one IP per line:

```ini
interface = auto
proxy = false
http_port = 7890
socks_port = 7891

10.0.1.100
192.168.0.0/16
```

**Legacy format** — bash arrays (still supported):

```bash
ROUTE_IPS=(
    "10.0.1.100"
    "192.168.0.0/16"
)
VPN_INTERFACE=auto
PROXY_ENABLED=false
```

## Testing

There is no automated test suite — the core logic depends on macOS system commands (`route`, `ifconfig`, `networksetup`) that can't be meaningfully tested in CI. ShellCheck catches syntax and common shell issues.

Manual testing checklist:
- [ ] `make install` works on a clean macOS
- [ ] Interactive setup collects IPs and proxy settings correctly
- [ ] `splitroute add/remove/list` manage config correctly
- [ ] Routes added after VPN connects (`splitroute status`)
- [ ] Routes cleaned up after VPN disconnects
- [ ] `splitroute test <IP>` shows correct routing
- [ ] Proxy bridging works when `proxy = true`
- [ ] Proxy cleaned up after VPN disconnects
- [ ] `splitroute uninstall` removes everything
- [ ] Legacy config format (bash arrays) still works
