#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$REPO_DIR/install-3xui-reality.sh"

bash -n "$INSTALLER"

export THREEXUI_INSTALLER_SOURCE_ONLY=1
# shellcheck disable=SC1090
source "$INSTALLER"
unset THREEXUI_INSTALLER_SOURCE_ONLY

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_eq 'wochiniming' "$XUI_USERNAME" 'default 3x-ui username'
assert_eq 'wochiniming' "$XUI_PASSWORD" 'default 3x-ui password'
assert_eq '18181' "$XUI_PANEL_PORT" 'default panel port'
assert_eq '443' "$REALITY_PORT" 'default REALITY port'
assert_eq 'www.cloudflare.com' "$REALITY_SNI" 'default REALITY SNI'
assert_eq 'reality' "$XUI_WEB_PATH" 'fixed panel path'

is_valid_port '443'
is_valid_port '65535'
if is_valid_port '0' || is_valid_port '65536' || is_valid_port 'abc'; then
  printf 'FAIL: invalid port was accepted\n' >&2
  exit 1
fi
is_valid_domain 'www.cloudflare.com'
if is_valid_domain 'bad_domain' || is_valid_domain '-bad.example'; then
  printf 'FAIL: invalid REALITY SNI was accepted\n' >&2
  exit 1
fi
is_ipv4 '216.167.36.198'
if is_ipv4 '999.1.1.1'; then
  printf 'FAIL: invalid IPv4 was accepted\n' >&2
  exit 1
fi

parse_args --username admin --password SafePass_123 --panel-port 19000 \
  --reality-port 8443 --reality-sni cdn.example.com --public-host 216.167.36.198
validate_inputs
assert_eq 'admin' "$XUI_USERNAME" 'custom username'
assert_eq 'SafePass_123' "$XUI_PASSWORD" 'custom password'
assert_eq '19000' "$XUI_PANEL_PORT" 'custom panel port'
assert_eq '8443' "$REALITY_PORT" 'custom REALITY port'
assert_eq 'cdn.example.com' "$REALITY_SNI" 'custom REALITY SNI'
assert_eq '216.167.36.198' "$PUBLIC_HOST" 'custom public host'

XUI_USERNAME='wochiniming'
XUI_PASSWORD='wochiniming'
XUI_PANEL_PORT='18181'
XUI_WEB_PATH='reality'
REALITY_PORT='443'
REALITY_SNI='www.cloudflare.com'
PUBLIC_HOST=''
CLIENT_UUID='22222222-3333-4444-9555-666666666666'
REALITY_PUBLIC_KEY='Tx5yj1bRcOPHkdvT2pIAQ2zh0gQ8m4OPdnzqXJxxV3o'
REALITY_PRIVATE_KEY='wM-2_oQRWXyLcXhV5q1ifTBcS3K8mYR3wQI3PqGFK1k'
REALITY_SHORT_ID='a3f1b8c2d4e6f809'

