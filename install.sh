#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

readonly XUI_VERSION='0.3.2'
readonly XUI_USERNAME='wochiniming'
readonly XUI_PASSWORD='wochiniming'
readonly XUI_PANEL_PORT='18181'
readonly DEFAULT_SS_PORT='80'
readonly SS_METHOD='aes-256-gcm'
readonly SS_REMARK='independent-ip'
readonly XUI_INSTALL_URL='https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh'

WORK_DIR=''
SS_PORT="$DEFAULT_SS_PORT"

log() {
  printf '[installer] %s\n' "$*"
}

warn() {
  printf '[installer] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[installer] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf -- "${WORK_DIR}"
  fi
}

trap cleanup EXIT

require_root_linux_systemd() {
  [[ "$(id -u)" -eq 0 ]] || die '请切换到 root 后重新执行一键命令'
  [[ "$(uname -s)" == 'Linux' ]] || die '仅支持 Linux'
  command -v systemctl >/dev/null 2>&1 || die '系统没有 systemd/systemctl，无法安装 x-ui 服务'

  case "$(uname -m)" in
    x86_64 | amd64 | aarch64 | arm64 | armv7l | armv7) ;;
    *) die "vaxilu/x-ui 0.3.2 不支持当前架构：$(uname -m)" ;;
  esac
}

prompt_yes_no() {
  local prompt="$1"
  local default_answer="$2"
  local answer

  while true; do
    if [[ "$default_answer" == 'yes' ]]; then
      read -r -p "$prompt [Y/n]: " answer || die '无法读取交互输入'
      answer="${answer:-y}"
    else
      read -r -p "$prompt [y/N]: " answer || die '无法读取交互输入'
      answer="${answer:-n}"
    fi
    case "$answer" in
      y | Y | yes | YES | Yes) return 0 ;;
      n | N | no | NO | No) return 1 ;;
      *) printf '请输入 y 或 n。\n' ;;
    esac
  done
}

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535))
}

collect_choices() {
  local custom_port

  printf '\nLinux x-ui + Shadowsocks 一键安装\n'
  printf '%s\n' '--------------------------------------------------'

  if prompt_yes_no 'Shadowsocks 是否使用默认端口 80？' 'yes'; then
    SS_PORT="$DEFAULT_SS_PORT"
  else
    while true; do
      read -r -p '请输入 Shadowsocks 端口（1-65535，不能是 18181）: ' custom_port || die '无法读取端口'
      if ! is_valid_port "$custom_port"; then
        printf '端口必须是 1-65535 的整数。\n'
      elif [[ "$custom_port" == "$XUI_PANEL_PORT" ]]; then
        printf '端口不能与 x-ui 面板端口 %s 相同。\n' "$XUI_PANEL_PORT"
      else
        SS_PORT="$custom_port"
        break
      fi
    done
  fi

  printf '选择完成：x-ui 面板端口=%s，Shadowsocks 协议=%s，端口=%s\n\n' \
    "$XUI_PANEL_PORT" "$SS_METHOD" "$SS_PORT"
}

install_package() {
  local package="$1"

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$package"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$package"
  else
    die "未识别包管理器，无法安装 $package；支持 apt-get、dnf、yum"
  fi
}

ensure_unzip_first() {
  if command -v unzip >/dev/null 2>&1; then
    log "unzip 已安装：$(command -v unzip)"
  else
    log '未检测到 unzip，开始安装'
    install_package unzip
    command -v unzip >/dev/null 2>&1 || die 'unzip 安装失败'
  fi
}

ensure_runtime_tools() {
  local tool
  for tool in curl wget tar base64 od awk grep sed tr; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      case "$tool" in
        curl) install_package curl ;;
        wget) install_package wget ;;
        tar) install_package tar ;;
        *) die "系统缺少必需命令：$tool" ;;
      esac
    fi
  done
}

port_in_use() {
  local port="$1"
  local hex_port
  local table

  hex_port=$(printf '%04X' "$port")
  for table in /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6; do
    [[ -r "$table" ]] || continue
    if awk -v suffix=":${hex_port}" 'NR > 1 && substr($2, length($2) - 4) == suffix { found=1 } END { exit !found }' "$table"; then
      return 0
    fi
  done
  return 1
}

preflight_ports_and_existing_install() {
  if [[ -x /usr/local/x-ui/x-ui ]]; then
    die '检测到已有 x-ui。为避免覆盖现有节点，本脚本不会重装；请先备份并卸载旧实例后再运行。'
  fi

  port_in_use "$XUI_PANEL_PORT" && die "本机端口 $XUI_PANEL_PORT 已被占用，不能作为 x-ui 面板端口"
  port_in_use "$SS_PORT" && die "本机端口 $SS_PORT 已被占用，不能创建 Shadowsocks 节点"
}

