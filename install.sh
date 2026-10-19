#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
# x-ui 0.3.2: one SS inbound, one port, different server IP endpoints.
XUI_USERNAME="${XUI_USERNAME:-wochiniming}"
XUI_PASSWORD="${XUI_PASSWORD:-wochiniming}"
XUI_PANEL_PORT="${XUI_PANEL_PORT:-18181}"
SS_PORT="${SS_PORT:-80}"
SS_METHOD="${SS_METHOD:-aes-256-gcm}"
SS_PASSWORD="${SS_PASSWORD:-wochiniming}"
DB=/etc/x-ui/x-ui.db
REPORT=/root/x-ui-multiip-diagnostic.log
DIAGDIR=/root/x-ui-multiip-debug
BACKUP=''
WORKDIR=''
log(){ printf '[installer] %s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup(){ [[ -z "$WORKDIR" ]] || rm -rf "$WORKDIR"; }
trap cleanup EXIT
usage(){ cat <<'EOF'
用法：bash install.sh [--username 用户] [--password 面板密码] [--panel-port 18181] [--ss-port 80] [--ss-method aes-256-gcm] [--ss-password wochiniming]
已有 x-ui：不重装、不修改面板账户，只更新指定端口 SS 及出口模板。
诊断日志：/root/x-ui-multiip-diagnostic.log（不会包含 SS 密码或完整链接）
EOF
}
while (($#)); do
  case "$1" in
    -h|--help) usage;exit 0;;
    --username|--password|--panel-port|--ss-port|--ss-method|--ss-password)
      (($# >= 2)) || fail "$1 缺少参数值"
      case "$1" in
        --username) XUI_USERNAME="$2";; --password) XUI_PASSWORD="$2";;
        --panel-port) XUI_PANEL_PORT="$2";; --ss-port) SS_PORT="$2";;
        --ss-method) SS_METHOD="$2";; --ss-password) SS_PASSWORD="$2";;
      esac; shift 2;;
    *) fail "未知参数：$1";;
  esac
done
[[ $EUID -eq 0 ]] || fail '必须 root 运行'
for p in "$SS_PORT" "$XUI_PANEL_PORT"; do
  [[ "$p" =~ ^[0-9]{1,5}$ ]] || fail "端口无效: $p"
  (( 10#$p>=1 && 10#$p<=65535 )) || fail "端口越界: $p"
done
[[ "$SS_PORT" != "$XUI_PANEL_PORT" ]] || fail 'SS 端口不能与面板端口相同'
case "$SS_METHOD" in aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305) ;; *) fail '加密方式不支持';; esac
[[ -n "$SS_PASSWORD" ]] || fail 'SS 密码不能为空'
export SS_PORT SS_METHOD SS_PASSWORD
package_install(){
  if command -v apt-get >/dev/null; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif command -v dnf >/dev/null; then dnf install -y "$@"
  elif command -v yum >/dev/null; then yum install -y "$@"
  else fail "请手动安装软件包: $*"; fi
}
for c in curl python3 ip ss systemctl; do
  if ! command -v "$c" >/dev/null 2>&1; then
    case "$c" in ip|ss) package_install iproute2;; *) package_install "$c";; esac
  fi
