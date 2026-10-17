#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

bash -n "$REPO_DIR/install.sh"

# The sourced functions consume these globals and indirect command mocks.
# shellcheck disable=SC1091
source "$REPO_DIR/install.sh"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

expected='ss://YWVzLTI1Ni1nY206Z2Q5NzI2d3FRa0AyMTYuMTY3LjM2LjE5ODo4MA#independent-ip'
SS_PORT='80'
actual=$(build_ss_uri '216.167.36.198' 'gd9726wqQk')
assert_eq "$expected" "$actual" 'SS URI should match the requested whole-payload base64 format'

is_ipv4 '216.167.36.198'
if is_ipv4 '999.1.1.1'; then
  printf 'FAIL: invalid IPv4 was accepted\n' >&2
  exit 1
fi
is_valid_port '80'
is_valid_port '65535'
if is_valid_port '0' || is_valid_port '65536' || is_valid_port 'abc'; then
  printf 'FAIL: invalid port was accepted\n' >&2
  exit 1
fi

SS_PORT='unset'
collect_choices <<< $'y\n'
assert_eq '80' "$SS_PORT" 'SS should use port 80 by default'

SS_PORT='unset'
collect_choices <<< $'n\n8388\n'
assert_eq '8388' "$SS_PORT" 'Custom SS port should be accepted'

mock_dir=$(mktemp -d)
cleanup_test() {
  local status=$?
  rm -rf -- "$mock_dir"
  exit "$status"
}
trap cleanup_test EXIT
# Consumed by create_shadowsocks_inbound from the sourced installer.
# shellcheck disable=SC2034
WORK_DIR="$mock_dir"
# shellcheck disable=SC2034
SS_PASSWORD='gd9726wqQk'

# shellcheck disable=SC2317
curl() {
  printf '%s\n' "$*" >>"$mock_dir/curl.log"
  case "$*" in
    *'/login'*) printf '{"success":true}' ;;
    *'/xui/inbound/list'*) printf '{"success":true,"obj":[]}' ;;
    *'/xui/inbound/add'*) printf '{"success":true}' ;;
    *) return 1 ;;
  esac
}

# shellcheck disable=SC2317
systemctl() {
  return 0
}

# shellcheck disable=SC2317
port_in_use() {
  return 0
}

create_shadowsocks_inbound
grep -q '/xui/inbound/add' "$mock_dir/curl.log"
grep -q 'port=8388' "$mock_dir/curl.log"
grep -q 'protocol=shadowsocks' "$mock_dir/curl.log"
grep -q 'aes-256-gcm' "$mock_dir/curl.log"
grep -q 'tcp,udp' "$mock_dir/curl.log"

unset -f curl systemctl port_in_use

grep -q "readonly XUI_PANEL_PORT='18181'" "$REPO_DIR/install.sh"
grep -q "readonly DEFAULT_SS_PORT='80'" "$REPO_DIR/install.sh"
grep -q "readonly XUI_USERNAME='wochiniming'" "$REPO_DIR/install.sh"
grep -q "readonly XUI_PASSWORD='wochiniming'" "$REPO_DIR/install.sh"
grep -q "readonly SS_METHOD='aes-256-gcm'" "$REPO_DIR/install.sh"
grep -q "protocol=shadowsocks" "$REPO_DIR/install.sh"

if grep -Eiq 'nezha|NZ_CLIENT_SECRET|NZ_SERVER|NZ_TLS' "$REPO_DIR/install.sh"; then
  printf 'FAIL: Nezha functionality or configuration is still present\n' >&2
  exit 1
fi

printf 'PASS: syntax, x-ui defaults, port choices, URI generation, API request, and Nezha removal\n'
