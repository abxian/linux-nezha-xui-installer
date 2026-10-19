#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
# vaxilu/x-ui 0.3.2: one Shadowsocks inbound, one port, multiple IP endpoints.
XUI_USERNAME="${XUI_USERNAME:-wochiniming}"
XUI_PASSWORD="${XUI_PASSWORD:-wochiniming}"
XUI_PANEL_PORT="${XUI_PANEL_PORT:-18181}"
SS_PORT="${SS_PORT:-80}"
SS_METHOD="${SS_METHOD:-aes-256-gcm}"
SS_PASSWORD="${SS_PASSWORD:-wochiniming}"
XUI_VERSION='0.3.2'
DB='/etc/x-ui/x-ui.db'
TEMP_DIR=''
cleanup() { [[ -z "$TEMP_DIR" ]] || rm -rf "$TEMP_DIR"; }
trap cleanup EXIT
fail() { echo "[ERROR] $*" >&2; exit 1; }
log() { echo "[installer] $*"; }
usage() {
  cat <<'EOF'
用法: bash install.sh [--username NAME] [--password PASS] [--panel-port PORT]
                    [--ss-port PORT] [--ss-method METHOD] [--ss-password PASS]
默认: 面板账号和密码 wochiniming，面板端口18181，SS端口80，SS密码wochiniming。
已有 x-ui 时不会重装，也不会修改现有面板管理账号密码。
EOF
}
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --username|--password|--panel-port|--ss-port|--ss-method|--ss-password)
      (($#>=2)) || fail "缺少 $1 的值"
      case "$1" in
        --username) XUI_USERNAME="$2";;
        --password) XUI_PASSWORD="$2";;
        --panel-port) XUI_PANEL_PORT="$2";;
        --ss-port) SS_PORT="$2";;
        --ss-method) SS_METHOD="$2";;
        --ss-password) SS_PASSWORD="$2";;
      esac
      shift 2;;
    *) fail "未知参数: $1";;
  esac
done
[[ $EUID -eq 0 ]] || fail '必须使用 root 权限运行'
for port in "$SS_PORT" "$XUI_PANEL_PORT"; do
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port>=1 && 10#$port<=65535)) || fail "无效端口: $port"
done
[[ "$SS_PORT" != "$XUI_PANEL_PORT" ]] || fail '面板与 SS 端口不能相同'
case "$SS_METHOD" in aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305) ;; *) fail '不支持的 SS 加密方式';; esac
[[ -n "$SS_PASSWORD" && -n "$XUI_USERNAME" && -n "$XUI_PASSWORD" ]] || fail '账号密码不能为空'
# Installer prompts are line-oriented; reject line breaks.
[[ "$XUI_USERNAME" != *$'\n'* && "$XUI_PASSWORD" != *$'\n'* ]] || fail '账号和面板密码不能含换行'
export SS_PORT SS_PASSWORD SS_METHOD
install_pkg() {
  if command -v apt-get >/dev/null; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif command -v dnf >/dev/null; then dnf install -y "$@"
  elif command -v yum >/dev/null; then yum install -y "$@"
  else fail "请安装依赖: $*"; fi
}
for c in curl python3 ip systemctl; do
  if ! command -v "$c" >/dev/null 2>&1; then
    case "$c" in ip) install_pkg iproute2;; *) install_pkg "$c";; esac
  fi
