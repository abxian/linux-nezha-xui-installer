#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
# vaxilu/x-ui 0.3.2: one SS inbound, many client IP endpoints, origin egress.
UPSTREAM='https://raw.githubusercontent.com/abxian/linux-nezha-xui-installer/main/install.sh'
PANEL_USER="${XUI_USERNAME:-wochiniming}"
PANEL_PASS="${XUI_PASSWORD:-wochiniming}"
PANEL_PORT="${XUI_PANEL_PORT:-18181}"
SS_PORT="${SS_PORT:-80}"
SS_METHOD="${SS_METHOD:-aes-256-gcm}"
SS_PASSWORD="${SS_PASSWORD:-wochiniming}"
for ((i=1;i<=$#;i++)); do :; done
while (($#)); do
  case "$1" in
    --username) PANEL_USER="$2"; shift 2;;
    --password) PANEL_PASS="$2"; shift 2;;
    --panel-port) PANEL_PORT="$2"; shift 2;;
    --ss-port) SS_PORT="$2"; shift 2;;
    --ss-method) SS_METHOD="$2"; shift 2;;
    --ss-password) SS_PASSWORD="$2"; shift 2;;
    *) echo "未知选项: $1" >&2; exit 1;;
  esac
done
[[ $EUID -eq 0 ]] || { echo '请使用 sudo bash 运行' >&2; exit 1; }
for c in python3 curl ip systemctl awk; do command -v "$c" >/dev/null || { echo "缺少命令: $c" >&2; exit 1; }; done
[[ "$PANEL_PORT" =~ ^[0-9]+$ && "$SS_PORT" =~ ^[0-9]+$ ]] || { echo '端口必须为数字' >&2; exit 1; }
(( PANEL_PORT>=1 && PANEL_PORT<=65535 && SS_PORT>=1 && SS_PORT<=65535 && PANEL_PORT!=SS_PORT )) || { echo '端口范围或冲突错误' >&2; exit 1; }
case "$SS_METHOD" in aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305) ;; *) echo '不支持加密方式' >&2; exit 1;; esac
export PANEL_USER PANEL_PASS PANEL_PORT SS_PORT SS_METHOD SS_PASSWORD
mapfile -t IPS < <(ip -o -4 addr show scope global | awk '{split($4,a,"/");print a[1]}' | sort -u | python3 -c 'import sys,ipaddress;print("\n".join(ip for x in sys.stdin if (ip:=x.strip()) and ipaddress.ip_address(ip).is_global))')
((${#IPS[@]})) || { echo '没有检测到绑定在网卡上的公网 IPv4。执行 ip -4 addr 排查。' >&2; exit 1; }
printf '本地网卡公网 IP (%d): %s\n' "${#IPS[@]}" "${IPS[*]}"
for addr in "${IPS[@]}"; do
  actual=$(curl -4fsS --interface "$addr" --connect-timeout 4 --max-time 10 https://api.ipify.org 2>/dev/null || true)
  if [[ "$actual" == "$addr" ]]; then echo "源地址出站测试通过: $addr";
  else echo "警告: $addr 不能从该 IP 出站（查询结果: ${actual:-失败}），对应节点可能无法联网。" >&2; fi
done
DB='/etc/x-ui/x-ui.db'
if [[ ! -x /usr/local/x-ui/x-ui ]]; then
  echo '未安装 x-ui：运行原仓库安装程序，显式传递统一 SS 密码。'
  temp=$(mktemp -d); trap 'rm -rf "$temp"' EXIT
  curl -fsSL --retry 3 "$UPSTREAM" -o "$temp/upstream.sh"
  SS_PASSWORD="$SS_PASSWORD" bash "$temp/upstream.sh" --username "$PANEL_USER" --password "$PANEL_PASS" --panel-port "$PANEL_PORT" --ss-port "$SS_PORT" --ss-method "$SS_METHOD" --ss-password "$SS_PASSWORD" --public-host "${IPS[0]}"
else
  echo '检测到现有 x-ui：保留安装，修改目标 SS 入站和 Xray 模板。'
fi
[[ -f "$DB" ]] || { echo "找不到 x-ui 数据库: $DB" >&2; exit 1; }
mkdir -p /root/x-ui-backups
BACKUP="/root/x-ui-backups/x-ui-$(date +%Y%m%d-%H%M%S).db"
python3 - "$DB" "$BACKUP" <<'PY'
import sqlite3,sys
src=sqlite3.connect(sys.argv[1]); dst=sqlite3.connect(sys.argv[2]);src.backup(dst);dst.close();src.close()
PY
echo "已备份数据库: $BACKUP"
python3 - "$DB" <<'PY'
import os,json,sqlite3,sys
port=int(os.environ['SS_PORT']); password=os.environ['SS_PASSWORD']; method=os.environ['SS_METHOD']
db=sqlite3.connect(sys.argv[1]);db.execute('BEGIN IMMEDIATE')
try:
    rows=db.execute('SELECT id,port,protocol,settings FROM inbounds WHERE port=?',(port,)).fetchall()
    if len(rows)!=1 or rows[0][2]!='shadowsocks':
        raise RuntimeError(f'未找到唯一的 Shadowsocks :{port} 入站（找到 {len(rows)} 条）；为避免修改错误节点，请检查面板')
    inbound_id,_,_,settings=rows[0]
    cfg=json.loads(settings); cfg['method']=method;cfg['password']=password;cfg['network']='tcp,udp'
    db.execute('UPDATE inbounds SET settings=?, listen=? WHERE id=?',(json.dumps(cfg,ensure_ascii=False,separators=(',',':')),'',inbound_id))
    r=db.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    if r is None: raise RuntimeError('x-ui 缺少 xrayTemplateConfig，未修改；检查版本')
    template=json.loads(r[0]);outbounds=template.get('outbounds',[])
    if not outbounds: raise RuntimeError('Xray 模板没有默认出站')
    # The default (first) outbound is the fallback; the one-port SS inbound uses it.
    first=outbounds[0]
    if first.get('protocol')!='freedom': raise RuntimeError('模板第一个出站不是 freedom，拒绝自动更改')
    first['sendThrough']='origin'
    first.setdefault('settings',{})
    # Do not overwrite existing routing, API, or blocking settings.
    db.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'",(json.dumps(template,ensure_ascii=False,separators=(',',':')),))
    db.commit()
except Exception:
    db.rollback();raise
finally:
    db.close()
print(f'已配置 SS 入站端口 {port}，密码固定；默认 freedom 出站 sendThrough=origin')
PY
systemctl restart x-ui
systemctl is-active --quiet x-ui || { echo "x-ui 服务没有启动。备份: $BACKUP" >&2; exit 1; }
# Generate URIs and Clash profiles (the same credentials, different server IPs).
printf '%s\n' "${IPS[@]}" | python3 -c '
import os,sys,json,base64,ipaddress
ips=[x.strip() for x in sys.stdin if x.strip()]
p=os.environ["SS_PASSWORD"]; port=int(os.environ["SS_PORT"]);method=os.environ["SS_METHOD"]
uri=[];node=[]
for idx,ip in enumerate(ips,1):
    name=f"美国{idx:02d}"
    token=base64.urlsafe_b64encode(f"{method}:{p}".encode()).decode().rstrip("=")
    uri.append(f"{name}: ss://{token}@{ip}:{port}#{name}")
    node.append(dict(name=name,type="ss",server=ip,port=port,cipher=method,password=p,udp=True))
open("/root/multiip-ss-links.txt","w").write("\n".join(uri)+"\n")
# Valid Clash YAML with quoted password and names.
with open("/root/multiip-ss-clash.yaml","w") as f:
    f.write("proxies:\n")
    for n in node:
        f.write("  - name: "+json.dumps(n["name"],ensure_ascii=False)+"\n")
        for key in ("type","server","port","cipher","password","udp"):
            f.write(f"    {key}: {json.dumps(n[key],ensure_ascii=False)}\n")
print("\n".join(uri))
'
chmod 600 /root/multiip-ss-links.txt /root/multiip-ss-clash.yaml
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then ufw allow "$SS_PORT/tcp"; ufw allow "$SS_PORT/udp"; fi
printf '\n完成。SS 密码: %s；共 %s 个公网 IP，共用端口 %s\n' "$SS_PASSWORD" "${#IPS[@]}" "$SS_PORT"
printf 'SS 链接: /root/multiip-ss-links.txt\nClash YAML: /root/multiip-ss-clash.yaml\n'
echo '注意: origin 依赖 Xray 版本及宿主机路由；请逐个测试出口，UDP 不保证沿用相同源地址。'
