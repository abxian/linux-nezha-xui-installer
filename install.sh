#!/usr/bin/env bash
# BUILD: MULTIIP-ARCHIVE-FIX-20261019-R2
# Fresh legacy x-ui 0.3.2 + recent Xray; multi-IP one-port Shadowsocks.
set -Eeuo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive
PANEL_USER="${XUI_USERNAME:-wochiniming}"
PANEL_PASS="${XUI_PASSWORD:-wochiniming}"
PANEL_PORT="${XUI_PANEL_PORT:-18181}"
SS_PASS="${SS_PASSWORD:-wochiniming}"
SS_PORT="${SS_PORT:-80}"
SS_METHOD="aes-256-gcm"
XUI_VERSION="0.3.2"
DB=/etc/x-ui/x-ui.db
WORK="$(mktemp -d /tmp/xui-install.XXXXXXXX)"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/root/x-ui-reinstall-backup-$STAMP"
LOG=/root/x-ui-multiip-diagnostic.log
COMMITTED=0
MUTATED=0
ORIGINAL_SERVICE=0
[[ $EUID -eq 0 ]] || { echo '请以 root 身份运行' >&2; exit 1; }
for n in PANEL_PORT SS_PORT; do v="${!n}"; [[ "$v" =~ ^[0-9]+$ ]] && ((10#$v>0 && 10#$v<=65535)) || { echo "$n 无效" >&2; exit 1; }; done
[[ "$PANEL_PORT" != "$SS_PORT" ]] || { echo '面板端口不能与 SS 端口相同' >&2; exit 1; }
[[ "$PANEL_USER" != *$'\n'* && "$PANEL_PASS" != *$'\n'* && "$SS_PASS" != *$'\n'* ]] || { echo '账号密码不能包含换行符' >&2; exit 1; }
command -v apt-get >/dev/null || { echo '目前仅支持 Debian/Ubuntu apt 系统' >&2; exit 1; }
ARCH="$(uname -m)"
case "$ARCH" in x86_64|amd64) XUI_ARCH=amd64; XRAY_ARCH=64;; aarch64|arm64) XUI_ARCH=arm64; XRAY_ARCH=arm64-v8a;; *) echo "不支持的架构: $ARCH" >&2; exit 1;; esac
mkdir -p "$BACKUP"
report() {
  {
    echo '=== x-ui/Xray 诊断（不含密码和 SS URI） ==='
    date -Is
    echo '-- 服务 --'; systemctl is-active x-ui || :
    echo '-- 核心版本 --'; /usr/local/x-ui/bin/xray-linux-${XUI_ARCH} version 2>&1 | head -n 3 || :
    echo '-- 进程 --'; pgrep -af '/usr/local/x-ui/bin/xray|xray-linux' 2>/dev/null | sed -E 's/ -config .*/ [config omitted]/' || :
    echo '-- 监听端口 --'; ss -H -lntup 2>/dev/null | awk -v p=":${SS_PORT}" '$5 ~ (p"$") {print $1, $5}' || :
    echo '-- Xray 语法验证 --';
    if [[ -s "$WORK/validation.json" && -x /usr/local/x-ui/bin/xray-linux-${XUI_ARCH} ]]; then
      /usr/local/x-ui/bin/xray-linux-${XUI_ARCH} run -test -config "$WORK/validation.json" 2>&1 | head -n 25 || :
    fi
    echo '-- x-ui 最近日志（过滤密码及 URL） --';
    journalctl -u x-ui -n 35 --no-pager -o cat 2>/dev/null | sed -E 's#ss://[^ ]+#[SS-URI-REDACTED]#g;s/(password|passwd|token|secret)[=:][^ ,]+/\1=[REDACTED]/Ig' || :
    echo '-- 备份目录 --'; echo "$BACKUP"
  } > "$LOG"
}
rollback() {
  code=$?
  trap - ERR EXIT
  if (( code != 0 && COMMITTED == 0 && MUTATED == 1 )); then
    echo "[ERROR] 安装失败，尝试恢复旧版。备份: $BACKUP" >&2
    report || :
    systemctl stop x-ui >/dev/null 2>&1 || :
    rm -rf /usr/local/x-ui
    if [[ -d "$BACKUP/x-ui" ]]; then cp -a "$BACKUP/x-ui" /usr/local/x-ui; fi
    if [[ -d "$BACKUP/etc-x-ui" ]]; then rm -rf /etc/x-ui; cp -a "$BACKUP/etc-x-ui" /etc/x-ui; fi
    if [[ -f "$BACKUP/x-ui.service" ]]; then cp -a "$BACKUP/x-ui.service" /etc/systemd/system/x-ui.service; else rm -f /etc/systemd/system/x-ui.service; fi
    if [[ -f "$BACKUP/x-ui-cli" ]]; then cp -a "$BACKUP/x-ui-cli" /usr/bin/x-ui; else rm -f /usr/bin/x-ui; fi
    systemctl daemon-reload || :
    if (( ORIGINAL_SERVICE )); then systemctl restart x-ui || :; fi
    echo "[ERROR] 诊断日志: $LOG" >&2
    cat "$LOG" >&2 || :
  elif (( code != 0 )); then
    {
      echo '=== 安装预检查失败（未修改旧安装） ==='
      date -Is
      echo "退出码: $code"
      echo "旧安装未被卸载或修改"
      if [[ -f "$WORK/xui-entries.txt" ]]; then
        echo '--- x-ui 压缩包条目前 30 行 ---'
        head -n 30 "$WORK/xui-entries.txt"
      fi
      if [[ -f "$WORK/release.json" ]]; then
        echo '--- Xray 版本 ---'
        python3 - "$WORK/release.json" <<'PY_JSON' || :
import json,sys
try: print(json.load(open(sys.argv[1])).get('tag_name','unknown'))
except Exception: print('invalid release JSON')
PY_JSON
      fi
    } > "$LOG"
    echo "[ERROR] 安装尚未修改旧安装，退出码: $code；新诊断日志: $LOG" >&2
  fi
  rm -rf "$WORK"
  exit "$code"
}
trap rollback ERR EXIT

