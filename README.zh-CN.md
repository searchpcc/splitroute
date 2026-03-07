# splitroute

[![ShellCheck](https://github.com/searchpcc/splitroute/actions/workflows/lint.yml/badge.svg)](https://github.com/searchpcc/splitroute/actions/workflows/lint.yml)
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
splitroute add <IP>       添加一个 IP 或网段到 VPN 路由
splitroute remove <IP>    从路由中移除
splitroute list           列出所有已配置的路由
splitroute edit           用编辑器打开配置文件
splitroute status         查看服务、VPN 和路由状态
splitroute test <IP>      检查某个 IP 当前的路由路径
splitroute logs           查看最近的日志
splitroute reload         重启后台服务
splitroute uninstall      卸载
splitroute help           显示帮助
```

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

splitroute 只处理路由，不处理 DNS。如需通过 VPN DNS 解析内网域名：

```bash
sudo mkdir -p /etc/resolver
echo "nameserver 10.0.0.1" | sudo tee /etc/resolver/internal.company.com
```

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
