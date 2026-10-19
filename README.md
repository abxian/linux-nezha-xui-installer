# Linux 独立 IP 节点一键安装

本仓库提供两套相互独立的一键脚本：

- `install.sh`：旧版 x-ui + Shadowsocks，默认节点端口 `80`
- `install-3xui-reality.sh`：新版 3x-ui + VLESS REALITY，默认节点端口 `443`

两套面板都使用 `/usr/local/x-ui` 和 `x-ui` 服务，不能同时安装在同一台服务器。两个脚本检测到已有 x-ui/3x-ui 时都会停止，避免覆盖现有节点。

## 3x-ui + VLESS REALITY 443

直接执行下面这一条命令，无需附加参数：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/abxian/linux-nezha-xui-installer/main/install-3xui-reality.sh)"
```

默认配置：

| 配置 | 默认值 |
|---|---|
| 3x-ui 账号 | `wochiniming` |
| 3x-ui 密码 | `wochiniming` |
| 3x-ui 面板端口 | `18181` |
| 3x-ui 面板路径 | `/reality/` |
| 节点协议 | `VLESS + REALITY` |
| 节点端口 | `443/tcp` |
| Flow | `xtls-rprx-vision` |
| REALITY SNI/目标站点 | `www.cloudflare.com` |
| UUID、X25519 密钥、short ID | 自动随机生成 |

安装成功后会在终端显示 VLESS 链接，并保存：

- `/root/independent-ip-reality.txt`：面板入口、账号密码和完整 `vless://` 链接
- `/root/independent-ip-reality.yaml`：可放入 Mihomo/OpenClash `proxies:` 的节点 YAML

把 `vless://...` 直接导入支持 REALITY 的路由器客户端即可；使用 OpenClash 时，内核必须使用支持 VLESS REALITY 的 Mihomo 版本。主机防火墙会在检测到已启用的 UFW/firewalld 时放行 `18181/tcp` 和 `443/tcp`，云服务器安全组也需要放行这两个 TCP 端口。

需要覆盖默认值时，可以使用参数版本：

```bash
curl -fsSL https://raw.githubusercontent.com/abxian/linux-nezha-xui-installer/main/install-3xui-reality.sh | \
  sudo bash -s -- \
  --username admin \
  --password 'CHANGE_ME' \
  --panel-port 18181 \
  --reality-port 443 \
  --reality-sni www.cloudflare.com
```

脚本通过 [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) 官方安装器安装最新稳定版，并用当前面板 API 创建 REALITY 入站。面板本身默认使用 HTTP；固定弱口令与公开管理端口存在明显风险，至少应在云安全组限制 `18181/tcp` 只允许你的管理 IP 访问。REALITY 节点的 `443/tcp` 则需要对客户端开放。

验证与卸载：

```bash
sudo systemctl status x-ui --no-pager
sudo cat /root/independent-ip-reality.txt
sudo cat /root/independent-ip-reality.yaml
sudo x-ui uninstall
```

## x-ui + Shadowsocks 80

为普通 Linux 服务器一次性安装：

- `unzip`（不存在时自动安装）
- `vaxilu/x-ui` `0.3.2`
- x-ui 面板：端口 `18181`，账号和密码均为 `wochiniming`
- 默认节点协议：Shadowsocks
- Shadowsocks：默认端口 `80`，加密方式 `aes-256-gcm`，TCP+UDP
- 自动输出 `ss://` 链接和 Clash/OpenClash 节点 YAML

## 使用

目标机需要：Linux、systemd、root 权限，以及 `apt-get`、`dnf` 或 `yum` 之一。目前支持 x86_64、arm64 和 armv7。

直接执行这一条完整命令，不需要附加任何参数：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/abxian/linux-nezha-xui-installer/main/install.sh)"
```

这条命令全程无交互，直接使用以下默认值：

| 配置 | 默认值 |
|---|---|
| x-ui 账号 | `wochiniming` |
| x-ui 密码 | `wochiniming` |
| x-ui 面板端口 | `18181` |
| 节点协议 | `Shadowsocks` |
| Shadowsocks 端口 | `80` |
| Shadowsocks 加密 | `aes-256-gcm` |
| Shadowsocks 密码 | 自动生成 32 位十六进制密码 |

脚本不安装 Nezha Agent，也不读取任何 Nezha 密钥。

脚本会自动检测服务器公网 IPv4，并随机生成 32 位十六进制 Shadowsocks 密码。

也可克隆仓库后直接执行：

```bash
git clone https://github.com/abxian/linux-nezha-xui-installer.git
cd linux-nezha-xui-installer
sudo bash install.sh
```

需要修改默认值时，可使用参数版本：

```bash
curl -fsSL https://raw.githubusercontent.com/abxian/linux-nezha-xui-installer/main/install.sh | \
  sudo bash -s -- \
  --username admin \
  --password 'CHANGE_ME' \
  --panel-port 18181 \
  --ss-port 8388 \
  --ss-method aes-256-gcm
```

支持 `--username`、`--password`、`--panel-port`、`--ss-port`、`--ss-method`、`--ss-password` 和 `--public-host`。运行 `bash install.sh --help` 可查看完整说明。密码若直接写在命令行中可能进入 shell 历史；默认无参数命令不会暴露密码参数。

安装成功后会显示并保存：

- `/root/independent-ip-node.txt`：面板地址、账号密码和 `ss://` 链接
- `/root/independent-ip-clash.yaml`：可粘贴进 Clash/OpenClash `proxies:` 的节点

把终端显示的 `ss://...` 导入路由器，或将 YAML 条目放入 OpenClash 配置的 `proxies:`，再把节点名 `independent-ip` 加进需要的策略组。

## 防火墙

脚本会在已经启用的 UFW 或 firewalld 中放行：

- `18181/tcp`：x-ui 面板
- `80/tcp`、`80/udp`：默认 Shadowsocks 端口

云服务器还需要在云安全组中放行同样端口。若选择了自定义 Shadowsocks 端口，请放行实际选择的 TCP 和 UDP 端口。

## 重要说明

- `vaxilu/x-ui` 最新发布 `0.3.2` 来自 2021 年，已经非常旧。本仓库按指定来源固定该版本，不代表它适合长期暴露在公网。
- 固定弱口令 `wochiniming` 是明确的部署要求。建议至少用云防火墙限制 `18181/tcp` 只允许管理 IP 访问。
- 本脚本仅安装 x-ui 并创建 Shadowsocks 节点，不包含 Nezha Agent 功能。
- 为避免生成的 `ss://` 链接产生分隔歧义，自定义 Shadowsocks 密码不能包含 `:` 或 `@`。
- 安装前若检测到已有 x-ui，或所选 SS 端口/18181 已占用，脚本会停止，避免覆盖现有服务。
- 本脚本会安装服务并修改启用中的 UFW/firewalld，建议先在新服务器上使用。

## 验证

```bash
sudo systemctl status x-ui --no-pager
sudo cat /root/independent-ip-node.txt
sudo cat /root/independent-ip-clash.yaml
```

## 卸载

x-ui 可运行 `x-ui uninstall`。卸载前请保留 `/root/independent-ip-node.txt` 作为节点记录，并按需撤销主机防火墙和云安全组规则。

## 上游来源

- x-ui：<https://github.com/vaxilu/x-ui>（固定 release `0.3.2`）
- 3x-ui：<https://github.com/MHSanaei/3x-ui>（官方安装器选择最新稳定版）