validate_inputs() {
  PUBLIC_HOST="${PUBLIC_HOST:-}"
  SS_PASSWORD="${SS_PASSWORD:-}"

  if [[ -n "$PUBLIC_HOST" ]] && ! is_ipv4 "$PUBLIC_HOST"; then
    die 'PUBLIC_HOST 必须是有效的公网 IPv4 地址'
  fi

  if [[ -n "$SS_PASSWORD" ]]; then
    [[ "$SS_PASSWORD" != *$'\n'* && "$SS_PASSWORD" != *':'* && "$SS_PASSWORD" != *'@'* ]] || \
      die 'SS_PASSWORD 不能包含换行、冒号或 @'
  else
    SS_PASSWORD=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  fi
}

download_file() {
  local url="$1"
  local destination="$2"

  curl --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 --connect-timeout 20 \
    "$url" -o "$destination"
  [[ -s "$destination" ]] || die "下载结果为空：$url"
}

install_xui() {
  local script="$WORK_DIR/x-ui-install.sh"

  log "安装 vaxilu/x-ui $XUI_VERSION"
  download_file "$XUI_INSTALL_URL" "$script"
  chmod 700 "$script"

  printf 'y\n%s\n%s\n%s\n' "$XUI_USERNAME" "$XUI_PASSWORD" "$XUI_PANEL_PORT" | \
    bash "$script" "$XUI_VERSION"

  [[ -x /usr/local/x-ui/x-ui ]] || die 'x-ui 安装完成后未找到主程序'
  /usr/local/x-ui/x-ui setting -username "$XUI_USERNAME" -password "$XUI_PASSWORD"
  /usr/local/x-ui/x-ui setting -port "$XUI_PANEL_PORT"
  systemctl daemon-reload
  systemctl enable x-ui
  systemctl restart x-ui
  systemctl is-active --quiet x-ui || die 'x-ui 服务启动失败'
}

wait_for_panel() {
  for _ in $(seq 1 30); do
    if curl --fail --silent --output /dev/null "http://127.0.0.1:${XUI_PANEL_PORT}/"; then
      return 0
    fi
    sleep 1
  done
  die "x-ui 面板在 30 秒内没有监听 127.0.0.1:$XUI_PANEL_PORT"
}

create_shadowsocks_inbound() {
  local cookies="$WORK_DIR/x-ui.cookies"
  local login_response
  local list_response
  local add_response
  local settings
  local stream_settings
  local sniffing

  log "登录本机 x-ui 并创建 Shadowsocks :$SS_PORT 节点"
  login_response=$(curl --fail --show-error --silent \
    --cookie-jar "$cookies" \
    --header 'Content-Type: application/json' \
    --data "{\"username\":\"${XUI_USERNAME}\",\"password\":\"${XUI_PASSWORD}\"}" \
    "http://127.0.0.1:${XUI_PANEL_PORT}/login")
  grep -Eq '"success"[[:space:]]*:[[:space:]]*true' <<<"$login_response" || die 'x-ui 本机登录失败'

  list_response=$(curl --fail --show-error --silent --cookie "$cookies" \
    --request POST "http://127.0.0.1:${XUI_PANEL_PORT}/xui/inbound/list")
  if grep -Eq "\"port\"[[:space:]]*:[[:space:]]*${SS_PORT}([,}])" <<<"$list_response"; then
    die "x-ui 中已经存在端口 $SS_PORT 的入站，拒绝覆盖"
  fi

  settings=$(printf '{"method":"%s","password":"%s","network":"tcp,udp"}' "$SS_METHOD" "$SS_PASSWORD")
  stream_settings='{"network":"tcp","security":"none","tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}'
  sniffing='{"enabled":true,"destOverride":["http","tls"]}'

  add_response=$(curl --fail --show-error --silent --cookie "$cookies" \
    --request POST "http://127.0.0.1:${XUI_PANEL_PORT}/xui/inbound/add" \
    --data-urlencode 'up=0' \
    --data-urlencode 'down=0' \
    --data-urlencode 'total=0' \
    --data-urlencode "remark=$SS_REMARK" \
    --data-urlencode 'enable=true' \
    --data-urlencode 'expiryTime=0' \
    --data-urlencode 'listen=' \
    --data-urlencode "port=$SS_PORT" \
    --data-urlencode 'protocol=shadowsocks' \
    --data-urlencode "settings=$settings" \
    --data-urlencode "streamSettings=$stream_settings" \
    --data-urlencode "sniffing=$sniffing")
  grep -Eq '"success"[[:space:]]*:[[:space:]]*true' <<<"$add_response" || die 'x-ui 创建 Shadowsocks 入站失败'

  systemctl restart x-ui
  systemctl is-active --quiet x-ui || die '创建节点后 x-ui 重启失败'

  for _ in $(seq 1 30); do
    port_in_use "$SS_PORT" && return 0
    sleep 1
  done
  die "Shadowsocks 入站在 30 秒内没有监听端口 $SS_PORT"
}

