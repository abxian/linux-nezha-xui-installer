#!/usr/bin/env bash
# BUILD: MULTIIP-REALITY-ORIGIN-20261020-R1
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
readonly XUI_INSTALL_RESULT_FILE='/etc/x-ui/install-result.env'

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
RESUME_EXISTING=0
API_COOKIES=''
API_CSRF_TOKEN=''
SELF_TEST_PID=''
DIAGNOSTIC_LOG='/root/3x-ui-reality-diagnostic.log'
declare -a PUBLIC_IPS=()

log() { printf '[3x-ui installer] %s\n' "$*"; }
warn() { printf '[3x-ui installer] WARNING: %s\n' "$*" >&2; }
die() { printf '[3x-ui installer] ERROR: %s\n' "$*" >&2; exit 1; }
write_diagnostic_report() {
  {
    echo '=== 3x-ui / REALITY diagnostic (credentials and links omitted) ==='
    date -Is
    echo '-- service --'
    systemctl is-active x-ui 2>/dev/null || true
    echo '-- core version --'
    local core
    core=$(xray_binary 2>/dev/null || true)
    [[ -z "$core" ]] || "$core" version 2>&1 | head -n 3 || true
    echo '-- listeners --'
    ss -H -lntup 2>/dev/null | awk -v panel=":${XUI_PANEL_PORT}" -v reality=":${REALITY_PORT}" \
      '$5 ~ (panel "$") || $5 ~ (reality "$") {print $1, $5}' || true
    echo '-- detected public IPv4 --'
    printf '%s\n' "${PUBLIC_IPS[@]:-none}"
    echo '-- recent x-ui log (secrets and share links filtered) --'
    journalctl -u x-ui -n 50 --no-pager -o cat 2>/dev/null | \
      sed -E 's#(vless|vmess|trojan|ss)://[^ ]+#[SHARE-LINK-REDACTED]#g;s/(password|passwd|token|secret)[=:][^ ,]+/\1=[REDACTED]/Ig' || true
  } >"$DIAGNOSTIC_LOG"
  chmod 600 "$DIAGNOSTIC_LOG" 2>/dev/null || true
}

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$SELF_TEST_PID" ]]; then
    kill "$SELF_TEST_PID" >/dev/null 2>&1 || true
    wait "$SELF_TEST_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
  if ((status != 0)); then
    write_diagnostic_report || true
    warn "诊断日志已保存：$DIAGNOSTIC_LOG"
  fi
  exit "$status"
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
  --public-host IPV4    只生成指定的本机公网 IPv4（默认检测并生成全部公网 IP）
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
  for tool in curl awk grep sed tr od ss ip jq; do
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
        ip)
          if command -v apt-get >/dev/null 2>&1; then
            install_package iproute2
          else
            install_package iproute
          fi
          ;;
        jq) install_package jq ;;
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
  if existing_xui_install_detected; then
    if install_result_is_safe && install_result_values_match "$XUI_INSTALL_RESULT_FILE"; then
      RESUME_EXISTING=1
      log '检测到本脚本上次未完成的同配置 3x-ui 安装，将跳过重装并继续创建 REALITY 节点'
    else
      die '检测到已有 x-ui/3x-ui，但无法确认是完全相同配置的中断安装；为避免覆盖现有节点，本脚本拒绝继续。'
    fi
  elif port_in_use "$XUI_PANEL_PORT"; then
    die "本机端口 $XUI_PANEL_PORT 已被占用，不能作为 3x-ui 面板端口"
  fi
  if [[ "$RESUME_EXISTING" != '1' ]] && port_in_use "$REALITY_PORT"; then
    die "本机端口 $REALITY_PORT 已被占用，不能创建 REALITY 节点"
  fi
  return 0
}

existing_xui_install_detected() {
  [[ -x /usr/local/x-ui/x-ui ]] || [[ -e /etc/x-ui/x-ui.db ]] || \
    [[ -e /etc/systemd/system/x-ui.service ]] || command -v x-ui >/dev/null 2>&1
}

