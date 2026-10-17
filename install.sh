#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly XUI_VERSION='0.3.2'
DEFAULT_XUI_USERNAME='wochiniming'
DEFAULT_XUI_PASSWORD='wochiniming'
DEFAULT_XUI_PANEL_PORT='18181'
readonly DEFAULT_SS_PORT='80'
DEFAULT_SS_METHOD='aes-256-gcm'
readonly SS_REMARK='independent-ip'
readonly XUI_INSTALL_URL='https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh'

WORK_DIR=''
XUI_USERNAME="$DEFAULT_XUI_USERNAME"
XUI_PASSWORD="$DEFAULT_XUI_PASSWORD"
XUI_PANEL_PORT="$DEFAULT_XUI_PANEL_PORT"
SS_PORT="$DEFAULT_SS_PORT"
SS_METHOD="$DEFAULT_SS_METHOD"
PUBLIC_HOST="${PUBLIC_HOST:-}"
SS_PASSWORD="${SS_PASSWORD:-}"

log() { printf '[installer] %s\n' "$*"; }
warn() { printf '[installer] WARNING: %s\n' "$*" >&2; }
die() { printf '[installer] ERROR: %s\n' "$*" >&2; exit 1; }
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

usage() {
  cat <<'EOF'
Linux x-ui + Shadowsocks 无交互安装

不带参数：使用默认账号/密码、面板端口 18181、SS 端口 80 和 aes-256-gcm。
用法：bash install.sh [选项]
  --username NAME       x-ui 登录账号（默认 wochiniming）
  --password PASS       x-ui 登录密码（默认 wochiniming）
  --panel-port PORT     x-ui 面板端口（默认 18181）
  --ss-port PORT        Shadowsocks 端口（默认 80）
  --ss-method METHOD    Shadowsocks 加密方法（默认 aes-256-gcm）
  --ss-password PASS    Shadowsocks 密码（默认随机生成）
  --public-host IPV4    公网 IPv4（默认自动检测）
  -h, --help            显示帮助

推荐远程运行（可传参）：
  curl -fsSL https://raw.githubusercontent.com/abxian/linux-nezha-xui-installer/main/install.sh | sudo bash -s -- --username admin --password 'CHANGE_ME' --panel-port 18181 --ss-port 80 --ss-method aes-256-gcm
EOF
}

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( ${#port} <= 5 )) || return 1
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}

parse_args() {
  while (($#)); do
    case "$1" in
      --username|--password|--panel-port|--ss-port|--ss-method|--ss-password|--public-host)
        (($# >= 2)) || die "缺少参数值：$1"
        case "$1" in
          --username) XUI_USERNAME="$2" ;;
          --password) XUI_PASSWORD="$2" ;;
          --panel-port) XUI_PANEL_PORT="$2" ;;
          --ss-port) SS_PORT="$2" ;;
          --ss-method) SS_METHOD="$2" ;;
          --ss-password) SS_PASSWORD="$2" ;;
          --public-host) PUBLIC_HOST="$2" ;;
        esac
        shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1（使用 --help 查看说明）" ;;
    esac
  done
}

show_config() {
  printf '\nLinux x-ui + Shadowsocks 无交互安装\n'
  printf '%s\n' '--------------------------------------------------'
  printf 'x-ui 账号=%s，面板端口=%s，Shadowsocks 加密=%s，端口=%s\n\n' \
    "$XUI_USERNAME" "$XUI_PANEL_PORT" "$SS_METHOD" "$SS_PORT"
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
  local port="$1" hex_port table
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
  if port_in_use "$XUI_PANEL_PORT"; then
    die "本机端口 $XUI_PANEL_PORT 已被占用，不能作为 x-ui 面板端口"
  fi
  if port_in_use "$SS_PORT"; then
    die "本机端口 $SS_PORT 已被占用，不能创建 Shadowsocks 节点"
  fi
  return 0
}

validate_inputs() {
  is_valid_port "$XUI_PANEL_PORT" || die '面板端口必须是 1-65535 的整数'
  is_valid_port "$SS_PORT" || die 'SS 端口必须是 1-65535 的整数'
  [[ "$XUI_PANEL_PORT" != "$SS_PORT" ]] || die '面板端口与 SS 端口不能相同'
  # x-ui installer及API需要安全传递；限制登录凭据字符，避免注入和JSON破坏。
  [[ "$XUI_USERNAME" =~ ^[a-zA-Z0-9_.@-]{1,64}$ ]] || die '账号仅支持 1-64 位英文字母、数字、_ . @ -'
  [[ "$XUI_PASSWORD" =~ ^[a-zA-Z0-9_.@!%+=:-]{1,128}$ ]] || die '面板密码仅支持 1-128 位字母、数字和 _.@!%+=:-'
  case "$SS_METHOD" in
    aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305) ;;
    *) die 'SS 加密方法仅支持 aes-128-gcm、aes-256-gcm、chacha20-ietf-poly1305' ;;
  esac
  if [[ -n "$PUBLIC_HOST" ]] && ! is_ipv4 "$PUBLIC_HOST"; then
    die '公网地址必须是有效 IPv4'
  fi
  if [[ -n "$SS_PASSWORD" ]]; then
    [[ "$SS_PASSWORD" =~ ^[a-zA-Z0-9_.@!%+=:-]{1,128}$ ]] || die 'SS 密码仅支持 1-128 位字母、数字和 _.@!%+=:-'
  else
    SS_PASSWORD=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  fi
}

download_file() {
  local url="$1" destination="$2"
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
  local attempt
  for attempt in $(seq 1 30); do
    if curl --fail --silent --output /dev/null "http://127.0.0.1:${XUI_PANEL_PORT}/"; then
      return 0
    fi
    sleep 1
  done
  die "x-ui 面板在 30 秒内没有监听 127.0.0.1:$XUI_PANEL_PORT"
}

create_shadowsocks_inbound() {
  local cookies="$WORK_DIR/x-ui.cookies"
  local login_response list_response add_response settings stream_settings sniffing
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
  local attempt
  for attempt in $(seq 1 30); do
    if port_in_use "$SS_PORT"; then return 0; fi
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
  local value="$1" octet
  local -a octets
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$value"
  for octet in "${octets[@]}"; do
    ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
  done
  return 0
}

detect_public_host() {
  local endpoint candidate
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
  local host="$1" password="$2" remark="${3:-$SS_REMARK}" encoded
  encoded=$(printf '%s:%s@%s:%s' "$SS_METHOD" "$password" "$host" "$SS_PORT" | \
    base64 | tr -d '\n=' | tr '+/' '-_')
  printf 'ss://%s#%s' "$encoded" "$remark"
}

write_connection_files() {
  local public_host ss_uri
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
  parse_args "$@"
  require_root_linux_systemd
  validate_inputs
  show_config
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

# Compatible with both `bash install.sh` and `bash -c "$(curl ...)"`.
main "$@"