done
mapfile -t IPS < <(ip -o -4 addr show scope global | python3 -c '
import sys, ipaddress
ips=set()
for line in sys.stdin:
    fields=line.split()
    if len(fields)<4 or fields[2]!="inet": continue
    addr=ipaddress.ip_interface(fields[3]).ip
    if addr.is_global: ips.add(str(addr))
print("\n".join(sorted(ips,key=lambda v:int(ipaddress.ip_address(v)))))')
((${#IPS[@]})) || fail '网卡没有检测到公网 IPv4，请检查 ip -4 addr'
printf '检测到 %s 个网卡公网 IP: %s\n' "${#IPS[@]}" "${IPS[*]}"
for addr in "${IPS[@]}"; do
  actual=$(curl -4fsS --interface "$addr" --connect-timeout 4 --max-time 10 https://api.ipify.org 2>/dev/null || true)
  if [[ "$actual" == "$addr" ]]; then log "源 IP 出站检测通过: $addr"
  else log "警告: $addr 源地址测试失败（返回 ${actual:-无}），对应节点可能断网"; fi
done
if [[ ! -x /usr/local/x-ui/x-ui ]]; then
  log '首次安装 vaxilu/x-ui 0.3.2'
  for c in unzip wget tar; do command -v "$c" >/dev/null 2>&1 || install_pkg "$c"; done
  TEMP_DIR=$(mktemp -d)
  curl -fsSL --retry 3 'https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh' -o "$TEMP_DIR/xui-installer.sh"
  printf 'y\n%s\n%s\n%s\n' "$XUI_USERNAME" "$XUI_PASSWORD" "$XUI_PANEL_PORT" | bash "$TEMP_DIR/xui-installer.sh" "$XUI_VERSION"
  [[ -x /usr/local/x-ui/x-ui ]] || fail 'x-ui 安装失败'
  /usr/local/x-ui/x-ui setting -username "$XUI_USERNAME" -password "$XUI_PASSWORD"
  /usr/local/x-ui/x-ui setting -port "$XUI_PANEL_PORT"
  systemctl restart x-ui
  systemctl is-active --quiet x-ui || fail 'x-ui 未启动'
  log '等待面板 API 就绪'
  ready=0
  for ((j=0;j<30;j++)); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${XUI_PANEL_PORT}/" -o /dev/null 2>/dev/null; then ready=1; break; fi
    sleep 1
  done
  ((ready)) || fail '面板未在预期端口监听'
  cookie="$TEMP_DIR/cookie"
  login=$(curl -fsS --cookie-jar "$cookie" --data-urlencode "username=$XUI_USERNAME" --data-urlencode "password=$XUI_PASSWORD" "http://127.0.0.1:${XUI_PANEL_PORT}/login")
  [[ "$login" == *'"success":true'* || "$login" == *'"success": true'* ]] || fail "登录新安装的 x-ui 失败: $login"
  ss_settings=$(python3 -c 'import json,os;print(json.dumps({"method":os.environ["SS_METHOD"],"password":os.environ["SS_PASSWORD"],"network":"tcp,udp"}))')
  response=$(curl -fsS --cookie "$cookie" -X POST "http://127.0.0.1:${XUI_PANEL_PORT}/xui/inbound/add" \
    --data-urlencode 'up=0' --data-urlencode 'down=0' --data-urlencode 'total=0' \
    --data-urlencode 'remark=independent-ip' --data-urlencode 'enable=true' \
    --data-urlencode 'expiryTime=0' --data-urlencode 'listen=' \
    --data-urlencode "port=$SS_PORT" --data-urlencode 'protocol=shadowsocks' \
    --data-urlencode "settings=$ss_settings" \
    --data-urlencode 'streamSettings={"network":"tcp","security":"none","tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}' \
    --data-urlencode 'sniffing={"enabled":true,"destOverride":["http","tls"]}')
  [[ "$response" == *'"success":true'* || "$response" == *'"success": true'* ]] || fail "创建 SS 入站失败: $response"
else
  log '检测到已有 x-ui，保留安装和管理账号，仅更新目标 SS 入站与出口模板'
fi
[[ -f "$DB" ]] || fail "找不到 x-ui 数据库 $DB"
mkdir -p /root/x-ui-backups
BACKUP="/root/x-ui-backups/x-ui-$(date +%Y%m%d-%H%M%S)-$$.db"
python3 - "$DB" "$BACKUP" <<'PY'
import sqlite3,sys
src=sqlite3.connect(sys.argv[1]);dst=sqlite3.connect(sys.argv[2]);src.backup(dst);dst.close();src.close()
PY
log "备份成功: $BACKUP"
python3 - "$DB" <<'PY'
import sqlite3,json,os,sys
port=int(os.environ['SS_PORT']); method=os.environ['SS_METHOD'];password=os.environ['SS_PASSWORD']
DEFAULT={
 'api':{'services':['HandlerService','LoggerService','StatsService'],'tag':'api'},
 'inbounds':[{'listen':'127.0.0.1','port':62789,'protocol':'dokodemo-door','settings':{'address':'127.0.0.1'},'tag':'api'}],
 'outbounds':[{'protocol':'freedom','settings':{}},{'protocol':'blackhole','settings':{},'tag':'blocked'}],
 'policy':{'system':{'statsInboundDownlink':True,'statsInboundUplink':True}},
 'routing':{'rules':[{'inboundTag':['api'],'outboundTag':'api','type':'field'},
                     {'ip':['geoip:private'],'outboundTag':'blocked','type':'field'},
                     {'outboundTag':'blocked','protocol':['bittorrent'],'type':'field'}]},
 'stats':{}
}
conn=sqlite3.connect(sys.argv[1]);conn.execute('BEGIN IMMEDIATE')
try:
    rows=conn.execute('SELECT id,protocol,settings FROM inbounds WHERE port=?',(port,)).fetchall()
    if len(rows)!=1 or rows[0][1]!='shadowsocks':
        raise RuntimeError(f'端口 {port} 必须恰好存在一个 Shadowsocks 入站，目前 {len(rows)} 个')
    ident,_,raw=rows[0]
    s=json.loads(raw)
    s.update(method=method,password=password,network='tcp,udp')
    row=conn.execute("SELECT id,value FROM settings WHERE key='xrayTemplateConfig' ORDER BY id LIMIT 1").fetchone()
    template=json.loads(row[1]) if row else DEFAULT
    if not isinstance(template,dict) or not isinstance(template.get('outbounds'),list) or not template['outbounds']:
        raise RuntimeError('Xray 模板结构不正确')
    first=template['outbounds'][0]
    if first.get('protocol')!='freedom':raise RuntimeError('默认出站不是 freedom，拒绝覆盖')
    first['sendThrough']='origin'
    first.setdefault('settings',{})
    conn.execute('UPDATE inbounds SET settings=?,listen=? WHERE id=?',
        (json.dumps(s,ensure_ascii=False,separators=(',',':')),'',ident))
    payload=json.dumps(template,ensure_ascii=False,separators=(',',':'))
    if row:
        conn.execute('UPDATE settings SET value=? WHERE id=?',(payload,row[0]))
    else:
        conn.execute('INSERT INTO settings(key,value) VALUES (?,?)',('xrayTemplateConfig',payload))
    conn.commit()
except Exception:
    conn.rollback();raise
finally:conn.close()
print(f'已设置 SS :{port} 密码={password}，Xray sendThrough=origin')
PY
systemctl restart x-ui
systemctl is-active --quiet x-ui || fail "x-ui 重启失败，可用备份恢复: $BACKUP"
# x-ui may remain active even when Xray fails. Verify the SS socket is actually listening.
if command -v ss >/dev/null 2>&1; then
  listening=0
  for ((j=0;j<12;j++)); do
    if ss -H -lntu | awk -v p="$SS_PORT" '$5 ~ (":"p"$"){found=1} END{exit !found}'; then listening=1;break;fi
    sleep 1
  done
  ((listening)) || log '警告: x-ui 服务运行但未发现 SS 监听端口；请检查 x-ui Xray 日志'
fi
printf '%s\n' "${IPS[@]}" | python3 -c '
import sys,os,json,base64,urllib.parse
ips=[x.strip() for x in sys.stdin if x.strip()]
method=os.environ["SS_METHOD"];pw=os.environ["SS_PASSWORD"];port=int(os.environ["SS_PORT"])
token=base64.urlsafe_b64encode(f"{method}:{pw}".encode()).decode().rstrip("=")
links=[];nodes=[]
for i,ip in enumerate(ips,1):
    name=f"美国{i:02d}"
    links.append(f"ss://{token}@{ip}:{port}#{urllib.parse.quote(name)}")
    nodes.append(dict(name=name,type="ss",server=ip,port=port,cipher=method,password=pw,udp=True))
with open("/root/multiip-ss-links.txt","w") as f:f.write("\n".join(links)+"\n")
with open("/root/multiip-ss-clash.yaml","w") as f:
    f.write("proxies:\n")
    for n in nodes:
        f.write("  - name: "+json.dumps(n["name"],ensure_ascii=False)+"\n")
        for k in ("type","server","port","cipher","password","udp"):
            f.write(f"    {k}: {json.dumps(n[k],ensure_ascii=False)}\n")
print(f"生成 {len(nodes)} 个客户端节点：")
for ip in ips:print(" -",ip)
'
chmod 600 /root/multiip-ss-links.txt /root/multiip-ss-clash.yaml
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow "$SS_PORT/tcp";ufw allow "$SS_PORT/udp"
fi
log "完成: ${#IPS[@]} 个 IP 共用 SS 端口 $SS_PORT，统一密码 $SS_PASSWORD"
log 'SS 链接: /root/multiip-ss-links.txt'
log 'OpenClash YAML: /root/multiip-ss-clash.yaml'
log '注意: origin 出站的 TCP/UDP 实际效果仍需逐节点测试。'