done
mapfile -t IPS < <(ip -o -4 addr show scope global | python3 -c '
import sys,ipaddress
s=set()
for ln in sys.stdin:
    p=ln.split()
    if len(p)>3 and p[2]=="inet":
        a=ipaddress.ip_interface(p[3]).ip
        if a.is_global:s.add(str(a))
print("\n".join(sorted(s,key=lambda x:int(ipaddress.ip_address(x)))))')
((${#IPS[@]})) || fail '网卡没有检测到公网 IPv4'
printf '检测到 %d 个公网 IP: %s\n' "${#IPS[@]}" "${IPS[*]}"
mkdir -p "$DIAGDIR"
for addr in "${IPS[@]}"; do
  actual=$(curl -4fsS --interface "$addr" --connect-timeout 4 --max-time 10 https://api.ipify.org 2>/dev/null || true)
  if [[ "$actual" == "$addr" ]];then log "出站源 IP 测试通过: $addr";
  else log "警告: $addr 出站检查失败，结果 ${actual:-无}";fi
done
if [[ ! -x /usr/local/x-ui/x-ui ]]; then
  log '没有检测到 x-ui，安装 vaxilu/x-ui 0.3.2'
  for c in wget tar unzip; do command -v "$c" >/dev/null 2>&1 || package_install "$c";done
  WORKDIR=$(mktemp -d)
  curl -fsSL --retry 3 https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh -o "$WORKDIR/xui.sh"
  printf 'y\n%s\n%s\n%s\n' "$XUI_USERNAME" "$XUI_PASSWORD" "$XUI_PANEL_PORT" | bash "$WORKDIR/xui.sh" 0.3.2
  [[ -x /usr/local/x-ui/x-ui ]] || fail 'x-ui 主程序安装失败'
  /usr/local/x-ui/x-ui setting -username "$XUI_USERNAME" -password "$XUI_PASSWORD"
  /usr/local/x-ui/x-ui setting -port "$XUI_PANEL_PORT"
  systemctl restart x-ui
  for i in {1..20}; do
    curl -fsS --max-time 2 "http://127.0.0.1:${XUI_PANEL_PORT}/" -o /dev/null 2>/dev/null && break
    sleep 1
  done
  WORKDIR=${WORKDIR:-$(mktemp -d)}
  cookie="$WORKDIR/cookie"
  resp=$(curl -fsS --cookie-jar "$cookie" --data-urlencode "username=$XUI_USERNAME" --data-urlencode "password=$XUI_PASSWORD" "http://127.0.0.1:${XUI_PANEL_PORT}/login")
  [[ "$resp" == *'"success":true'* || "$resp" == *'"success": true'* ]] || fail '首次安装后登录 API 失败'
  settings=$(python3 -c 'import json,os;print(json.dumps(dict(method=os.environ["SS_METHOD"],password=os.environ["SS_PASSWORD"],network="tcp,udp")))')
  resp=$(curl -fsS --cookie "$cookie" -X POST "http://127.0.0.1:${XUI_PANEL_PORT}/xui/inbound/add" \
    --data-urlencode up=0 --data-urlencode down=0 --data-urlencode total=0 \
    --data-urlencode remark=independent-ip --data-urlencode enable=true \
    --data-urlencode expiryTime=0 --data-urlencode listen= \
    --data-urlencode "port=$SS_PORT" --data-urlencode protocol=shadowsocks \
    --data-urlencode "settings=$settings" \
    --data-urlencode 'streamSettings={"network":"tcp","security":"none","tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}' \
    --data-urlencode 'sniffing={"enabled":true,"destOverride":["http","tls"]}')
  [[ "$resp" == *'"success":true'* || "$resp" == *'"success": true'* ]] || fail '创建 SS 入站失败'
else
  log '保留已有 x-ui，仅修改目标 SS 入站和 Xray 模板'
fi
[[ -f "$DB" ]] || fail "数据库不存在: $DB"
mkdir -p /root/x-ui-backups
BACKUP="/root/x-ui-backups/x-ui-$(date +%Y%m%d-%H%M%S)-$$.db"
python3 - "$DB" "$BACKUP" <<'PY'
import sqlite3,sys
s=sqlite3.connect(sys.argv[1]);d=sqlite3.connect(sys.argv[2]);s.backup(d);d.close();s.close()
PY
log "已备份数据库: $BACKUP"
python3 - "$DB" <<'PY'
import os,sqlite3,json,sys
port=int(os.environ['SS_PORT']);method=os.environ['SS_METHOD'];pw=os.environ['SS_PASSWORD']
tmpl={
 'api':{'services':['HandlerService','LoggerService','StatsService'],'tag':'api'},
 'inbounds':[{'listen':'127.0.0.1','port':62789,'protocol':'dokodemo-door','settings':{'address':'127.0.0.1'},'tag':'api'}],
 'outbounds':[{'protocol':'freedom','settings':{}},{'protocol':'blackhole','settings':{},'tag':'blocked'}],
 'policy':{'system':{'statsInboundDownlink':True,'statsInboundUplink':True}},
 'routing':{'rules':[{'inboundTag':['api'],'outboundTag':'api','type':'field'},
                     {'ip':['geoip:private'],'outboundTag':'blocked','type':'field'},
                     {'outboundTag':'blocked','protocol':['bittorrent'],'type':'field'}]},'stats':{}}
con=sqlite3.connect(sys.argv[1]);con.execute('BEGIN IMMEDIATE')
try:
 rows=con.execute('SELECT id,protocol,settings FROM inbounds WHERE port=?',(port,)).fetchall()
 if len(rows)!=1 or rows[0][1]!='shadowsocks':raise RuntimeError(f'端口 {port} 不是唯一的 SS 入站（查到 {len(rows)} 条）')
 ident,_,raw=rows[0];cfg=json.loads(raw);cfg.update(password=pw,method=method,network='tcp,udp')
 row=con.execute("SELECT id,value FROM settings WHERE key='xrayTemplateConfig' LIMIT 1").fetchone()
 template=json.loads(row[1]) if row else tmpl
 if not template.get('outbounds') or template['outbounds'][0].get('protocol')!='freedom':raise RuntimeError('第一个出站不是 freedom，拒绝自动修改')
 template['outbounds'][0]['sendThrough']='origin'
 con.execute('UPDATE inbounds SET settings=?,listen=? WHERE id=?',(json.dumps(cfg,ensure_ascii=False),'',ident))
 payload=json.dumps(template,ensure_ascii=False)
 if row:con.execute('UPDATE settings SET value=? WHERE id=?',(payload,row[0]))
 else:con.execute('INSERT INTO settings(key,value) VALUES (?,?)',('xrayTemplateConfig',payload))
 con.commit()
except:con.rollback();raise
finally:con.close()
print('已更新 SS 密码、全网卡监听、origin 出站模板（密码不写入日志）')
PY
# Create links with actual DB credentials; never include secrets in diagnostic file.
python3 - "$DB" "$SS_PORT" "${IPS[@]}" <<'PY'
import sys,sqlite3,json,base64,urllib.parse,os
con=sqlite3.connect(sys.argv[1]);port=int(sys.argv[2]);ips=sys.argv[3:]
row=con.execute("SELECT settings FROM inbounds WHERE port=? AND protocol='shadowsocks'",(port,)).fetchone()
if not row:raise SystemExit('数据库缺少 SS 节点')
s=json.loads(row[0]);pw=s['password'];method=s['method']
token=base64.urlsafe_b64encode((method+':'+pw).encode()).decode().rstrip('=')
links=[];nodes=[]
for i,ip in enumerate(ips,1):
 name=f'美国{i:02d}'
 links.append(f'ss://{token}@{ip}:{port}#{urllib.parse.quote(name)}')
 nodes.append(dict(name=name,type='ss',server=ip,port=port,cipher=method,password=pw,udp=True))
with open('/root/multiip-ss-links.txt','w') as f:f.write('\n'.join(links)+'\n')
with open('/root/multiip-ss-clash.yaml','w') as f:
 f.write('proxies:\n')
 for n in nodes:
  f.write('  - name: '+json.dumps(n['name'],ensure_ascii=False)+'\n')
  for k in ('type','server','port','cipher','password','udp'):
   f.write('    '+k+': '+json.dumps(n[k],ensure_ascii=False)+'\n')
print('\n====== SS 节点链接（含密码，请勿公开）======')
for i,s in enumerate(links,1):print(f'美国{i:02d}: {s}')
print('=========================================')
PY
chmod 600 /root/multiip-ss-links.txt /root/multiip-ss-clash.yaml
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
 ufw allow "${SS_PORT}/tcp" >/dev/null && ufw allow "${SS_PORT}/udp" >/dev/null
fi
systemctl restart x-ui
# Generate a sanitized report from runtime state and an Xray config-test based on DB.
# The synthesized file contains SS secrets and is chmod 600; never print it.
collect_report(){
  {
    echo "=== x-ui / Xray 诊断（可发给技术支持；不含账号、密码、SS 链接） ==="
    date -Is
    echo "检测到的 IP 数量: ${#IPS[@]}"
    echo "SS 端口: $SS_PORT"
    echo "数据库备份: $BACKUP"
    echo '--- x-ui 服务 ---'
    systemctl is-active x-ui || true
    echo '--- Xray 进程（只列名称） ---'
    pgrep -a -f '[/]xray-linux|[/]xray run|[/]xray -config' | sed -E 's@/[^ ]*/xray[^ ]*@xray@g' || true
    echo '--- 实际端口监听 ---'
    ss -H -lntup | awk -v p="$SS_PORT" '$5 ~ (":" p "$") {print}' | sed -E 's/users:\(\([^)]*\)\)/users:(hidden)/g' || true
    echo '--- 数据库结构与入站状态（不输出 settings） ---'
    python3 - "$DB" "$SS_PORT" <<'PY'
import sqlite3,sys,json
c=sqlite3.connect(sys.argv[1]);p=int(sys.argv[2]);
for row in c.execute('SELECT id,port,protocol,enable,listen,settings FROM inbounds WHERE port=?',(p,)):
 i,port,proto,en,listen,raw=row
 try:s=json.loads(raw);network=s.get('network','(未设)');method=s.get('method','(未设)')
 except Exception:network=method='JSON ERROR'
 print('id:',i,'port:',port,'protocol:',proto,'enable:',en,'listen:',repr(listen),'network:',network,'method:',method,'password_set:',bool(s.get('password')))
for k,v in c.execute("SELECT key,value FROM settings WHERE key in ('xrayTemplateConfig','xrayState')"):
 print('setting:',k, 'present:',bool(v),'value:' if k=='xrayState' else 'length:',v if k=='xrayState' else len(v))
c.close()
PY
    echo '--- 核心文件与版本 ---'
    find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray*' -printf '%f %s bytes\n' 2>/dev/null || true
    XRAY=$(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray-linux-*' | head -n1)
    if [[ -n "$XRAY" ]]; then
      "$XRAY" version 2>&1 | head -n 4 || true
    else
      echo '未找到 Xray 可执行文件'
    fi
    echo '--- Xray 配置语法测试（基于数据库合成，完整配置仅在本机） ---'
    if [[ -n "$XRAY" ]]; then
      python3 - "$DB" "$DIAGDIR/xray-check.json" <<'PY'
import sqlite3,sys,json
c=sqlite3.connect(sys.argv[1]);r=c.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
t=json.loads(r[0]) if r else {}
t.setdefault('inbounds',[])
for port,proto,listen,settings,stream,sniff,enable in c.execute('SELECT port,protocol,listen,settings,stream_settings,sniffing,enable FROM inbounds'):
 if not enable:continue
 e={'port':port,'protocol':proto,'settings':json.loads(settings),'tag':f'inbound-{port}'}
 if listen:e['listen']=listen
 if stream:e['streamSettings']=json.loads(stream)
 if sniff:e['sniffing']=json.loads(sniff)
 t['inbounds'].append(e)
c.close()
with open(sys.argv[2],'w') as f:json.dump(t,f)
PY
      chmod 600 "$DIAGDIR/xray-check.json"
      (cd /usr/local/x-ui/bin && "$XRAY" -test -config "$DIAGDIR/xray-check.json") 2>&1 | sed -E 's/wochiniming/[REDACTED]/g' | tail -n 30 || true
    fi
    echo '--- x-ui 最近 60 行日志（过滤常见密钥） ---'
    journalctl -u x-ui -n 60 --no-pager -o cat 2>&1 \
      | sed -E 's/(password|passwd|token|secret|uuid|authorization)[=:][^ ,}]+/\1=[REDACTED]/Ig' \
      | sed -E 's/wochiniming/[REDACTED]/g' || true
    echo '--- 完毕 ---'
  } > "$REPORT" 2>&1
  chmod 600 "$REPORT"
}
READY=0
for i in {1..12}; do
  if pgrep -f '[/]xray-linux|[/]xray run|[/]xray -config' >/dev/null && \
     ss -H -lnt | awk -v p="$SS_PORT" '$4 ~ (":"p"$"){ok=1}END{exit !ok}' && \
     ss -H -lnu | awk -v p="$SS_PORT" '$4 ~ (":"p"$"){ok=1}END{exit !ok}'; then READY=1;break; fi
  sleep 1
done
collect_report
if ((READY));then
  log "Xray 进程存在，TCP/UDP :$SS_PORT 已监听（未验证远端代理连通性）"
  log '诊断日志: /root/x-ui-multiip-diagnostic.log'
  log 'SS 链接: /root/multiip-ss-links.txt'
  log 'OpenClash YAML: /root/multiip-ss-clash.yaml'
  echo '提示：每个 IP 的 TCP 出口仍需客户端实际验证；origin 对 UDP 不保证同源。'
else
  echo "[ERROR] Xray 未启动或 TCP/UDP 端口 $SS_PORT 未全部监听。" >&2
  echo '[ERROR] 诊断日志位于 /root/x-ui-multiip-diagnostic.log' >&2
  echo '[ERROR] 将下面的内容复制给我（发送前仍建议检查是否涉及隐私）：' >&2
  cat "$REPORT"
  exit 1
fi
