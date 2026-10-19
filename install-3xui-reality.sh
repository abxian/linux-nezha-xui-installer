#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEFAULT_XUI_USERNAME='wochiniming'
DEFAULT_XUI_PASSWORD='wochiniming'
DEFAULT_XUI_PANEL_PORT='18181'
DEFAULT_XUI_WEB_PATH='reality'
readonly DEFAULT_REALITY_PORT='443'
DEFAULT_REALITY_SNI='www.cloudflare.com'
readonly REALITY_REMARK='independent-ip-reality'
readonly XUI_INSTALL_URL='https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh'

WORK_DIR=''
XUI_USERNAME="$DEFAULT_XUI_USERNAME"
XUI_PASSWORD="$DEFAULT_XUI_PASSWORD"
XUI_PANEL_PORT="$DEFAULT_XUI_PANEL_PORT"
XUI_WEB_PATH="$DEFAULT_XUI_WEB_PATH"
REALITY_PORT="$DEFAULT_REALITY_PORT"
REALITY_SNI="$DEFAULT_REALITY_SNI"
PUBLIC_HOST="${PUBLIC_HOST:-}"
CLIENT_UUID=''
REALITY_PRIVATE_KEY=''
REALITY_PUBLIC_KEY=''
REALITY_SHORT_ID=''

