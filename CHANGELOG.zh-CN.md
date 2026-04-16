# 更新日志

> English version: [CHANGELOG.md](CHANGELOG.md)

## [1.4.0] - 2026-04-17

### 新增

- `splitroute domain add` 现在支持传入 IPv4 地址或 CIDR。这类条目**只**生成 PAC 的 `isInNet` DIRECT 规则，**不会**写入 macOS 路由表。适用场景：VPN 客户端已经自己管好了该 IP/网段的路由（例如 IKEv2 / WireGuard AllowedIPs 下发的内网段，或者 full-tunnel 把默认路由整段接管），你只需要让浏览器不要再把这些请求交给上游 HTTP 代理（Clash Verge 等）。**如果是需要 splitroute 自己把 VPN 路由装上**（SSH/curl/浏览器都要走 VPN 的那种），请继续用 `splitroute add <IP>` — 它同时写路由和 PAC。`splitroute domain list` 现在会把域名 pattern 和 PAC-only IP 分段显示，`status` / `doctor` / `pac show` 的计数也把 PAC-only IP 一起计入。

### 修复

- 之前往 `splitroute domain add` 传入 IP 会被写成 `domain: <ip>`，PAC 用 `shExpMatch` 当文本匹配 hostname，根本不会生效（不会按 IP 命中）。这种历史条目现在会被正确识别为 PAC-only IP 规则。

## [1.3.0] - 2026-04-17

### 新增

- **浏览器分流（PAC）**：splitroute 现在托管一个 Proxy Auto-Config 文件在 `http://127.0.0.1:7899/proxy.pac`，并自动注册为 macOS 所有活动网络服务的 auto-proxy URL。Chrome、Safari 等支持 PAC 的应用会把配置的域名/IP 段走 VPN（`DIRECT` → 内核路由表 → VPN），其余流量回落到原来的 HTTP 代理（如 `127.0.0.1:7890` 的 Clash Verge）。Clash 配置**不用动**。
- `splitroute domain add|remove|list`：管理 PAC 域名规则（`*.company.com` 这类 shExpMatch pattern）。配置变更在 30s 内热加载。
- `splitroute dns add <suffix> [<nameserver>|auto] / remove / list`：维护 `/etc/resolver/<suffix>` 条目，让只在内网可解析的域名走 VPN 推下来的 DNS。`auto` 在 VPN 连上后从 `scutil --dns` 读取 nameserver。
- `splitroute pac [url|show|status]`：查看 PAC 端点和生成的文件。
- `splitroute doctor` 增加第 7 步：PAC 服务器可达性 + 各活动网络服务的 auto-proxy URL 校验；`--fix` 会重新写 auto-proxy URL。
- `splitroute-priv`：受限、带 marker 校验的特权辅助工具（`write-resolver` / `delete-resolver` / `cleanup-resolver`）。只动它自己写过 marker 的 `/etc/resolver/<suffix>` 文件。
- 配置新增：`domain:`、`dns:`、`pac_enabled`、`pac_port`、`upstream_proxy`、`manage_resolver`、`auto_set_system_proxy`。都有合理默认值；典型用法只需要配 `domain:`。
- `auto` 上游代理探测：自动检测 Clash Verge / ClashX Meta / Surge 常用端口（`7890`、`7897`、`6152`），哪个在监听用哪个。
- 网络服务自动同步：每 30 秒重新把 PAC URL 写一遍，以应对 WiFi ↔ 以太网切换。
- 热加载：watch 守护进程按 mtime 检测 `splitroute.conf` 变更，无需重启即可刷新 PAC + resolver + auto-proxy。

### 变更

- sudoers 文件新增允许 `/usr/local/bin/splitroute-priv`（输入校验的辅助工具）；原有的 `/sbin/route` 和 `/usr/sbin/networksetup` 条目未动。

## [1.2.1] - 2026-04-14

### 修复

- `splitroute reload` 间歇性失败：`Load failed: 5: Input/output error`，经常要重试 2–3 次。根因：`launchctl bootout` 是异步的，发完 SIGTERM 就返回，紧跟着的 `launchctl bootstrap` 看到 label 还没注销，返回 EIO。现在 `reload` / `uninstall` / 安装程序都会轮询 `launchctl print`，确认 label 消失（超时 5s）后再 bootstrap。
- `splitroute reload` 在新旧两套加载 API 都失败时仍然打印 "Service reloaded"。现在只有服务真的加载成功才报 success，否则输出可操作的错误信息（exit code 1）。

## [1.2.0] - 2026-04-14

### 新增

- `splitroute doctor` 增加第 6 步 `Proxy listener`：当 `proxy = true` 时探测 `127.0.0.1` 上配置的 HTTP/SOCKS 端口，告诉你代理工具是否真的起来了。如果 HTTP 和 SOCKS 配了同一端口（如 Clash Verge `7897`），只探一次。
- 交互安装脚本在询问端口之前打印一个代理端口对照表（ClashX Meta / Stash、Clash Verge、Surge），不用离开终端就能选对端口。

## [1.1.0] - 2026-03-11

### 新增

- `splitroute doctor [--fix]`：5 步自检（daemon、config、VPN、routes、connectivity），可选自动修复。
- `splitroute apply`：无需等 watch 守护进程，手动立刻写路由。
- `splitroute status` 每条路由前加 `[OK]` / `[STALE]` 标记。
- watch 守护进程每 30 秒定期校验路由，作为兜底。

### 修复

- VPN 重连路由丢失：watch 守护进程现在记录具体的 VPN 接口名（比如 `utun3`），而不只是"VPN 是否连上"，所以重连导致接口号变化（比如 `utun3` → `utun5`）时会重新应用路由。

## [1.0.0] - 2026-03-07

### 新增

- macOS VPN 自动分流隧道（L2TP/IPsec、IKEv2、WireGuard、OpenVPN）。
- 支持第三方 VPN 客户端（WireGuard App、Tunnelblick、OpenVPN Connect），通过 utun P2P 检测识别接口。
- 外部配置文件 `~/.splitroute/splitroute.conf` 承载 IP / CIDR 路由规则。
- 简洁配置格式：纯文本，一行一个 IP（也兼容遗留的 bash 数组格式）。
- `splitroute` CLI 子命令：`add`、`remove`、`list`、`edit`、`test`、`status`、`logs`、`version`、`reload`、`uninstall`、`help`。
- 首次安装交互式配置：安装器引导填写 IP 和代理设置。
- 一行远程安装：`curl -fsSL .../install.sh | bash`。
- launchd KeepAlive 管理的后台 watch 守护进程（`com.splitroute.watch`）。
- 可选的本地代理桥接（ClashX、Surge、Stash 等）。
- VPN 断开时自动清理代理。
- 幂等路由检测（fixed-string 匹配）— 不会重复注入。
- VPN 接口重试：15 秒超时 + 2 秒稳定等待。
- 日志自动轮转（1MB 清空）。
- 共享函数库 `splitroute-lib.sh`：统一 VPN 检测和日志逻辑。
- routes 脚本启用 `set -u`，捕获未定义变量错误。
- 带时区的结构化日志时间戳（`%Y-%m-%d %H:%M:%S %Z`）。
- launchd `ThrottleInterval`（10s），防止快速重启循环。
- `launchctl bootstrap/bootout` API，带 `load/unload` 旧 API 回退。
- Makefile：install / uninstall / status / logs / version。
- GitHub Actions ShellCheck CI（`--severity=warning`）。
- `.editorconfig` 和 `.shellcheckrc`：贡献者一致性。
- GitHub issue 模板（bug 和 feature）。
- DNS 故障排查文档。
- MIT License。