install_result_is_safe() {
  local owner mode
  [[ -f "$XUI_INSTALL_RESULT_FILE" ]] || return 1
  owner=$(stat -c '%u' "$XUI_INSTALL_RESULT_FILE" 2>/dev/null) || return 1
  mode=$(stat -c '%a' "$XUI_INSTALL_RESULT_FILE" 2>/dev/null) || return 1
  [[ "$owner" == '0' && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 8#077) == 0 ))
}

install_result_values_match() (
  local file="$1"
  local expected_username="$XUI_USERNAME"
  local expected_password="$XUI_PASSWORD"
  local expected_port="$XUI_PANEL_PORT"
  local expected_path="$XUI_WEB_PATH"
  [[ -r "$file" ]] || return 1
  # This root-owned 0600 file is written by the official 3x-ui installer.
  # shellcheck disable=SC1090
  source "$file"
  [[ "${XUI_USERNAME:-}" == "$expected_username" ]] &&
    [[ "${XUI_PASSWORD:-}" == "$expected_password" ]] &&
    [[ "${XUI_PANEL_PORT:-}" == "$expected_port" ]] &&
    [[ "${XUI_WEB_BASE_PATH:-}" == "$expected_path" ]]
)

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
  jq -e '.success == true' >/dev/null 2>&1 <<<"$1"
}

json_string_field() {
  local json="$1" field="$2"
  jq -er --arg field "$field" '.obj[$field] // .[$field] | select(type == "string" and length > 0)' <<<"$json"
}

generate_client_values() {
  CLIENT_UUID=$(tr '[:upper:]' '[:lower:]' </proc/sys/kernel/random/uuid)
  REALITY_SHORT_ID=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  [[ "$CLIENT_UUID" =~ ^[0-9a-f-]{36}$ ]] || die '生成 VLESS UUID 失败'
  [[ "$REALITY_SHORT_ID" =~ ^[0-9a-f]{16}$ ]] || die '生成 REALITY short ID 失败'
}

panel_login() {
  local base csrf_response login_response
  base=$(panel_base_url)
  API_COOKIES="$WORK_DIR/3x-ui.cookies"
  csrf_response=$(curl --fail --show-error --silent \
    --cookie-jar "$API_COOKIES" \
    "$base/csrf-token")
  json_success "$csrf_response" || die '3x-ui CSRF 令牌获取失败'
  API_CSRF_TOKEN=$(jq -er '.obj | select(type == "string")' <<<"$csrf_response")
  [[ "$API_CSRF_TOKEN" =~ ^[A-Za-z0-9_-]{32,128}$ ]] || die '3x-ui 返回的 CSRF 令牌格式无效'
  login_response=$(curl --fail --show-error --silent \
    --cookie "$API_COOKIES" \
    --cookie-jar "$API_COOKIES" \
    --header 'Content-Type: application/json' \
    --header "X-CSRF-Token: $API_CSRF_TOKEN" \
    --data "$(jq -cn --arg username "$XUI_USERNAME" --arg password "$XUI_PASSWORD" '{username:$username,password:$password}')" \
    "$base/login")
  json_success "$login_response" || die '3x-ui 本机登录失败'
}

panel_inbounds() {
  curl --fail --show-error --silent --cookie "$API_COOKIES" \
    "$(panel_base_url)/panel/api/inbounds/list"
}

load_managed_reality_inbound() {
  local list_response port_count managed_count record
  list_response=$(panel_inbounds)
  json_success "$list_response" || die '3x-ui 入站列表读取失败'
  port_count=$(jq -r --argjson port "$REALITY_PORT" '[.obj[] | select(.port == $port)] | length' <<<"$list_response")
  managed_count=$(jq -r --argjson port "$REALITY_PORT" --arg remark "$REALITY_REMARK" \
    '[.obj[] | select(.port == $port and .remark == $remark)] | length' <<<"$list_response")
  if ((port_count == 0)); then
    return 1
  fi
  if ((port_count != 1 || managed_count != 1)); then
    die "3x-ui 中端口 $REALITY_PORT 已由非本脚本节点占用，拒绝覆盖"
  fi
  record=$(jq -c --argjson port "$REALITY_PORT" --arg remark "$REALITY_REMARK" '
    .obj[] | select(.port == $port and .remark == $remark) |
    .settings = (if (.settings | type) == "string" then (.settings | fromjson) else .settings end) |
    .streamSettings = (if (.streamSettings | type) == "string" then (.streamSettings | fromjson) else .streamSettings end)
  ' <<<"$list_response") || die '3x-ui 入站 JSON 字段解析失败'
  jq -e --arg sni "$REALITY_SNI" '
    .enable == true and .protocol == "vless" and
    (.streamSettings.security == "reality") and
    (.streamSettings.network == "tcp" or .streamSettings.network == "raw") and
    ((.streamSettings.realitySettings.target // .streamSettings.realitySettings.dest) == ($sni + ":443")) and
    (.streamSettings.realitySettings.serverNames | index($sni) != null) and
    (.settings.clients | length == 1) and
    (.settings.clients[0].enable == true) and
    (.settings.clients[0].flow == "xtls-rprx-vision")
  ' >/dev/null <<<"$record" || die '现有脚本节点配置与安全预期不一致，拒绝自动修改'
  CLIENT_UUID=$(jq -er '.settings.clients[0].id' <<<"$record")
  REALITY_PRIVATE_KEY=$(jq -er '.streamSettings.realitySettings.privateKey' <<<"$record")
  REALITY_PUBLIC_KEY=$(jq -er '.streamSettings.realitySettings.settings.publicKey' <<<"$record")
  REALITY_SHORT_ID=$(jq -er '.streamSettings.realitySettings.shortIds[0]' <<<"$record")
  [[ "$CLIENT_UUID" =~ ^[0-9a-f-]{36}$ ]] || die '现有节点 UUID 格式无效'
  [[ "$REALITY_PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || die '现有节点 REALITY 私钥格式无效'
  [[ "$REALITY_PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || die '现有节点 REALITY 公钥格式无效'
  [[ "$REALITY_SHORT_ID" =~ ^[0-9a-f]{2,16}$ && $((${#REALITY_SHORT_ID} % 2)) -eq 0 ]] || die '现有节点 short ID 格式无效'
  return 0
}

create_reality_inbound() {
  local base key_response add_response payload target
  base=$(panel_base_url)
  target="${REALITY_SNI}:443"
  log "登录本机 3x-ui 并检查 VLESS + REALITY :$REALITY_PORT 入站"
  panel_login

  if load_managed_reality_inbound; then
    [[ "$RESUME_EXISTING" == '1' ]] || die '发现同名 REALITY 节点，但不是安全续跑场景'
    log '已回读并复用本脚本创建的现有 REALITY 节点'
    return 0
  fi

  key_response=$(curl --fail --show-error --silent --cookie "$API_COOKIES" \
    "$base/panel/api/server/getNewX25519Cert")
  json_success "$key_response" || die '3x-ui 生成 REALITY X25519 密钥失败'
  REALITY_PRIVATE_KEY=$(json_string_field "$key_response" 'privateKey')
  REALITY_PUBLIC_KEY=$(json_string_field "$key_response" 'publicKey')
  [[ "$REALITY_PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || die '3x-ui 返回的 REALITY 私钥格式无效'
  [[ "$REALITY_PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || die '3x-ui 返回的 REALITY 公钥格式无效'

  payload=$(jq -cn \
    --arg remark "$REALITY_REMARK" --argjson port "$REALITY_PORT" --arg uuid "$CLIENT_UUID" \
    --arg subId "$REALITY_SHORT_ID" --arg target "$target" --arg sni "$REALITY_SNI" \
    --arg privateKey "$REALITY_PRIVATE_KEY" --arg publicKey "$REALITY_PUBLIC_KEY" --arg shortId "$REALITY_SHORT_ID" \
    '{up:0,down:0,total:0,remark:$remark,enable:true,expiryTime:0,listen:"",port:$port,protocol:"vless",settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision",email:"reality",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$subId,comment:"",reset:0}],decryption:"none",encryption:"none",fallbacks:[]},streamSettings:{network:"tcp",security:"reality",tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}},realitySettings:{show:false,xver:0,target:$target,serverNames:[$sni],privateKey:$privateKey,minClientVer:"",maxClientVer:"",maxTimediff:0,shortIds:[$shortId],mldsa65Seed:"",settings:{publicKey:$publicKey,fingerprint:"chrome",serverName:"",spiderX:"/",mldsa65Verify:""}}},sniffing:{enabled:true,destOverride:["http","tls","quic","fakedns"],metadataOnly:false,routeOnly:false,ipsExcluded:[],domainsExcluded:[]}}')
  add_response=$(curl --fail --show-error --silent --cookie "$API_COOKIES" \
    --header 'Content-Type: application/json' \
    --header "X-CSRF-Token: $API_CSRF_TOKEN" \
    --data "$payload" \
    "$base/panel/api/inbounds/add")
  json_success "$add_response" || die "3x-ui 创建 REALITY 入站失败：$add_response"

  load_managed_reality_inbound || die '3x-ui 返回成功，但回读时找不到 REALITY 入站'

  systemctl is-active --quiet x-ui || die '创建节点后 3x-ui 服务异常'
  local attempt
  for ((attempt = 1; attempt <= 30; attempt++)); do
    if port_in_use "$REALITY_PORT"; then return 0; fi
    sleep 1
  done
  die "REALITY 入站在 30 秒内没有监听端口 $REALITY_PORT"
}

get_xray_template_response() {
  curl --fail --show-error --silent --cookie "$API_COOKIES" \
    --header "X-CSRF-Token: $API_CSRF_TOKEN" \
    --data '' \
    "$(panel_base_url)/panel/api/xray/"
}

extract_xray_template() {
  jq -cer '
    if (.obj | type) == "string" then (.obj | fromjson | .xraySetting)
    elif (.obj | type) == "object" then .obj.xraySetting
    else error("unexpected xray template response") end
  ' <<<"$1"
}

save_xray_template() {
  local template="$1" test_url="$2"
  curl --fail --show-error --silent --cookie "$API_COOKIES" \
    --header "X-CSRF-Token: $API_CSRF_TOKEN" \
    --data-urlencode "xraySetting=$template" \
    --data-urlencode "outboundTestUrl=$test_url" \
    "$(panel_base_url)/panel/api/xray/update"
}

ensure_direct_freedom_outbound() {
  local response original updated test_url save_response verify_response verify_template restore_response
  response=$(get_xray_template_response)
  json_success "$response" || die '读取 3x-ui Xray 模板失败'
  original=$(extract_xray_template "$response") || die '解析 3x-ui Xray 模板失败'
  test_url=$(jq -er '
    if (.obj | type) == "string" then ((.obj | fromjson).outboundTestUrl // "https://www.google.com/generate_204")
    else (.obj.outboundTestUrl // "https://www.google.com/generate_204") end
  ' <<<"$response")
  if ! jq -e '[.outbounds[]? | select(.tag == "direct" and .protocol == "freedom")] | length == 1' \
      >/dev/null <<<"$original"; then
    die 'Xray 模板中没有唯一的 direct/freedom 出站，拒绝覆盖全局出站配置'
  fi
  updated=$(jq -c '
    (.outbounds[] | select(.tag == "direct" and .protocol == "freedom")) |=
      (. + {sendThrough:"origin",settings:(.settings // {})})
  ' <<<"$original") || die '生成 direct/freedom 出站配置失败'
  if jq -e '.outbounds[] | select(.tag == "direct" and .protocol == "freedom" and .sendThrough == "origin" and (.settings | type == "object"))' \
      >/dev/null <<<"$original"; then
    log 'direct/freedom 出站已经使用 sendThrough=origin'
    return 0
  fi
  save_response=$(save_xray_template "$updated" "$test_url") || true
  if ! json_success "$save_response"; then
    restore_response=$(save_xray_template "$original" "$test_url") || true
    json_success "$restore_response" || warn 'Xray 模板更新失败，且自动恢复原模板未得到成功响应'
    die '设置 direct/freedom sendThrough=origin 失败，已尝试恢复原模板'
  fi
  verify_response=$(get_xray_template_response)
  json_success "$verify_response" || die '更新后无法回读 Xray 模板'
  verify_template=$(extract_xray_template "$verify_response") || die '更新后 Xray 模板解析失败'
  if ! jq -e '.outbounds[] | select(.tag == "direct" and .protocol == "freedom" and .sendThrough == "origin" and (.settings | type == "object"))' \
      >/dev/null <<<"$verify_template"; then
    restore_response=$(save_xray_template "$original" "$test_url") || true
    json_success "$restore_response" || warn 'Xray 模板回读不一致，且自动恢复原模板未得到成功响应'
    die 'direct/freedom 出站更新后回读不一致，已尝试恢复原模板'
  fi
  systemctl is-active --quiet x-ui || die '更新 direct/freedom 出站后 3x-ui 服务异常'
  log '已设置 direct/freedom 出站 sendThrough=origin 并回读确认'
}

xray_binary() {
  local candidate
  for candidate in /usr/local/x-ui/bin/xray-* /usr/local/x-ui/bin/xray; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

free_local_port() {
  local port
  for ((port = 19080; port <= 19180; port++)); do
    if ! port_in_use "$port"; then
      printf '%s' "$port"
      return 0
    fi
  done
  return 1
}

reality_proxy_probe() {
  local address="$1" label="$2" xray socks_port config log_file attempt endpoint result=''
  xray=$(xray_binary) || die '找不到 3x-ui 随附的 Xray，无法执行 REALITY 协议自检'
  socks_port=$(free_local_port) || die '找不到可用于 REALITY 自检的本机临时端口'
  config="$WORK_DIR/reality-probe-${label}.json"
  log_file="$WORK_DIR/reality-probe-${label}.log"
  jq -n \
    --arg address "$address" --argjson serverPort "$REALITY_PORT" --argjson socksPort "$socks_port" \
    --arg uuid "$CLIENT_UUID" --arg sni "$REALITY_SNI" --arg publicKey "$REALITY_PUBLIC_KEY" --arg shortId "$REALITY_SHORT_ID" \
    '{log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:$socksPort,protocol:"socks",settings:{udp:true}}],outbounds:[{protocol:"vless",settings:{vnext:[{address:$address,port:$serverPort,users:[{id:$uuid,encryption:"none",flow:"xtls-rprx-vision"}]}]},streamSettings:{network:"raw",security:"reality",realitySettings:{fingerprint:"chrome",serverName:$sni,publicKey:$publicKey,shortId:$shortId,spiderX:"/"}}}]}' \
    >"$config"
  "$xray" run -c "$config" >"$log_file" 2>&1 &
  SELF_TEST_PID=$!
  for ((attempt = 1; attempt <= 30; attempt++)); do
    port_in_use "$socks_port" && break
    kill -0 "$SELF_TEST_PID" >/dev/null 2>&1 || break
    sleep 0.2
  done
  port_in_use "$socks_port" || die "REALITY ${label}自检客户端启动失败"
  for endpoint in 'https://api.ipify.org' 'https://ipv4.icanhazip.com' 'https://ifconfig.me/ip'; do
    result=$(curl -4 --fail --show-error --silent --location --max-time 12 \
      --noproxy '' --proxy "socks5h://127.0.0.1:${socks_port}" "$endpoint" 2>/dev/null | tr -d '[:space:]') || true
    is_ipv4 "$result" && break
    result=''
  done
  kill "$SELF_TEST_PID" >/dev/null 2>&1 || true
  wait "$SELF_TEST_PID" >/dev/null 2>&1 || true
  SELF_TEST_PID=''
  if [[ -z "$result" ]]; then
    warn "REALITY ${label}协议握手或代理访问失败；诊断日志：$log_file"
    return 1
  fi
  printf '%s' "$result"
}

is_public_ipv4() {
  local value="$1" a b c
  is_ipv4 "$value" || return 1
  IFS='.' read -r a b c _ <<<"$value"
  ((10#$a != 0 && 10#$a != 10 && 10#$a != 127 && 10#$a < 224)) || return 1
  ((!(10#$a == 169 && 10#$b == 254))) || return 1
  ((!(10#$a == 172 && 10#$b >= 16 && 10#$b <= 31))) || return 1
  ((!(10#$a == 192 && 10#$b == 168))) || return 1
  ((!(10#$a == 100 && 10#$b >= 64 && 10#$b <= 127))) || return 1
  ((!(10#$a == 192 && (10#$b == 0 || 10#$b == 2)))) || return 1
  ((!(10#$a == 198 && (10#$b == 18 || 10#$b == 19 || (10#$b == 51 && 10#$c == 100))))) || return 1
  ((!(10#$a == 203 && 10#$b == 0 && 10#$c == 113))) || return 1
}

collect_local_public_ips() {
  local address requested_found=0
  local -a detected=()
  while IFS= read -r address; do
    is_public_ipv4 "$address" && detected+=("$address")
  done < <(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | sort -V -u)
  ((${#detected[@]} > 0)) || die '网卡没有检测到公网 IPv4；为避免再次输出错误节点，脚本不会使用第三方查询结果代替入站地址'
  if [[ -n "$PUBLIC_HOST" ]]; then
    for address in "${detected[@]}"; do
      if [[ "$address" == "$PUBLIC_HOST" ]]; then
        requested_found=1
        PUBLIC_IPS=("$address")
        break
      fi
    done
    ((requested_found == 1)) || die "指定的公网 IPv4 $PUBLIC_HOST 不在本机网卡上"
  else
    PUBLIC_IPS=("${detected[@]}")
  fi
  printf '[3x-ui installer] 检测到 %s 个待配置公网 IPv4: %s\n' "${#PUBLIC_IPS[@]}" "${PUBLIC_IPS[*]}"
}

verify_public_ip_sources() {
  local address endpoint observed
  for address in "${PUBLIC_IPS[@]}"; do
    observed=''
    for endpoint in 'https://api.ipify.org' 'https://ipv4.icanhazip.com' 'https://ifconfig.me/ip'; do
      observed=$(curl -4 --fail --show-error --silent --location --connect-timeout 8 --max-time 15 \
        --noproxy '*' --interface "$address" "$endpoint" 2>/dev/null | tr -d '[:space:]') || true
      [[ "$observed" == "$address" ]] && break
      observed=''
    done
    [[ "$observed" == "$address" ]] || \
      die "公网源地址 $address 出站验证失败；不会安装并输出可能无法独立出站的节点"
    log "公网源地址验证通过：$address"
  done
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

build_vless_uri() {
  local host="$1" uuid="$2" public_key="$3" short_id="$4" name="${5:-$REALITY_REMARK}"
  printf 'vless://%s@%s:%s?type=tcp&security=reality&pbk=%s&fp=chrome&sni=%s&sid=%s&spx=%%2F&flow=xtls-rprx-vision#%s' \
    "$uuid" "$host" "$REALITY_PORT" "$public_key" "$REALITY_SNI" "$short_id" "$name"
}

write_connection_files() {
  local public_host vless_uri name index=0
  local summary='/root/independent-ip-reality.txt'
  local clash_yaml='/root/independent-ip-reality.yaml'
  {
    printf '3x-ui panel: http://%s:%s/%s/\n' "${PUBLIC_IPS[0]}" "$XUI_PANEL_PORT" "$XUI_WEB_PATH"
    printf '3x-ui username: %s\n' "$XUI_USERNAME"
    printf '3x-ui password: %s\n' "$XUI_PASSWORD"
    for public_host in "${PUBLIC_IPS[@]}"; do
      ((index += 1))
      printf -v name '%s-%02d' "$REALITY_REMARK" "$index"
      vless_uri=$(build_vless_uri "$public_host" "$CLIENT_UUID" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" "$name")
      printf '%s: %s\n' "$name" "$vless_uri"
    done
  } >"$summary"
  {
    printf 'proxies:\n'
    index=0
    for public_host in "${PUBLIC_IPS[@]}"; do
      ((index += 1))
      printf -v name '%s-%02d' "$REALITY_REMARK" "$index"
      printf -- '  - name: %s\n' "$name"
      printf '    type: vless\n'
      printf '    server: %s\n' "$public_host"
      printf '    port: %s\n' "$REALITY_PORT"
      printf '    uuid: %s\n' "$CLIENT_UUID"
      printf '    network: tcp\n'
      printf '    tls: true\n'
      printf '    udp: true\n'
      printf '    flow: xtls-rprx-vision\n'
      printf '    servername: %s\n' "$REALITY_SNI"
      printf '    reality-opts:\n'
      printf '      public-key: %s\n' "$REALITY_PUBLIC_KEY"
      printf '      short-id: %s\n' "$REALITY_SHORT_ID"
      printf '    client-fingerprint: chrome\n'
    done
  } >"$clash_yaml"
  chmod 600 "$summary" "$clash_yaml"

  printf '\n安装完成。\n'
  printf '3x-ui 面板: http://%s:%s/%s/\n' "${PUBLIC_IPS[0]}" "$XUI_PANEL_PORT" "$XUI_WEB_PATH"
  printf '3x-ui 账号/密码: %s / %s\n' "$XUI_USERNAME" "$XUI_PASSWORD"
  printf '路由器可导入 VLESS REALITY 链接（每个公网 IP 一条）:\n'
  sed -n '/^independent-ip-reality-/p' "$summary"
  printf 'Mihomo/OpenClash 节点 YAML: %s\n' "$clash_yaml"
  printf '完整结果: %s\n' "$summary"
  printf 'REALITY 验证: %s 个公网 IP 均完成协议握手，且代理出口与接入 IP 一致\n' "${#PUBLIC_IPS[@]}"
  printf '诊断日志: %s\n' "$DIAGNOSTIC_LOG"
}

show_config() {
  printf '\nLinux 3x-ui + VLESS REALITY 无交互安装\n'
  printf '%s\n' '--------------------------------------------------'
  printf '3x-ui 账号=%s，面板端口=%s，REALITY SNI=%s，节点端口=%s\n\n' \
    "$XUI_USERNAME" "$XUI_PANEL_PORT" "$REALITY_SNI" "$REALITY_PORT"
}

main() {
  local address public_exit index=0
  parse_args "$@"
  require_root_linux_systemd
  validate_inputs
  show_config
  ensure_runtime_tools
  collect_local_public_ips
  verify_public_ip_sources
  preflight
  WORK_DIR=$(mktemp -d /tmp/linux-3xui-reality.XXXXXX)
  generate_client_values
  if [[ "$RESUME_EXISTING" != '1' ]]; then
    install_3xui
  fi
  wait_for_panel
  create_reality_inbound
  ensure_direct_freedom_outbound
  open_firewall_ports
  for address in "${PUBLIC_IPS[@]}"; do
    ((index += 1))
    public_exit=$(reality_proxy_probe "$address" "public-${index}") || \
      die "公网地址 ${address}:${REALITY_PORT} 的 REALITY 端到端握手失败；请核对云防火墙和端口映射"
    [[ "$public_exit" == "$address" ]] || \
      die "公网地址 $address 接入后的出口是 $public_exit，不符合独立 IP 同源出站要求"
    log "REALITY 协议与同源出口验证通过：$address"
  done
  write_connection_files
  write_diagnostic_report
}

# 直接执行、bash -c 和 curl | bash 都进入 main；测试 source 时显式设置为 1。
if [[ "${THREEXUI_INSTALLER_SOURCE_ONLY:-0}" != '1' ]]; then
  main "$@"
fi