log() { printf '[3x-ui installer] %s\n' "$*"; }
warn() { printf '[3x-ui installer] WARNING: %s\n' "$*" >&2; }
die() { printf '[3x-ui installer] ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Linux 3x-ui + VLESS REALITY 无交互安装

不带参数：面板账号/密码 wochiniming、面板端口 18181、REALITY 端口 443。
用法：bash install-3xui-reality.sh [选项]
  --username NAME       3x-ui 登录账号（默认 wochiniming）
  --password PASS       3x-ui 登录密码（默认 wochiniming）
  --panel-port PORT     3x-ui 面板端口（默认 18181）
  --reality-port PORT   VLESS REALITY 端口（默认 443）
  --reality-sni DOMAIN  REALITY SNI/目标站点（默认 www.cloudflare.com）
  --public-host IPV4    公网 IPv4（默认自动检测）
  -h, --help            显示帮助
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --username|--password|--panel-port|--reality-port|--reality-sni|--public-host)
        (($# >= 2)) || die "缺少参数值：$1"
        case "$1" in
          --username) XUI_USERNAME="$2" ;;
          --password) XUI_PASSWORD="$2" ;;
          --panel-port) XUI_PANEL_PORT="$2" ;;
          --reality-port) REALITY_PORT="$2" ;;
          --reality-sni) REALITY_SNI="$2" ;;
          --public-host) PUBLIC_HOST="$2" ;;
        esac
        shift 2
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1（使用 --help 查看说明）" ;;
    esac
  done
}

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( ${#port} <= 5 )) || return 1
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}

is_ipv4() {
  local value="$1" octet
  local -a octets
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$value"
  for octet in "${octets[@]}"; do
    ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
  done
}

is_valid_domain() {
  local value="$1"
  [[ ${#value} -le 253 ]] || return 1
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

validate_inputs() {
  is_valid_port "$XUI_PANEL_PORT" || die '面板端口必须是 1-65535 的整数'
  is_valid_port "$REALITY_PORT" || die 'REALITY 端口必须是 1-65535 的整数'
  [[ "$XUI_PANEL_PORT" != "$REALITY_PORT" ]] || die '面板端口与 REALITY 端口不能相同'
  [[ "$XUI_USERNAME" =~ ^[a-zA-Z0-9_.@-]{1,64}$ ]] || die '账号仅支持 1-64 位英文字母、数字、_ . @ -'
  [[ "$XUI_PASSWORD" =~ ^[a-zA-Z0-9_.@!%+=:-]{1,128}$ ]] || die '面板密码仅支持 1-128 位字母、数字和 _.@!%+=:-'
  [[ "$XUI_WEB_PATH" =~ ^[a-zA-Z0-9_-]{4,64}$ ]] || die '面板路径格式无效'
  is_valid_domain "$REALITY_SNI" || die 'REALITY SNI 必须是有效域名'
  if [[ -n "$PUBLIC_HOST" ]]; then
    is_ipv4 "$PUBLIC_HOST" || die '公网地址必须是有效 IPv4'
  fi
}

require_root_linux_systemd() {
  [[ "$(id -u)" -eq 0 ]] || die '请切换到 root 后重新执行一键命令'
  [[ "$(uname -s)" == 'Linux' ]] || die '仅支持 Linux'
  command -v systemctl >/dev/null 2>&1 || die '系统没有 systemd/systemctl，无法安装 3x-ui 服务'
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

ensure_runtime_tools() {
  local tool
  for tool in curl awk grep sed tr od ss; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      case "$tool" in
        curl) install_package curl ;;
        ss)
          if command -v apt-get >/dev/null 2>&1; then
            install_package iproute2
          else
            install_package iproute
          fi
          ;;
        *) die "系统缺少必需命令：$tool" ;;
      esac
      command -v "$tool" >/dev/null 2>&1 || die "安装依赖后仍缺少命令：$tool"
    fi
  done
}

port_in_use() {
  local port="$1"
  ss -H -ltn | awk -v port="$port" '
    $4 ~ (":" port "$") { found=1; exit }
    END { exit !found }
  '
}

preflight() {
  if [[ -x /usr/local/x-ui/x-ui ]] || [[ -e /etc/x-ui/x-ui.db ]] || \
     [[ -e /etc/systemd/system/x-ui.service ]] || command -v x-ui >/dev/null 2>&1; then
    die '检测到已有 x-ui/3x-ui。两者共用安装路径；为避免覆盖现有节点，本脚本拒绝继续。'
  fi
  port_in_use "$XUI_PANEL_PORT" && die "本机端口 $XUI_PANEL_PORT 已被占用，不能作为 3x-ui 面板端口"
  port_in_use "$REALITY_PORT" && die "本机端口 $REALITY_PORT 已被占用，不能创建 REALITY 节点"
  return 0
}

download_file() {
  local url="$1" destination="$2"
  curl --fail --show-error --silent --location \
    --retry 3 --retry-delay 2 --connect-timeout 20 \
    "$url" -o "$destination"
  [[ -s "$destination" ]] || die "下载结果为空：$url"
}

install_3xui() {
  local script="$WORK_DIR/3x-ui-install.sh"
  log '通过 MHSanaei/3x-ui 官方安装器安装最新稳定版'
  download_file "$XUI_INSTALL_URL" "$script"
  chmod 700 "$script"
  env \
    XUI_NONINTERACTIVE=1 \
    XUI_USERNAME="$XUI_USERNAME" \
    XUI_PASSWORD="$XUI_PASSWORD" \
    XUI_PANEL_PORT="$XUI_PANEL_PORT" \
    XUI_WEB_BASE_PATH="$XUI_WEB_PATH" \
    XUI_SSL_MODE=none \
    XUI_DB_TYPE=sqlite \
    XUI_ENABLE_FAIL2BAN=false \
    bash "$script"
  [[ -x /usr/local/x-ui/x-ui ]] || die '3x-ui 安装完成后未找到主程序'
  systemctl daemon-reload
  systemctl enable x-ui
  systemctl restart x-ui
  systemctl is-active --quiet x-ui || die '3x-ui 服务启动失败'
}

panel_base_url() {
  printf 'http://127.0.0.1:%s/%s' "$XUI_PANEL_PORT" "$XUI_WEB_PATH"
}

wait_for_panel() {
  local attempt base
  base=$(panel_base_url)
  for ((attempt = 1; attempt <= 45; attempt++)); do
    if curl --silent --output /dev/null --max-time 2 "$base/"; then
      return 0
    fi
    sleep 1
  done
  die "3x-ui 面板在 45 秒内没有响应：$base/"
}

json_success() {
  grep -Eq '"success"[[:space:]]*:[[:space:]]*true' <<<"$1"
}

json_string_field() {
  local json="$1" field="$2"
  sed -nE "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\\1/p" <<<"$json" | head -n1
}

generate_client_values() {
  CLIENT_UUID=$(tr '[:upper:]' '[:lower:]' </proc/sys/kernel/random/uuid)
  REALITY_SHORT_ID=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  [[ "$CLIENT_UUID" =~ ^[0-9a-f-]{36}$ ]] || die '生成 VLESS UUID 失败'
  [[ "$REALITY_SHORT_ID" =~ ^[0-9a-f]{16}$ ]] || die '生成 REALITY short ID 失败'
}

create_reality_inbound() {
  local base cookies login_response list_response key_response add_response payload target
  base=$(panel_base_url)
  cookies="$WORK_DIR/3x-ui.cookies"
  target="${REALITY_SNI}:443"
  log "登录本机 3x-ui 并创建 VLESS + REALITY :$REALITY_PORT 入站"
  login_response=$(curl --fail --show-error --silent \
    --cookie-jar "$cookies" \
    --header 'Content-Type: application/json' \
    --data "{\"username\":\"${XUI_USERNAME}\",\"password\":\"${XUI_PASSWORD}\"}" \
    "$base/login")
  json_success "$login_response" || die '3x-ui 本机登录失败'

  list_response=$(curl --fail --show-error --silent --cookie "$cookies" \
    "$base/panel/api/inbounds/list")
  json_success "$list_response" || die '3x-ui 入站列表读取失败'
  if grep -Eq "\"port\"[[:space:]]*:[[:space:]]*${REALITY_PORT}([,}])" <<<"$list_response"; then
    die "3x-ui 中已经存在端口 $REALITY_PORT 的入站，拒绝覆盖"
  fi

  key_response=$(curl --fail --show-error --silent --cookie "$cookies" \
    "$base/panel/api/server/getNewX25519Cert")
  json_success "$key_response" || die '3x-ui 生成 REALITY X25519 密钥失败'
  REALITY_PRIVATE_KEY=$(json_string_field "$key_response" 'privateKey')
  REALITY_PUBLIC_KEY=$(json_string_field "$key_response" 'publicKey')
  [[ "$REALITY_PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || die '3x-ui 返回的 REALITY 私钥格式无效'
  [[ "$REALITY_PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || die '3x-ui 返回的 REALITY 公钥格式无效'

  payload=$(printf '{"up":0,"down":0,"total":0,"remark":"%s","enable":true,"expiryTime":0,"listen":"","port":%s,"protocol":"vless","settings":{"clients":[{"id":"%s","flow":"xtls-rprx-vision","email":"reality","limitIp":0,"totalGB":0,"expiryTime":0,"enable":true,"tgId":0,"subId":"%s","comment":"","reset":0}],"decryption":"none","encryption":"none","fallbacks":[]},"streamSettings":{"network":"tcp","security":"reality","tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}},"realitySettings":{"show":false,"xver":0,"target":"%s","serverNames":["%s"],"privateKey":"%s","minClientVer":"","maxClientVer":"","maxTimediff":0,"shortIds":["%s"],"mldsa65Seed":"","settings":{"publicKey":"%s","fingerprint":"chrome","serverName":"","spiderX":"/","mldsa65Verify":""}}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false,"ipsExcluded":[],"domainsExcluded":[]}}' \
    "$REALITY_REMARK" "$REALITY_PORT" "$CLIENT_UUID" "$REALITY_SHORT_ID" \
    "$target" "$REALITY_SNI" "$REALITY_PRIVATE_KEY" "$REALITY_SHORT_ID" "$REALITY_PUBLIC_KEY")
  add_response=$(curl --fail --show-error --silent --cookie "$cookies" \
    --header 'Content-Type: application/json' \
    --data "$payload" \
    "$base/panel/api/inbounds/add")
  json_success "$add_response" || die "3x-ui 创建 REALITY 入站失败：$add_response"

  systemctl is-active --quiet x-ui || die '创建节点后 3x-ui 服务异常'
  local attempt
  for ((attempt = 1; attempt <= 30; attempt++)); do
    if port_in_use "$REALITY_PORT"; then return 0; fi
    sleep 1
  done
  die "REALITY 入站在 30 秒内没有监听端口 $REALITY_PORT"
}

open_firewall_ports() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${XUI_PANEL_PORT}/tcp"
    ufw allow "${REALITY_PORT}/tcp"
    log '已更新 UFW 规则'
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${XUI_PANEL_PORT}/tcp"
    firewall-cmd --permanent --add-port="${REALITY_PORT}/tcp"
    firewall-cmd --reload
    log '已更新 firewalld 规则'
  else
    warn "未检测到启用中的 UFW/firewalld；请在云安全组和主机防火墙放行 ${XUI_PANEL_PORT}/tcp、${REALITY_PORT}/tcp"
  fi
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

build_vless_uri() {
  local host="$1" uuid="$2" public_key="$3" short_id="$4"
  printf 'vless://%s@%s:%s?type=tcp&security=reality&pbk=%s&fp=chrome&sni=%s&sid=%s&spx=%%2F&flow=xtls-rprx-vision#%s' \
    "$uuid" "$host" "$REALITY_PORT" "$public_key" "$REALITY_SNI" "$short_id" "$REALITY_REMARK"
}

write_connection_files() {
  local public_host vless_uri
  local summary='/root/independent-ip-reality.txt'
  local clash_yaml='/root/independent-ip-reality.yaml'
  public_host=$(detect_public_host) || die '无法检测公网 IPv4；重新运行时使用 --public-host 指定公网 IP'
  vless_uri=$(build_vless_uri "$public_host" "$CLIENT_UUID" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID")
  {
    printf '3x-ui panel: http://%s:%s/%s/\n' "$public_host" "$XUI_PANEL_PORT" "$XUI_WEB_PATH"
    printf '3x-ui username: %s\n' "$XUI_USERNAME"
    printf '3x-ui password: %s\n' "$XUI_PASSWORD"
    printf 'VLESS REALITY URI: %s\n' "$vless_uri"
  } >"$summary"
  {
    printf -- '- name: %s\n' "$REALITY_REMARK"
    printf '  type: vless\n'
    printf '  server: %s\n' "$public_host"
    printf '  port: %s\n' "$REALITY_PORT"
    printf '  uuid: %s\n' "$CLIENT_UUID"
    printf '  network: tcp\n'
    printf '  tls: true\n'
    printf '  udp: true\n'
    printf '  flow: xtls-rprx-vision\n'
    printf '  servername: %s\n' "$REALITY_SNI"
    printf '  reality-opts:\n'
    printf '    public-key: %s\n' "$REALITY_PUBLIC_KEY"
    printf '    short-id: %s\n' "$REALITY_SHORT_ID"
    printf '  client-fingerprint: chrome\n'
  } >"$clash_yaml"
  chmod 600 "$summary" "$clash_yaml"

  printf '\n安装完成。\n'
  printf '3x-ui 面板: http://%s:%s/%s/\n' "$public_host" "$XUI_PANEL_PORT" "$XUI_WEB_PATH"
  printf '3x-ui 账号/密码: %s / %s\n' "$XUI_USERNAME" "$XUI_PASSWORD"
  printf '路由器可导入 VLESS REALITY 链接:\n%s\n' "$vless_uri"
  printf 'Mihomo/OpenClash 节点 YAML: %s\n' "$clash_yaml"
  printf '完整结果: %s\n' "$summary"
}

show_config() {
  printf '\nLinux 3x-ui + VLESS REALITY 无交互安装\n'
  printf '%s\n' '--------------------------------------------------'
  printf '3x-ui 账号=%s，面板端口=%s，REALITY SNI=%s，节点端口=%s\n\n' \
    "$XUI_USERNAME" "$XUI_PANEL_PORT" "$REALITY_SNI" "$REALITY_PORT"
}

main() {
  parse_args "$@"
  require_root_linux_systemd
  validate_inputs
  show_config
  ensure_runtime_tools
  preflight
  WORK_DIR=$(mktemp -d /tmp/linux-3xui-reality.XXXXXX)
  generate_client_values
  install_3xui
  wait_for_panel
  create_reality_inbound
  open_firewall_ports
  write_connection_files
}

# 直接执行、bash -c 和 curl | bash 都进入 main；测试 source 时显式设置为 1。
if [[ "${THREEXUI_INSTALLER_SOURCE_ONLY:-0}" != '1' ]]; then
  main "$@"
fi
