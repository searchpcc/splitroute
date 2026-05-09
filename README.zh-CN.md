# splitroute

[![ShellCheck](https://github.com/searchpcc/splitroute/actions/workflows/lint.yml/badge.svg)](https://github.com/searchpcc/splitroute/actions/workflows/lint.yml)
[![Tests](https://github.com/searchpcc/splitroute/actions/workflows/test.yml/badge.svg)](https://github.com/searchpcc/splitroute/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-12%2B-black.svg)](https://www.apple.com/macos/)

[English](README.md) | 中文

macOS VPN 自动分流工具。只让指定 IP 走 VPN 隧道，其余流量保持直连。

支持 L2TP/IPsec、IKEv2、WireGuard、OpenVPN。

## 快速开始

### 1. 准备 VPN

打开 **系统设置 > VPN**，选择你的 VPN 配置，**取消勾选**「通过 VPN 连接发送所有流量」。

### 2. 安装

```bash
curl -fsSL https://raw.githubusercontent.com/searchpcc/splitroute/main/install.sh | bash
```

或者手动安装：

```bash
git clone https://github.com/searchpcc/splitroute.git
cd splitroute
make install
```

安装过程会引导你配置需要走 VPN 的 IP，也可以之后再添加。

### 3. 添加路由

```bash
splitroute add 10.0.1.100        # 单个服务器
splitroute add 192.168.0.0/16    # 整个内网网段
```

### 4. 连接 VPN 并验证

正常连接 VPN，然后查看状态：

```bash
splitroute status
```

搞定。每次 VPN 连接时路由会自动生效。

---

## 工作原理

```
                     ┌────────────────┐
                     │  macOS 路由表    │
                     └───────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
       ┌──────▼──────┐ ┌────▼────┐  ┌──────▼──────┐
       │  你的路由规则 │ │  其他   │  │  默认网关    │
       │ (splitroute) │ │  流量   │  │            │
       └──────┬──────┘ └────┬────┘  └─────────────┘
              │              │
       ┌──────▼──────┐ ┌────▼────┐
       │  VPN 隧道    │ │  直连   │
       │ (ppp/utun)   │ │        │
       └─────────────┘ └────────┘
```

1. **路由注入** — VPN 连接后，自动为你配置的 IP 添加路由指向 VPN 接口
2. **自动检测** — 后台服务监控 VPN 连接/断开
3. **自动清理** — VPN 断开时系统自动移除路由

不需要特定启动顺序，后台服务开机自动运行。

## 常用命令

```
splitroute add <target>          智能添加 — IP / CIDR / 域名 / *.通配符 自动分发
splitroute remove <target>       智能移除 — 同 add 的输入形式
splitroute list                  列出所有已配置项
splitroute edit                  用编辑器打开配置文件
splitroute status                查看服务、VPN、路由和 PAC 状态
splitroute test <IP|hostname>    检查某个目标当前的路由路径
splitroute logs                  查看最近的日志
splitroute reload                重启后台服务
splitroute uninstall             卸载
splitroute help                  显示帮助

# 显式子命令（智能 add/remove 已自动分发到这些）
splitroute host add <hostname>   一条命令搞定：浏览器 + ssh/git/curl 都走 VPN
splitroute host remove <name>    移除（顺带清理自动加的 dns 后缀）
splitroute host list             列出所有 host 与当前解析到的 IP
splitroute domain add <pat|IP>   *.通配符或 IPv4/CIDR（仅浏览器，纯 PAC）
splitroute domain remove <pat>   移除域名规则或 PAC-only IP
splitroute domain list           列出域名规则与 PAC-only IP
splitroute dns add <sfx> [ns]    将一个 DNS 后缀映射到内网 DNS（或 'auto'）
splitroute dns remove <sfx>      移除 DNS 覆盖
splitroute dns list              列出 DNS 覆盖
splitroute pac [url|show|status] 查看 PAC 地址和生成文件
```

### 一条命令搞定一个域名

最常见的需求 —— 「让 `git.company.com` 在浏览器、git、ssh 三种场景下都走 VPN」—— `splitroute add` 会自动判断输入类型并配齐三层：

```bash
splitroute add git.company.com               # 浏览器 + ssh + git，全走 VPN
splitroute add bastion.company.com           # SSH 跳板机走 VPN
splitroute add git.company.com 10.0.1.5      # 同上，但把 IP 写死，跳过 DNS 解析
splitroute add 10.20.0.0/16                  # 任意程序：整段 CIDR 走 VPN
splitroute add '*.corp.internal'             # 仅浏览器 — 通配符 PAC
```

输入一个裸域名时，幕后会做三件事：

1. PAC 加一条 `DIRECT`，浏览器对该域名绕过 Clash。
2. 自动追加 `dns: <父域名> auto`（如尚未配置）—— 让 DIRECT 解析走 VPN 推送的 DNS。
3. VPN 连上后，watch 循环用 VPN DNS 解析这个域名，把每个 A 记录加到路由表；之后周期性重解析，IP 变了自动更新。

带 IP 的形式 (`splitroute add <hostname> <ip>`) 会跳过第 2 步，改为把一行带 splitroute 标记的记录写入 `/etc/hosts`，让系统本地直接解析。**适合 IP 固定且稳定的场景**：完全不依赖 VPN DNS 可达、VPN 一连上立刻可用、每次访问不再有 DNS 轮询。

`splitroute remove git.company.com` 反向清理（如父域名 `dns:` 已无其他 host 占用则一并删除；带 IP 的 host 在下次 sync 时从 `/etc/hosts` 移除）。

## 配置

配置文件位于 `~/.splitroute/splitroute.conf`。

可以用 `splitroute add/remove` 管理路由，也可以直接编辑配置文件：

```ini
# VPN 接口检测（一般不用改）
# auto = 自动检测 | ppp = 仅 L2TP | utun = 仅 IKEv2/WireGuard
interface = auto

# 代理桥接（使用代理工具时开启，见下方说明）
proxy = false
http_port = 7890
socks_port = 7891

# === 路由规则 ===
10.0.1.100
192.168.0.0/16
```

修改后无需重启服务，下次 VPN 连接自动生效。

### 代理桥接（可选）

如果你使用代理工具（ClashX Meta、Surge、Stash 等），VPN 连接可能导致代理的系统代理设置失效。开启代理桥接可以解决这个问题：

```bash
splitroute edit
```

然后设置：

```ini
proxy = true
http_port = 7890      # 按你的代理工具设置
socks_port = 7891
```

常见代理工具端口：

| 工具 | HTTP | SOCKS |
|------|------|-------|
| ClashX Meta | 7890 | 7891 |
| Clash Verge | 7897 | 7897 |
| Surge | 6152 | 6153 |
| Stash | 7890 | 7891 |

> **为什么会失效？** VPN 连接后，macOS 会为隧道创建一个新的网络服务。代理工具只在 Wi-Fi 上设置了系统代理，VPN 网络服务上没有。代理桥接让 splitroute 自动在 VPN 网络服务上也设置系统代理。

## 浏览器分流（PAC）

> v1.3 新增

路由表对走 OS socket 的程序（SSH、`curl`、`git`、原生 app）都生效。**浏览器不一样。** 如果你用 Clash Verge 这类代理工具并开着「系统代理」，Chrome 会把每个请求先丢给代理，splitroute 的路由根本没机会触发，公司内网域名就被机场代理走岔了。

v1.3 的做法：splitroute 托管一个 **PAC（Proxy Auto-Config）** 文件，并把它注册成 macOS 的系统 auto-proxy URL。PAC 告诉浏览器："公司域名和 IP 段走 `DIRECT`（让 OS 路由表命中 splitroute 送进 VPN），其它一律走你原来的代理（Clash 之类）。"

**Clash 配置完全不用动。**

### 配置步骤

```bash
# 要在浏览器里走 VPN 的域名
splitroute domain add '*.company.com'
splitroute domain add '*.corp.internal'

# 仅浏览器经 VPN 的 IP / CIDR（只生成 PAC `isInNet` DIRECT，不写 macOS 路由表）。
# 适用场景：VPN 客户端已经安装了路由，只需要让浏览器绕过上游代理。
# 如果 SSH/curl 等也需要走 VPN，请改用 `splitroute add <IP>`（同时写路由和 PAC）。
splitroute domain add 10.0.1.5
splitroute domain add 10.0.2.0/24

# 内网 DNS 覆盖（让 DIRECT 的域名能解析到内网 IP）。
# 'auto' 会在 VPN 连上后从 scutil --dns 自动读取 VPN 推下来的 DNS。
splitroute dns add company.com auto
splitroute dns add corp.internal auto

# 验证
splitroute status
splitroute pac show     # 看生成的 PAC JS 内容
splitroute doctor       # 7 步自检，含 PAC 服务 + autoproxy URL 校验
```

就这样。后台服务会：

- 根据配置生成 `~/.splitroute/pac/proxy.pac`
- 在 `http://127.0.0.1:7899/proxy.pac` 起一个本地 HTTP server（macOS 自带的 `python3 -m http.server`，仅监听 127.0.0.1）
- 对每个活跃的网络服务（Wi-Fi、以太网等）执行 `networksetup -setautoproxyurl`，并每 30 秒重新应用一次（保证切换网卡后自动跟上）
- VPN 连上时写 `/etc/resolver/<suffix>`；断开时清理
- 监测 `~/.splitroute/splitroute.conf` 的 mtime，约 30 秒内热重载，不用重启
- `splitroute uninstall`（或 `launchctl bootout`）时，每个网络服务恢复原 auto-proxy 状态，并删除自己写过的 `/etc/resolver` 文件

### PAC 分流路径

```
Chrome → 系统代理 → PAC FindProxyForURL(host):
  host ~ *.company.com       → DIRECT → OS 路由 → splitroute 送入 VPN
  host 属于 10.0.0.0/8       → DIRECT → OS 路由 → splitroute 送入 VPN
  其它                       → PROXY 127.0.0.1:7890（Clash 等）
```

### VPN 断开时

PAC server 和 auto-proxy URL 保持常驻，非公司流量继续走 Clash，浏览器不会掉线。命中公司规则的 DIRECT 请求会在 DNS 阶段失败（内网 DNS 不可达）—— 这就是离开 VPN 时应有的表现。

### 特权辅助程序

管理 `/etc/resolver/<suffix>` 需要 root。splitroute 装了一个小的 helper `/usr/local/bin/splitroute-priv`，通过 sudoers NOPASSWD 执行。它会严格校验输入（DNS 合法的 suffix、IPv4 格式的 nameserver），并且**只动带有 splitroute marker 行的文件**—— 不能被用来写或删任意路径。

### 配置文件写法

```ini
# ~/.splitroute/splitroute.conf — 浏览器 PAC 段

# 默认值（以下全部可选）:
# pac_enabled = auto            # auto = 出现 domain: / dns: 行时自动开启
# pac_port = 7899
# upstream_proxy =              # 空 = 自动探测 Clash（7890/7897/6152）
# auto_set_system_proxy = true
# manage_resolver = true

domain: *.company.com
domain: *.corp.internal

# IP/CIDR 路由规则（已有）会同时用于 PAC 的 isInNet() 判断
10.0.0.0/8
172.16.0.0/12

dns: company.com auto
dns: corp.internal auto
```

## 支持的 VPN 协议

| 协议 | 接口 | 状态 |
|------|------|------|
| L2TP/IPsec | `ppp0` | 支持 |
| IKEv2（系统） | `utun*` | 支持 |
| WireGuard（系统） | `utun*` | 支持 |
| WireGuard App | `utun*` | 支持 |
| OpenVPN / Tunnelblick | `utun*` | 支持 |

> 仅支持 IPv4。

## 系统要求

- **macOS 12 Monterey 及以上**（已在 macOS 12–15 上测试）
- 管理员权限（安装时需要 sudo）
- 已配置 VPN 连接，并**取消勾选**「发送所有流量」

> **macOS 15 Sequoia 注意：** Apple 移除了内置 L2TP/IPsec。请使用第三方 L2TP 客户端或改用 IKEv2/WireGuard/OpenVPN。

所有依赖命令均为 macOS 内置，**无需安装任何外部工具**。

## 常见问题

**路由未生效**

```bash
splitroute status     # 检查服务和配置
splitroute logs       # 查看错误信息
```

常见原因：
- 未添加路由规则：运行 `splitroute add <IP>`
- 服务未运行：运行 `splitroute reload`

**检查某个 IP 是否走了 VPN**

```bash
splitroute test 10.0.1.100
```

**内网域名无法解析**

v1.3 起 splitroute 可以帮你管 `/etc/resolver/*`：

```bash
splitroute dns add internal.company.com auto       # auto = 用 VPN 推下来的 DNS
# 或显式指定 nameserver：
splitroute dns add internal.company.com 10.0.0.1
```

也可以按老办法手动写：

```bash
sudo mkdir -p /etc/resolver
echo "nameserver 10.0.0.1" | sudo tee /etc/resolver/internal.company.com
```

**浏览器仍然走 Clash，没走 VPN**

跑 `splitroute doctor`—— 第 7 步会校验 PAC server 是否可达、所有活跃网络服务的 auto-proxy URL 是否指向 splitroute。出问题用 `splitroute doctor --fix` 重新应用。也可以用 `splitroute pac show` 看一眼生成的 PAC 规则。

**代理工具连接 VPN 后失效**

开启代理桥接：运行 `splitroute edit`，设置 `proxy = true`。

## 卸载

```bash
splitroute uninstall
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