open_firewall_ports() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${XUI_PANEL_PORT}/tcp"
    ufw allow "${SS_PORT}/tcp"
    ufw allow "${SS_PORT}/udp"
    log '已更新 UFW 规则'
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${XUI_PANEL_PORT}/tcp"
    firewall-cmd --permanent --add-port="${SS_PORT}/tcp"
    firewall-cmd --permanent --add-port="${SS_PORT}/udp"
    firewall-cmd --reload
    log '已更新 firewalld 规则'
  else
    warn "未检测到启用中的 UFW/firewalld；请在云安全组和主机防火墙放行 ${XUI_PANEL_PORT}/tcp、${SS_PORT}/tcp、${SS_PORT}/udp"
  fi
}

is_ipv4() {
  local value="$1"
  local octet
  local -a octets
  local old_ifs="$IFS"

  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$value"
  IFS="$old_ifs"
  for octet in "${octets[@]}"; do
    ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
  done
}

detect_public_host() {
  local endpoint
  local candidate

  if [[ -n "$PUBLIC_HOST" ]]; then
    printf '%s' "$PUBLIC_HOST"
    return 0
  fi

  for endpoint in 'https://api.ipify.org' 'https://ipv4.icanhazip.com' 'https://ifconfig.me/ip'; do
    candidate=$(curl -4 --fail --show-error --silent --location --connect-timeout 10 "$endpoint" 2>/dev/null | tr -d '[:space:]') || true
    if is_ipv4 "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

build_ss_uri() {
  local host="$1"
  local password="$2"
  local remark="${3:-$SS_REMARK}"
  local encoded

  encoded=$(printf '%s:%s@%s:%s' "$SS_METHOD" "$password" "$host" "$SS_PORT" | \
    base64 | tr -d '\n=' | tr '+/' '-_')
  printf 'ss://%s#%s' "$encoded" "$remark"
}

write_connection_files() {
  local public_host
  local ss_uri
  local summary='/root/independent-ip-node.txt'
  local clash_yaml='/root/independent-ip-clash.yaml'

  public_host=$(detect_public_host) || die '无法检测公网 IPv4；重新运行时设置 PUBLIC_HOST=你的公网IP'
  ss_uri=$(build_ss_uri "$public_host" "$SS_PASSWORD")

  {
    printf 'x-ui panel: http://%s:%s\n' "$public_host" "$XUI_PANEL_PORT"
    printf 'x-ui username: %s\n' "$XUI_USERNAME"
    printf 'x-ui password: %s\n' "$XUI_PASSWORD"
    printf 'Shadowsocks URI: %s\n' "$ss_uri"
  } >"$summary"

  {
    printf -- '- name: independent-ip\n'
    printf '  type: ss\n'
    printf '  server: %s\n' "$public_host"
    printf '  port: %s\n' "$SS_PORT"
    printf '  cipher: %s\n' "$SS_METHOD"
    printf '  password: "%s"\n' "$SS_PASSWORD"
    printf '  udp: true\n'
  } >"$clash_yaml"

  chmod 600 "$summary" "$clash_yaml"

  printf '\n安装完成。\n'
  printf 'x-ui 面板: http://%s:%s\n' "$public_host" "$XUI_PANEL_PORT"
  printf 'x-ui 账号/密码: %s / %s\n' "$XUI_USERNAME" "$XUI_PASSWORD"
  printf '路由器可导入 SS 链接:\n%s\n' "$ss_uri"
  printf 'Clash/OpenClash 节点 YAML: %s\n' "$clash_yaml"
  printf '完整结果: %s\n' "$summary"
}

main() {
  require_root_linux_systemd
  collect_choices
  validate_inputs
  ensure_unzip_first
  ensure_runtime_tools
  preflight_ports_and_existing_install

  WORK_DIR=$(mktemp -d /tmp/linux-xui-ss.XXXXXX)
  install_xui
  wait_for_panel
  create_shadowsocks_inbound
  open_firewall_ports
  write_connection_files
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
