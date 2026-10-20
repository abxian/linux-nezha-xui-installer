# Linux 多公网 IP 节点一键安装

本仓库提供两套独立脚本：

- `install.sh`：旧版 x-ui `0.3.2` + 新版 Xray + Shadowsocks，默认端口 `80`
- `install-3xui-reality.sh`：最新版 3x-ui + VLESS REALITY，默认端口 `443`

两套面板都使用 `/usr/local/x-ui` 和 `x-ui` 服务，不能同时安装在一台服务器上。脚本面向网卡直接配置了一个或多个公网 IPv4 的 Debian/Ubuntu VPS；每个公网 IP 会生成一条独立节点。

## 3x-ui + VLESS REALITY 443

无参数一键命令：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/abxian/linux-nezha-xui-installer/main/install-3xui-reality.sh)"
```

默认配置：

| 配置 | 默认值 |
|---|---|
| 3x-ui 账号 / 密码 | `wochiniming` / `wochiniming` |
| 面板端口 / 路径 | `18181` / `/reality/` |
| 节点协议 | VLESS + REALITY |
| 节点端口 | `443/tcp` |
| Flow | `xtls-rprx-vision` |
| REALITY SNI / 目标站点 | `www.cloudflare.com` |
| UUID、X25519 密钥、short ID | 自动随机生成 |
| `direct` 出站 | `freedom` + `sendThrough: origin` |

脚本沿用已验证可用的 x-ui 多 IP 方案：只采用 Linux 网卡上的公网 IPv4，在改动面板前逐个执行指定源地址的公网出口检查；创建 Reality 后，再对每个公网 IP 执行真实 VLESS REALITY 握手和代理访问，并要求代理出口与接入 IP 完全一致。端口仅监听但协议握手失败、密钥不匹配、地址指向其他服务器或同源出口失效时，脚本会报错并拒绝输出节点。

成功后会输出每个公网 IP 的 `vless://` 链接，并保存：

- `/root/independent-ip-reality.txt`：面板入口、账号密码和全部链接
- `/root/independent-ip-reality.yaml`：可直接合并到 Mihomo/OpenClash 的 `proxies:` 配置
- `/root/3x-ui-reality-diagnostic.log`：不含密码和分享链接的服务、核心、监听与日志诊断

OpenClash 必须使用支持 VLESS REALITY 的 Mihomo 内核。主机和云安全组需要放行 `18181/tcp` 与 `443/tcp`；管理端口 `18181` 建议只允许自己的管理 IP。

脚本通过 [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) 官方安装器安装最新版。安全续跑时，只有 `/etc/x-ui/install-result.env` 为 root 所有、权限安全、且账号、密码、端口和路径完全一致，脚本才会复用安装；已有节点也必须是端口 `443`、备注 `independent-ip-reality` 且所有 Reality 参数符合预期，绝不会覆盖不明节点。

如服务器有多个公网 IPv4、但只希望生成其中一个，可使用：

```bash
curl -fsSL https://raw.githubusercontent.com/abxian/linux-nezha-xui-installer/main/install-3xui-reality.sh | \
  sudo bash -s -- --public-host 203.0.113.10
```

该地址必须真实配置在本机网卡上。其他可选参数可通过 `bash install-3xui-reality.sh --help` 查看。

## x-ui + Shadowsocks 80

无参数一键命令：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/abxian/linux-nezha-xui-installer/main/install.sh)"
```

当前 `install.sh` 会执行一次干净重装：先下载并校验 x-ui `0.3.2` 和最新稳定版 Xray，完整备份已有 `/usr/local/x-ui`、`/etc/x-ui`、service 与命令，再初始化新数据库。安装失败且尚未提交结果时会尝试自动恢复旧版。

默认配置：

| 配置 | 默认值 |
|---|---|
| x-ui 账号 / 密码 | `wochiniming` / `wochiniming` |
| 面板端口 | `18181` |
| 节点协议 | Shadowsocks，TCP + UDP |
| 节点端口 | `80` |
| 加密 / 密码 | `aes-256-gcm` / `wochiniming` |
| `direct` 出站 | `freedom` + `sendThrough: origin` |

脚本检测网卡上的全部公网 IPv4，并逐个确认指定源地址能够以相同公网 IP 出站。一条 Shadowsocks 入站监听所有地址，通过 `sendThrough: origin` 让流量使用客户端接入的本机 IP 出站，因此每个公网 IP 都会生成一条独立节点。

成功后会保存：

- `/root/multiip-ss-links.txt`：全部 `ss://` 链接
- `/root/multiip-ss-clash.yaml`：Mihomo/OpenClash 配置
- `/root/x-ui-multiip-diagnostic.log`：脱敏诊断日志
- `/root/x-ui-reinstall-backup-时间戳/`：本次安装前备份

目前 x-ui 脚本仅支持 Debian/Ubuntu 的 `apt` 系统以及 x86_64、arm64。它会验证 Xray 完整配置、服务进程和 TCP/UDP 监听；UDP 是否从对应公网 IP 出站仍需在路由器端实测。

## 验证与卸载

```bash
sudo systemctl status x-ui --no-pager
sudo cat /root/independent-ip-reality.txt   # 3x-ui Reality
sudo cat /root/multiip-ss-links.txt         # x-ui Shadowsocks
sudo x-ui uninstall
```

## 重要说明

- 固定密码 `wochiniming` 是部署要求，属于弱口令。务必使用云防火墙限制面板管理端口。
- Reality 只使用 TCP 443；YAML 中的 `udp: true` 表示客户端允许 UDP 流量经 Xray 转发，不表示 Reality 自身监听 UDP 443，也不需要网站证书。
- `www.cloudflare.com` 仅作为 Reality 握手伪装目标/SNI，不需要申请或安装它的证书。
- 脚本不包含 Nezha Agent 或 Nezha 密钥。
- 网卡只有私网地址、依赖 NAT 映射或公网地址未直接配置到本机时，严格的多 IP 检查会停止；此时应先正确配置云网络，不能用第三方“查公网 IP”结果冒充本机入站地址。
- x-ui `0.3.2` 很旧，不建议把管理面板无访问控制地长期暴露到公网。

## 上游来源

- x-ui：<https://github.com/vaxilu/x-ui>（固定 `0.3.2`）
- Xray-core：<https://github.com/XTLS/Xray-core>（最新稳定版）
- 3x-ui：<https://github.com/MHSanaei/3x-ui>（官方安装器）
