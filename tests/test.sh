#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$REPO_DIR/install.sh"

bash -n "$INSTALLER"

assert_contains() {
  local pattern="$1" label="$2"
  if ! grep -Eq "$pattern" "$INSTALLER"; then
    printf 'FAIL: %s\nmissing pattern: %s\n' "$label" "$pattern" >&2
    exit 1
  fi
}

assert_contains '^# BUILD: MULTIIP-ARCHIVE-FIX-' 'versioned multi-IP build marker'
assert_contains 'PANEL_USER="\$\{XUI_USERNAME:-wochiniming\}"' 'default panel username'
assert_contains 'PANEL_PASS="\$\{XUI_PASSWORD:-wochiniming\}"' 'default panel password'
assert_contains 'PANEL_PORT="\$\{XUI_PANEL_PORT:-18181\}"' 'default panel port'
assert_contains 'SS_PASS="\$\{SS_PASSWORD:-wochiniming\}"' 'default Shadowsocks password'
assert_contains 'SS_PORT="\$\{SS_PORT:-80\}"' 'default Shadowsocks port'
assert_contains 'SS_METHOD="aes-256-gcm"' 'default Shadowsocks cipher'
assert_contains 'XUI_VERSION="0\.3\.2"' 'pinned legacy x-ui version'
assert_contains 'sendThrough.*origin' 'direct freedom origin binding'
assert_contains "'network':'tcp,udp'" 'TCP and UDP enabled'
assert_contains 'curl .*--interface .*addr' 'per-address source validation'
assert_contains 'ext.*==.*addr' 'source address must match public result'
assert_contains 'Xray-core/releases/latest' 'latest stable Xray discovery'
assert_contains 'run -test -config' 'full Xray configuration validation'
assert_contains 'x-ui-reinstall-backup-' 'pre-install backup path'
assert_contains '尝试恢复旧版' 'rollback path'
assert_contains 'multiip-ss-links\.txt' 'multi-IP link output'
assert_contains 'multiip-ss-clash\.yaml' 'OpenClash output'
assert_contains "'udp':True" 'OpenClash UDP flag'

if grep -Eiq 'nezhahq|NEZHA_INSTALL|NZ_CLIENT_SECRET|NZ_SERVER|NZ_TLS' "$INSTALLER"; then
  printf 'FAIL: Nezha functionality or configuration is present\n' >&2
  exit 1
fi

if ((EUID != 0)); then
  output=$(bash "$INSTALLER" 2>&1 || true)
  grep -q '请以 root 身份运行' <<<"$output" || {
    printf 'FAIL: non-root preflight did not stop with the expected message\n' >&2
    exit 1
  }
fi

printf 'PASS: current x-ui multi-IP build, defaults, source binding, rollback, validation, outputs, and Nezha removal\n'