expected='vless://22222222-3333-4444-9555-666666666666@216.167.36.198:443?type=tcp&security=reality&pbk=Tx5yj1bRcOPHkdvT2pIAQ2zh0gQ8m4OPdnzqXJxxV3o&fp=chrome&sni=www.cloudflare.com&sid=a3f1b8c2d4e6f809&spx=%2F&flow=xtls-rprx-vision#independent-ip-reality'
actual=$(build_vless_uri '216.167.36.198' "$CLIENT_UUID" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID")
assert_eq "$expected" "$actual" 'VLESS REALITY URI'

bash "$INSTALLER" --help | grep -q 'Linux 3x-ui + VLESS REALITY 无交互安装'
bash -c "$(command cat "$INSTALLER")" installer --help | \
  grep -q 'Linux 3x-ui + VLESS REALITY 无交互安装'

mock_dir=$(mktemp -d)
cleanup_test() {
  local status=$?
  rm -rf -- "$mock_dir"
  exit "$status"
}
trap cleanup_test EXIT
# shellcheck disable=SC2034
WORK_DIR="$mock_dir"

install_result="$mock_dir/install-result.env"
printf '%s\n' \
  'XUI_USERNAME=wochiniming' \
  'XUI_PASSWORD=wochiniming' \
  'XUI_PANEL_PORT=18181' \
  'XUI_WEB_BASE_PATH=reality' >"$install_result"
chmod 600 "$install_result"
install_result_values_match "$install_result"
sed 's/XUI_PANEL_PORT=18181/XUI_PANEL_PORT=19000/' "$install_result" >"$mock_dir/wrong-result.env"
if install_result_values_match "$mock_dir/wrong-result.env"; then
  printf 'FAIL: mismatched prior install was accepted for resume\n' >&2
  exit 1
fi

# Invoked indirectly by create_reality_inbound after sourcing the installer.
# shellcheck disable=SC2317,SC2329
curl() {
  printf '%s\n' "$*" >>"$mock_dir/curl.log"
  case "$*" in
    *'/csrf-token'*) printf '{"success":true,"obj":"abcdefghijklmnopqrstuvwxyz0123456789_-ABCDE"}' ;;
    *'/login'*) printf '{"success":true}' ;;
    *'/panel/api/inbounds/list'*)
      if [[ -e "$mock_dir/inbound-created" ]]; then
        jq -cn \
          --arg uuid "$CLIENT_UUID" --arg privateKey "$REALITY_PRIVATE_KEY" \
          --arg publicKey "$REALITY_PUBLIC_KEY" --arg shortId "$REALITY_SHORT_ID" \
          '{success:true,obj:[{id:9,enable:true,remark:"independent-ip-reality",port:443,protocol:"vless",settings:({clients:[{id:$uuid,enable:true,flow:"xtls-rprx-vision"}]}|tojson),streamSettings:({network:"tcp",security:"reality",realitySettings:{target:"www.cloudflare.com:443",serverNames:["www.cloudflare.com"],privateKey:$privateKey,shortIds:[$shortId],settings:{publicKey:$publicKey}}}|tojson)}]}'
      else
        printf '{"success":true,"obj":[]}'
      fi
      ;;
    *'/panel/api/server/getNewX25519Cert'*)
      printf '{"success":true,"obj":{"privateKey":"%s","publicKey":"%s"}}' \
        "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY"
      ;;
    *'/panel/api/inbounds/add'*) touch "$mock_dir/inbound-created"; printf '{"success":true}' ;;
    *'/panel/api/xray/update'*) touch "$mock_dir/xray-updated"; printf '{"success":true}' ;;
    *'/panel/api/xray/'*)
      if [[ -e "$mock_dir/xray-updated" ]]; then
        printf '%s' '{"success":true,"obj":"{\"xraySetting\":{\"outbounds\":[{\"tag\":\"direct\",\"protocol\":\"freedom\",\"sendThrough\":\"origin\",\"settings\":{}}]},\"outboundTestUrl\":\"https://example.com/204\"}"}'
      else
        printf '%s' '{"success":true,"obj":"{\"xraySetting\":{\"outbounds\":[{\"tag\":\"direct\",\"protocol\":\"freedom\",\"settings\":{}}]},\"outboundTestUrl\":\"https://example.com/204\"}"}'
      fi
      ;;
    *) return 1 ;;
  esac
}

# shellcheck disable=SC2317,SC2329
systemctl() { return 0; }

# shellcheck disable=SC2317,SC2329
port_in_use() { return 0; }

create_reality_inbound
grep -q '/reality/csrf-token' "$mock_dir/curl.log"
if [[ $(grep -c 'X-CSRF-Token: abcdefghijklmnopqrstuvwxyz0123456789_-ABCDE' "$mock_dir/curl.log") -lt 2 ]]; then
  printf 'FAIL: login and inbound POST did not both carry the CSRF token\n' >&2
  exit 1
