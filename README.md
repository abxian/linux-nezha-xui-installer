# Linux Nezha Agent + x-ui 独立 IP 一键安装

为普通 Linux 服务器一次性安装：

- `unzip`（不存在时自动安装）
- 可选安装官方 Nezha Agent，连接 `rc.010199.xyz:18181`，`NZ_TLS=false`
- `vaxilu/x-ui` `0.3.2`
- x-ui 面板：端口 `18181`，账号和密码均为 `wochiniming`
- Shadowsocks：默认端口 `80`（可交互改成自定义端口），`aes-256-gcm`，TCP+UDP
- 自动输出 `ss://` 链接和 Clash/OpenClash 节点 YAML

## 使用

目标机需要：Linux、systemd、root 权限，以及 `apt-get`、`dnf` 或 `yum` 之一。目前支持 x86_64、arm64 和 armv7。

直接执行这一条完整命令，不需要附加任何参数：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/abxian/linux-nezha-xui-installer/main/install.sh)"
```

执行后会依次询问：

- 是否安装 Nezha Agent；选择安装时，无回显输入 `NZ_CLIENT_SECRET`
- Shadowsocks 是否使用默认端口 `80`；选择否时输入自定义端口

脚本会自动检测服务器公网 IPv4，并随机生成 32 位十六进制 Shadowsocks 密码。

也可克隆仓库后执行，交互内容相同：

```bash
git clone https://github.com/abxian/linux-nezha-xui-installer.git
cd linux-nezha-xui-installer
sudo bash install.sh
```

安装成功后会显示并保存：

- `/root/independent-ip-node.txt`：面板地址、账号密码和 `ss://` 链接
- `/root/independent-ip-clash.yaml`：可粘贴进 Clash/OpenClash `proxies:` 的节点

把终端显示的 `ss://...` 导入路由器，或将 YAML 条目放入 OpenClash 配置的 `proxies:`，再把节点名 `independent-ip` 加进需要的策略组。

## 防火墙

脚本会在已经启用的 UFW 或 firewalld 中放行：

- `18181/tcp`：x-ui 面板
- `80/tcp`、`80/udp`：Shadowsocks

云服务器还需要在云安全组中放行同样端口。Nezha Agent 连接的远端 `rc.010199.xyz:18181` 是出站连接，与本机 x-ui 监听 `18181` 不冲突。

## 重要说明

- `vaxilu/x-ui` 最新发布 `0.3.2` 来自 2021 年，已经非常旧。本仓库按指定来源固定该版本，不代表它适合长期暴露在公网。
- 固定弱口令 `wochiniming` 是明确的部署要求。建议至少用云防火墙限制 `18181/tcp` 只允许管理 IP 访问。
- `NZ_CLIENT_SECRET` 不写入 Git 历史；仅在选择安装 Nezha 时由终端无回显读取，再交给官方安装器。
- 安装前若检测到已有 x-ui，或所选 SS 端口/18181 已占用，脚本会停止，避免覆盖现有服务。
- 本脚本会安装服务并修改启用中的 UFW/firewalld，建议先在新服务器上使用。

## 验证

```bash
sudo systemctl status nezha-agent --no-pager || sudo systemctl status nezha-agent.service --no-pager
sudo systemctl status x-ui --no-pager
sudo cat /root/independent-ip-node.txt
sudo cat /root/independent-ip-clash.yaml
```

## 卸载

x-ui 可运行 `x-ui uninstall`。Nezha Agent 的服务名和安装位置由官方安装器决定；卸载前先查看对应 systemd unit，并保留 `/root/independent-ip-node.txt` 作为节点记录。

## 上游来源

- Nezha Agent 安装器：<https://github.com/nezhahq/scripts/blob/main/agent/install.sh>
- x-ui：<https://github.com/vaxilu/x-ui>（固定 release `0.3.2`）