echo '[installer] BUILD: MULTIIP-ARCHIVE-FIX-20261019-R2'
echo '[1/7] 安装依赖并检测公网 IP'
apt-get update -qq
apt-get install -y -qq curl ca-certificates unzip tar python3 iproute2 procps >/dev/null
mapfile -t IPS < <(ip -o -4 addr show scope global | python3 -c 'import sys,ipaddress; a=set();[(a.add(x.split()[3].split("/")[0])) for x in sys.stdin]; print("\n".join(sorted((x for x in a if ipaddress.ip_address(x).is_global),key=lambda s:tuple(map(int,s.split("."))))))')
((${#IPS[@]})) || { echo '网卡没有检测到公网 IPv4' >&2; exit 1; }
printf '检测到 %s 个公网 IP: %s\n' "${#IPS[@]}" "${IPS[*]}"
for addr in "${IPS[@]}"; do
  ext="$(curl -4fsS --interface "$addr" --connect-timeout 4 --max-time 10 https://api.ipify.org || :)"
  [[ "$ext" == "$addr" ]] || { echo "[ERROR] $addr 源地址公网测试失败（返回 ${ext:-空}），终止以避免不可用节点" >&2; exit 1; }
  echo "源地址测试通过: $addr"
done

echo '[2/7] 下载并验证安装包（此阶段不会卸载旧版）'
curl -fL --retry 3 -o "$WORK/xui.tar.gz" "https://github.com/vaxilu/x-ui/releases/download/${XUI_VERSION}/x-ui-linux-${XUI_ARCH}.tar.gz"
# Validate that the archive is readable, extract it, then check files on disk.
# Tar entries may be prefixed with ./; exact matching against tar -t output
# incorrectly rejects valid archives.
if ! tar -tzf "$WORK/xui.tar.gz" > "$WORK/xui-entries.txt"; then
  echo '[ERROR] x-ui 压缩包不能正常读取' >&2
  exit 1
fi
if ! tar -xzf "$WORK/xui.tar.gz" -C "$WORK"; then
  echo '[ERROR] x-ui 压缩包解压失败' >&2
  exit 1
fi
if [[ ! -f "$WORK/x-ui/x-ui" || ! -f "$WORK/x-ui/x-ui.service" || ! -d "$WORK/x-ui/bin" ]]; then
  echo '[ERROR] 解压后找不到 x-ui 核心文件。压缩包前 30 个条目:' >&2
  head -n 30 "$WORK/xui-entries.txt" >&2
  exit 1
fi

# Use github API to find current stable Xray release (latest non-prerelease).
curl -fLsS --retry 3 https://api.github.com/repos/XTLS/Xray-core/releases/latest -o "$WORK/release.json"
XRAY_VERSION="$(python3 - "$WORK/release.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); print(x['tag_name'])
PY
)"
[[ "$XRAY_VERSION" == v* ]] || { echo '无法读取有效 Xray release' >&2; exit 1; }
echo "准备安装 Xray $XRAY_VERSION"
curl -fL --retry 3 -o "$WORK/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
unzip -p "$WORK/xray.zip" xray > "$WORK/xray-new"
chmod 755 "$WORK/xray-new"
"$WORK/xray-new" version | head -n 1

# Backup existing installation fully before replacing anything.
echo '[3/7] 备份并移除旧面板及旧数据库'
systemctl is-active --quiet x-ui && ORIGINAL_SERVICE=1 || :
[[ ! -d /usr/local/x-ui ]] || cp -a /usr/local/x-ui "$BACKUP/x-ui"
[[ ! -d /etc/x-ui ]] || cp -a /etc/x-ui "$BACKUP/etc-x-ui"
[[ ! -f /etc/systemd/system/x-ui.service ]] || cp -a /etc/systemd/system/x-ui.service "$BACKUP/x-ui.service"
[[ ! -f /usr/bin/x-ui ]] || cp -a /usr/bin/x-ui "$BACKUP/x-ui-cli"
MUTATED=1
systemctl stop x-ui >/dev/null 2>&1 || :
systemctl disable x-ui >/dev/null 2>&1 || :
rm -rf /usr/local/x-ui /etc/x-ui
mkdir -p /usr/local/x-ui /etc/x-ui
cp -a "$WORK/x-ui/." /usr/local/x-ui/
install -m755 "$WORK/xray-new" "/usr/local/x-ui/bin/xray-linux-${XUI_ARCH}"
chmod +x /usr/local/x-ui/x-ui
cp /usr/local/x-ui/x-ui.service /etc/systemd/system/x-ui.service
cp /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
chmod +x /usr/bin/x-ui
systemctl daemon-reload

# Ensure DB initializes using the panel binary, not guessed SQLite schema.
echo '[4/7] 初始化新 x-ui 面板与 SS 入站'
/usr/local/x-ui/x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS"
/usr/local/x-ui/x-ui setting -port "$PANEL_PORT"
export SS_PORT SS_PASS SS_METHOD
# x-ui 0.3.2 may initialize database on CLI setting, but assert existence.
[[ -f "$DB" ]] || { echo "找不到数据库 $DB" >&2; exit 1; }
python3 - "$DB" <<'PY'
import os,sys,sqlite3,json
p=int(os.environ['SS_PORT']); pw=os.environ['SS_PASS']; method=os.environ['SS_METHOD']
con=sqlite3.connect(sys.argv[1]);con.execute('BEGIN IMMEDIATE')
try:
    cols=[row[1] for row in con.execute('PRAGMA table_info(inbounds)')]
    # Handle legacy schema with column introspection, avoid guessed positional inserts.
    payload={'user_id':1,'up':0,'down':0,'total':0,'remark':'multiip-ss','enable':1,
             'expiry_time':0,'listen':'','port':p,'protocol':'shadowsocks',
             'settings':json.dumps({'method':method,'password':pw,'network':'tcp,udp'},separators=(',',':')),
             'stream_settings':'{}','tag':f'inbound-{p}',
             'sniffing':json.dumps({'enabled':False,'destOverride':['http','tls']},separators=(',',':'))}
    use={k:v for k,v in payload.items() if k in cols}
    if not {'port','protocol','settings','enable'} <= set(use):raise RuntimeError(f'未知数据库结构: {cols}')
    con.execute(f'INSERT INTO inbounds ({",".join(use)}) VALUES ({",".join("?" for _ in use)})',tuple(use.values()))
    template={'api':{'services':['HandlerService','LoggerService','StatsService'],'tag':'api'},
      'inbounds':[{'listen':'127.0.0.1','port':62789,'protocol':'dokodemo-door','settings':{'address':'127.0.0.1'},'tag':'api'}],
      'outbounds':[{'protocol':'freedom','sendThrough':'origin','settings':{},'tag':'direct'},
                  {'protocol':'blackhole','settings':{},'tag':'blocked'}],
      'routing':{'rules':[{'inboundTag':['api'],'outboundTag':'api','type':'field'},
                            {'ip':['geoip:private'],'outboundTag':'blocked','type':'field'},
                            {'outboundTag':'blocked','protocol':['bittorrent'],'type':'field'}]},
      'policy':{'system':{'statsInboundDownlink':True,'statsInboundUplink':True}},'stats':{}}
    con.execute("DELETE FROM settings WHERE key='xrayTemplateConfig'")
    con.execute('INSERT INTO settings(key,value) VALUES(?,?)',('xrayTemplateConfig',json.dumps(template,separators=(',',':'))))
    con.commit()
except: con.rollback();raise
finally: con.close()
PY

# Check core accepts the entire config before starting service.
echo '[5/7] 校验 Xray 配置'
python3 - "$DB" "$WORK/validation.json" <<'PY'
import sqlite3,json,sys
con=sqlite3.connect(sys.argv[1]); row=con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone(); cfg=json.loads(row[0]);
for (port,proto,sett,listen,tag,stream,sniff) in con.execute('SELECT port,protocol,settings,listen,tag,stream_settings,sniffing FROM inbounds WHERE enable=1'):
    x={'port':port,'protocol':proto,'settings':json.loads(sett),'tag':tag or f'inbound-{port}'}
    if listen:x['listen']=listen
    if stream:x['streamSettings']=json.loads(stream)
    if sniff:x['sniffing']=json.loads(sniff)
    cfg['inbounds'].append(x)
open(sys.argv[2],'w').write(json.dumps(cfg))
PY
"/usr/local/x-ui/bin/xray-linux-${XUI_ARCH}" run -test -config "$WORK/validation.json"

echo '[6/7] 启动并检测 Xray、TCP/UDP 监听'
systemctl enable x-ui >/dev/null
systemctl restart x-ui
sleep 3
systemctl is-active --quiet x-ui || { echo 'x-ui 未运行'; exit 1; }
# A panel can be active while its Xray process has crashed.
pgrep -f 'xray-linux-' >/dev/null || { echo '[ERROR] Xray 进程未启动'; exit 1; }
ss -H -lnt "( sport = :${SS_PORT} )" | grep -q . || { echo '[ERROR] TCP ${SS_PORT} 未监听'; exit 1; }
ss -H -lnu "( sport = :${SS_PORT} )" | grep -q . || { echo '[ERROR] UDP ${SS_PORT} 未监听'; exit 1; }

# Only write links after service actually starts.
echo '[7/7] 输出 SS 节点与 OpenClash YAML'
# pass IPs as argv (stdin is used by the python program itself)
python3 - "${IPS[@]}" <<'PY'
import sys,os,json,base64,urllib.parse
ips=sys.argv[1:]; port=int(os.environ['SS_PORT']); pw=os.environ['SS_PASS']; method=os.environ['SS_METHOD']
creds=base64.urlsafe_b64encode(f'{method}:{pw}'.encode()).decode().rstrip('=')
with open('/root/multiip-ss-links.txt','w') as a,open('/root/multiip-ss-clash.yaml','w') as b:
    b.write('proxies:\n')
    for i,ip in enumerate(ips,1):
        name=f'美国{i:02d}'
        a.write(f'{name}: ss://{creds}@{ip}:{port}#{urllib.parse.quote(name)}\n')
        node={'name':name,'type':'ss','server':ip,'port':port,'cipher':method,'password':pw,'udp':True}
        b.write('  - '+json.dumps(node,ensure_ascii=False,separators=(',',':'))+'\n')
PY
chmod 600 /root/multiip-ss-links.txt /root/multiip-ss-clash.yaml
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow "${SS_PORT}/tcp" >/dev/null; ufw allow "${SS_PORT}/udp" >/dev/null; ufw allow "${PANEL_PORT}/tcp" >/dev/null
fi
COMMITTED=1
report
printf '\n===== 已启动：SS 链接（包含密码，勿公开）=====\n'
cat /root/multiip-ss-links.txt
printf '\n面板端口: %s；SS 端口: %s；Xray: %s\n' "$PANEL_PORT" "$SS_PORT" "$XRAY_VERSION"
printf 'OpenClash: /root/multiip-ss-clash.yaml\n诊断日志: %s\n旧版备份: %s\n' "$LOG" "$BACKUP"
echo '注意：TCP/UDP 端口监听成功不保证 UDP 源地址按对应公网 IP 出站；请用客户端分别验证。'
