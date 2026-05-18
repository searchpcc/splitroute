# 更新日志

> English version: [CHANGELOG.md](CHANGELOG.md)

## [1.5.1] - 2026-05-19

### 修复

- **PAC 上游代理现在不需要重启或等 VPN 切换就能自动更新。** 之前 `detect_upstream_proxy` 只在 `reconcile_full`（VPN 状态变化 / 配置文件修改）里跑一次，所以 PAC 文件里的 `PROXY <host:port>` 那行被冻结在上次 reconcile 的瞬间。后果：splitroute 先于 Clash Verge / ClashX / Surge 启动 —— PAC 写成 `return "DIRECT"`，浏览器到下次 VPN 重连或改配置之前都绕过上游代理；切换代理工具（如 Clash Verge → Surge）或 Clash 换端口重启 —— PAC 仍然指着已经死掉的端口。`reconcile_drift` 现在每 30 秒重新探测一次，只有探测结果和上次应用的值不一致时才重写 PAC。状态持久化在 `~/.splitroute/state/last_upstream`，watch 重启后依然可靠。对"代理工具先启动、splitroute 后启动"的常见用户没有任何配置或行为变化 —— 唯一区别是反向启动顺序（以及代理工具中途重配）现在能在 30 秒内自愈。

## [1.5.0] - 2026-05-10

### 新增

- `splitroute add <hostname> --no-auto-dns` 跳过自动派生 `dns: <父域名> auto` 的副作用。适用场景：父域名上还挂着不该走 VPN DNS 的公网服务，你只想让指定 hostname 走 VPN，DNS 自己管。flag 位置随便放。
- `splitroute doctor` 从 7 步扩到 8 步。新增第 5 步 Hosts，检查 `host:` 项的解析状态、/etc/hosts 是否同步、每个 IP 的路由状态。第 4 步（Routes）现在会识别老版本 splitroute 留下的 IFSCOPE 路由并建议 `--fix` 迁移。第 3 步（VPN）显示对端地址或「无独立 peer」标记，方便区分 L2TP 和 utun 协议。
- 基于 bats 的测试套件（`tests/` 目录），覆盖 lib 工具函数、config 解析器、PAC 生成器、特权 helper、智能 `add`/`remove` 分发器（80 个测试）。新 GitHub Actions workflow `.github/workflows/test.yml` 在 Ubuntu + macOS 上运行。

### 改动

- watch 循环重构为两个 reconcile 函数：`reconcile_full`（VPN 状态变化或 config 变化时跑一次完整应用）和 `reconcile_drift`（每 30 秒跑一次，只对真正漂移的部分动作）。单一 dispatch 入口替代之前嵌套的循环逻辑。行为不变，可读性大幅提升。
- `get_vpn_gateway` 检测到 VPN「对端 == 本机」时返回空字符串（utun 协议 WireGuard / IKEv2 native 的常见特征）。peer-as-gateway 这招只对有独立对端的协议有效（L2TP/PPP、OpenVPN）。utun 协议自动 fallback 到 `-interface <vpn_if>`，因为这些协议本就不会加 CLONING 默认路由所以不会被 IFSCOPE 化。

### 修复

- **路由表里有条目但流量根本不走 VPN 的隐性故障**（L2TP/PPP 上 split tunneling 静默失效）。关闭「通过 VPN 发送所有流量」后，macOS 会给所有 `-interface ppp0` 形式的路由打 `IFSCOPE` 标记 —— 这种路由只对绑定到 ppp0 的流量可见，普通 app（ssh/curl/git）不绑定接口，就漏到 en0 默认网关。`splitroute status` 因为只看路由表里是否有这条记录，会误报 `[OK]`，但 `route get <ip>` 实际返回的是 en0。修复：`splitroute-routes.sh` 和 `splitroute-hosts.sh` 改为用 VPN peer IP 当 gateway（`route add -host <ip> <peer>`），不再用 `-interface <vpn_if>`，新路由不带 IFSCOPE，所有 app 都能命中。升级后 `splitroute reload` 会自动 delete + re-add 老的 IFSCOPE 路由，迁移无感。对于拿不到 peer 的 VPN 协议（少见），自动 fallback 到老的 `-interface` 形式。
- 新增 `get_vpn_gateway` lib helper：从 `ifconfig <iface>` 的 `inet ... --> <peer>` 行读出对端 IP。

### 改动

- `splitroute uninstall` 现在会先问你是否备份配置（默认 Y），且如果已经有旧的 `~/.splitroute.conf.bak`，会先把它轮转成带时间戳的名字（`~/.splitroute.conf.bak.YYYYmmdd-HHMMSS`），避免反复 uninstall/reinstall 把更早的保存覆盖掉。非交互模式保持原本「总是备份」的行为。
- `splitroute-setup.sh`（`make install` / curl 一键安装的脚本）现在会检测上次卸载留下的 `~/.splitroute.conf.bak`，**先问你要不要恢复**再走交互配置或模板路径。会显示备份的修改时间，方便你确认是不是想要的那份。

### 新增

- **一条命令搞定一个域名**（`splitroute add <hostname>`）：直接传入裸域名时，会写入一行 `host:` 配置，自动同时配齐三层 —— PAC 加 `DIRECT` 让浏览器绕过 Clash、自动派生 `dns: <父域名> auto` 让 DIRECT 解析走 VPN DNS、watch 循环用 VPN DNS 解析后注入每条 A 记录的路由。每 ~30s 重解析一次，DNS 变化自动跟进。替代原本三步走的常见场景（`splitroute domain add` + `splitroute dns add` + `splitroute add <IP>`）。
- **固定 IP 域名**（`splitroute add <hostname> <ip>`）：IP 已知且稳定时，可以直接带 IP，让 splitroute 跳过 DNS 解析这一层。watch 循环会通过 `splitroute-priv` 的新 `hosts-sync` 子命令往 `/etc/hosts` 写一行带 splitroute 标记的记录（这个命令只允许改自己标记过的行），再装好路由。**完全不 dig**、**不依赖 VPN DNS 可达**、VPN 一连上立刻生效。
- `splitroute add` 升级为智能分发：IPv4/CIDR 走路由表；裸域名走 `host:` 三层捆绑；裸域名 + IP 走固定 IP 模式；`*.通配符` 走纯 PAC 的 `domain:`。`splitroute remove` 对称支持同样的输入形式；当某父域名后缀下没有 host 时自动清理该后缀的 `dns:`；`/etc/hosts` 在下个 watch tick 会从配置重新 sync（卸载时则整体清空）。
- 新增 `splitroute host add/remove/list`，显式子命令；`host list` 会同时显示「pinned」固定 IP 和 watch 循环动态解析到的 IP。
- `splitroute test` 现在支持传入域名（自动解析并检查每条 A 记录的路径）。
- 新模块 `splitroute-hosts.sh`：解析循环、状态文件、路由 diff/清理、/etc/hosts sync。状态保存在 `~/.splitroute/state/hosts.state`，跨重启可识别新增/失效的 IP。
- `splitroute-priv` 新增两个子命令：`hosts-sync`（从 stdin 读 `ip<TAB>hostname` 对，原子重写 `/etc/hosts` 中带 splitroute 标记的那块）和 `hosts-cleanup`（移除所有标记行）。

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