fi
grep -q '/reality/panel/api/inbounds/add' "$mock_dir/curl.log"
grep -q '"port":443' "$mock_dir/curl.log"
grep -q '"protocol":"vless"' "$mock_dir/curl.log"
grep -q '"security":"reality"' "$mock_dir/curl.log"
grep -q '"target":"www.cloudflare.com:443"' "$mock_dir/curl.log"
grep -q '"flow":"xtls-rprx-vision"' "$mock_dir/curl.log"
grep -q '"privateKey"' "$mock_dir/curl.log"
grep -q '"shortIds"' "$mock_dir/curl.log"

add_count_before=$(grep -c '/panel/api/inbounds/add' "$mock_dir/curl.log")
# Used by the sourced installer's create_reality_inbound function.
# shellcheck disable=SC2034
RESUME_EXISTING=1
create_reality_inbound
add_count_after=$(grep -c '/panel/api/inbounds/add' "$mock_dir/curl.log")
assert_eq "$add_count_before" "$add_count_after" 'safe resume reuses the exact managed inbound'

ensure_direct_freedom_outbound
grep -q '/panel/api/xray/update' "$mock_dir/curl.log"
grep -q 'sendThrough' "$mock_dir/curl.log"
grep -q 'origin' "$mock_dir/curl.log"

is_public_ipv4 '8.8.8.8'
if is_public_ipv4 '10.0.0.1' || is_public_ipv4 '100.64.0.1' || is_public_ipv4 '192.168.1.1' || is_public_ipv4 '203.0.113.1'; then
  printf 'FAIL: private/reserved IPv4 accepted as public\n' >&2
  exit 1
fi

unset -f curl systemctl port_in_use

# shellcheck disable=SC2317,SC2329
ip() {
  printf '%s\n' \
    '2: eth0    inet 8.8.8.8/24 brd 8.8.8.255 scope global eth0' \
    '2: eth0    inet 9.9.9.9/24 brd 9.9.9.255 scope global secondary eth0'
}
# shellcheck disable=SC2317,SC2329
curl() {
  local previous='' argument
  for argument in "$@"; do
    if [[ "$previous" == '--interface' ]]; then
      printf '%s' "$argument"
      return 0
    fi
    previous="$argument"
  done
  return 1
}
PUBLIC_HOST=''
PUBLIC_IPS=()
collect_local_public_ips
assert_eq '2' "${#PUBLIC_IPS[@]}" 'all local public IPv4 addresses detected'
assert_eq '8.8.8.8' "${PUBLIC_IPS[0]}" 'public IPv4 addresses sorted'
assert_eq '9.9.9.9' "${PUBLIC_IPS[1]}" 'second public IPv4 detected'
verify_public_ip_sources
unset -f curl ip

grep -q "DEFAULT_XUI_PANEL_PORT='18181'" "$INSTALLER"
grep -q "readonly DEFAULT_REALITY_PORT='443'" "$INSTALLER"
grep -q "DEFAULT_XUI_USERNAME='wochiniming'" "$INSTALLER"
grep -q "DEFAULT_XUI_PASSWORD='wochiniming'" "$INSTALLER"
grep -q 'MHSanaei/3x-ui/main/install.sh' "$INSTALLER"
grep -q 'THREEXUI_INSTALLER_SOURCE_ONLY' "$INSTALLER"
grep -q 'sendThrough:"origin"' "$INSTALLER"
grep -q 'MULTIIP-REALITY-ORIGIN' "$INSTALLER"
grep -q 'collect_local_public_ips' "$INSTALLER"
grep -q 'public_exit=.*reality_proxy_probe' "$INSTALLER"
grep -q '不符合独立 IP 同源出站要求' "$INSTALLER"

if grep -Eiq 'nezhahq|NZ_CLIENT_SECRET|NZ_SERVER|NZ_TLS' "$INSTALLER"; then
  printf 'FAIL: Nezha functionality or credentials found in 3x-ui installer\n' >&2
  exit 1
fi

printf 'PASS: 3x-ui defaults, string/object API readback, direct origin outbound, multi-IP source checks, URI, and execution modes\n'
