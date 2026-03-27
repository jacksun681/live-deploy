#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

CONF="/usr/local/etc/xray/config.json"
ETC_CONF="/etc/xray/config.json"
SYSCTL_CONF="/etc/sysctl.d/99-cast.conf"

DOMAIN="www.cloudflare.com"
PORT="443"
FLOW="xtls-rprx-vision"
MAIN_USER="stream-main"

# 诊断目标：可按你的线路实际情况改
HK_TEST_TARGET="1.1.1.1"
GLOBAL_TEST_TARGET="8.8.8.8"

[[ "$(id -u)" -ne 0 ]] && echo "请用 root 运行" && exit 1

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    apt-get update -yq
    apt-get install -yq \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      "$2"
  }
}

install_deps() {
  need_cmd curl curl
  need_cmd python3 python3
  need_cmd openssl openssl
  need_cmd jq jq
  need_cmd ping iputils-ping
  need_cmd ip iproute2
  need_cmd bc bc
  need_cmd awk gawk
}

install_xray() {
  command -v xray >/dev/null 2>&1 || \
    bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install
}

ensure_conf_link() {
  mkdir -p /etc/xray
  ln -sf "$CONF" "$ETC_CONF"
}

new_uuid() {
  cat /proc/sys/kernel/random/uuid
}

new_short_ids_json() {
python3 - <<'PY'
import json, secrets
print(json.dumps([secrets.token_hex(8) for _ in range(4)]))
PY
}

make_keys() {
  local raw pri pub
  raw="$(xray x25519 2>/dev/null || true)"
  pri="$(echo "$raw" | awk -F': ' '/Private key|PrivateKey/ {print $2}' | head -n1 | tr -d '\r')"
  [[ -z "$pri" ]] && { echo "生成 privateKey 失败"; exit 1; }

  pub="$(xray x25519 -i "$pri" 2>/dev/null | awk -F': ' '/Public key|PublicKey|Password/ {print $2}' | head -n1 | tr -d '\r')"
  [[ -z "$pub" ]] && { echo "推导 publicKey 失败"; exit 1; }

  echo "$pri|$pub"
}

get_public_ip() {
  local ip
  ip="$(curl -4 -s https://api.ipify.org || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -s https://ifconfig.me || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -s https://ip.sb || true)"
  [[ -z "$ip" ]] && ip="$(hostname -I | awk '{print $1}')"
  [[ -z "$ip" ]] && read -rp "请输入公网 IP: " ip
  echo "$ip"
}

test_tcp_jitter() {
  sysctl -w net.ipv4.tcp_congestion_control="$1" >/dev/null 2>&1 || true
  sleep 2
  ping -c 6 -W 2 8.8.8.8 2>/dev/null | awk -F'/' '/rtt|round-trip/ {print $7}'
}

choose_tcp_algo() {
  local available bbr_jitter cubic_jitter
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! echo "$available" | grep -qw bbr; then
    echo "cubic"
    return
  fi

  bbr_jitter="$(test_tcp_jitter bbr)"
  cubic_jitter="$(test_tcp_jitter cubic)"

  if [[ -n "${bbr_jitter:-}" && -n "${cubic_jitter:-}" ]] && (( $(echo "$bbr_jitter <= $cubic_jitter" | bc -l) )); then
    echo "bbr"
  else
    echo "cubic"
  fi
}

write_sysctl() {
  local algo="$1"
  cat >"$SYSCTL_CONF" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$algo
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_no_metrics_save=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.core.netdev_max_backlog=250000
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF

  sysctl --system >/dev/null || true

  local iface
  iface="$(ip route | awk '/default/ {print $5; exit}')"
  [[ -n "${iface:-}" ]] && tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 || true
}

write_new_config() {
  local uuid="$1"
  local pri="$2"
  local shortids_json="$3"

  mkdir -p /usr/local/etc/xray

  cat >"$CONF" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "flow": "$FLOW",
            "email": "$MAIN_USER"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "sockopt": {
          "tcpKeepAliveIdle": 30,
          "tcpKeepAliveInterval": 10
        },
        "realitySettings": {
          "show": false,
          "dest": "$DOMAIN:443",
          "xver": 0,
          "serverNames": ["$DOMAIN"],
          "privateKey": "$pri",
          "shortIds": $shortids_json
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

  ensure_conf_link
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
}

repair_config() {
python3 - <<'PY'
import json, os, sys, subprocess, secrets

conf="/usr/local/etc/xray/config.json"
domain="www.cloudflare.com"
flow="xtls-rprx-vision"

if not os.path.exists(conf):
    sys.exit(2)

with open(conf,"r",encoding="utf-8") as f:
    data=json.load(f)

if "inbounds" not in data or not isinstance(data["inbounds"], list) or not data["inbounds"]:
    sys.exit(3)

changed=False
inb=data["inbounds"][0]

if inb.get("port") != 443:
    inb["port"]=443
    changed=True

if inb.get("protocol") != "vless":
    inb["protocol"]="vless"
    changed=True

settings=inb.get("settings")
if not isinstance(settings, dict):
    settings={}
    inb["settings"]=settings
    changed=True

settings["decryption"]="none"

clients=settings.get("clients")
if not isinstance(clients, list):
    clients=[]
    settings["clients"]=clients
    changed=True

for c in clients:
    if c.get("flow") != flow:
        c["flow"]=flow
        changed=True

ss=inb.get("streamSettings")
if not isinstance(ss, dict):
    ss={}
    inb["streamSettings"]=ss
    changed=True

if ss.get("network") != "tcp":
    ss["network"]="tcp"
    changed=True

if ss.get("security") != "reality":
    ss["security"]="reality"
    changed=True

sockopt=ss.get("sockopt")
if not isinstance(sockopt, dict):
    sockopt={}
    ss["sockopt"]=sockopt
    changed=True

if sockopt.get("tcpKeepAliveIdle") != 30:
    sockopt["tcpKeepAliveIdle"]=30
    changed=True

if sockopt.get("tcpKeepAliveInterval") != 10:
    sockopt["tcpKeepAliveInterval"]=10
    changed=True

rs=ss.get("realitySettings")
if not isinstance(rs, dict):
    rs={}
    ss["realitySettings"]=rs
    changed=True

if rs.get("show") is not False:
    rs["show"]=False
    changed=True

if rs.get("dest") != f"{domain}:443":
    rs["dest"]=f"{domain}:443"
    changed=True

if rs.get("xver") != 0:
    rs["xver"]=0
    changed=True

if rs.get("serverNames") != [domain]:
    rs["serverNames"]=[domain]
    changed=True

pk = rs.get("privateKey")
if not pk:
    raw = subprocess.check_output(["bash","-lc","xray x25519"], text=True)
    pri = ""
    for line in raw.splitlines():
        if "Private key" in line or "PrivateKey" in line:
            pri = line.split(": ",1)[1].strip()
            break
    if not pri:
        print("生成 privateKey 失败")
        sys.exit(4)
    rs["privateKey"] = pri
    changed=True

shortids = rs.get("shortIds")
if not isinstance(shortids, list) or len(shortids) < 1 or not shortids[0]:
    rs["shortIds"]=[secrets.token_hex(8) for _ in range(4)]
    changed=True

with open(conf,"w",encoding="utf-8") as f:
    json.dump(data,f,ensure_ascii=False,indent=2)

sys.exit(0 if changed else 1)
PY
}

ensure_base_config() {
  install_deps
  install_xray

  if [[ ! -f "$CONF" ]]; then
    local algo keys pri uuid shortids_json
    algo="$(choose_tcp_algo)"
    write_sysctl "$algo"

    keys="$(make_keys)"
    pri="${keys%%|*}"
    uuid="$(new_uuid)"
    shortids_json="$(new_short_ids_json)"
    write_new_config "$uuid" "$pri" "$shortids_json"
    return
  fi

  if repair_config; then
    :
  else
    rc=$?
    if [[ "$rc" -eq 2 || "$rc" -eq 3 ]]; then
      rm -f "$CONF"
      local algo keys pri uuid shortids_json
      algo="$(choose_tcp_algo)"
      write_sysctl "$algo"

      keys="$(make_keys)"
      pri="${keys%%|*}"
      uuid="$(new_uuid)"
      shortids_json="$(new_short_ids_json)"
      write_new_config "$uuid" "$pri" "$shortids_json"
      return
    fi
  fi

  ensure_conf_link
  systemctl restart xray
}

get_private_key() {
python3 - <<'PY'
import json
with open("/usr/local/etc/xray/config.json","r",encoding="utf-8") as f:
    data=json.load(f)
print(data["inbounds"][0]["streamSettings"]["realitySettings"].get("privateKey",""))
PY
}

get_short_id() {
python3 - <<'PY'
import json
with open("/usr/local/etc/xray/config.json","r",encoding="utf-8") as f:
    data=json.load(f)
shortids=data["inbounds"][0]["streamSettings"]["realitySettings"].get("shortIds", [])
print(shortids[0] if shortids else "")
PY
}

get_pbk() {
  local pri
  pri="$(get_private_key)"
  [[ -z "$pri" ]] && return 1
  xray x25519 -i "$pri" 2>/dev/null | awk -F': ' '/Public key|PublicKey|Password/ {print $2}' | head -n1 | tr -d '\r'
}

list_users_raw() {
python3 - <<'PY'
import json
with open("/usr/local/etc/xray/config.json","r",encoding="utf-8") as f:
    data=json.load(f)

clients=data["inbounds"][0].get("settings", {}).get("clients", [])
for i,c in enumerate(clients,1):
    print(f"{i}|{c.get('email','user'+str(i))}|{c.get('id','')}|{c.get('flow','xtls-rprx-vision')}")
PY
}

build_link() {
  local uuid="$1"
  local name="$2"
  local flow="$3"
  local ip pbk sid
  ip="$(get_public_ip)"
  pbk="$(get_pbk)"
  sid="$(get_short_id)"
  [[ -z "$pbk" ]] && { echo "生成 pbk 失败"; return 1; }
  [[ -z "$sid" ]] && { echo "shortId 缺失"; return 1; }
  echo "vless://${uuid}@${ip}:${PORT}?encryption=none&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${pbk}&sid=${sid}&flow=${flow}&type=tcp&headerType=none#${name}"
}

ensure_main_user() {
  local count
  count="$(python3 - <<'PY'
import json, os
conf="/usr/local/etc/xray/config.json"
if not os.path.exists(conf):
    print(0)
else:
    with open(conf,"r",encoding="utf-8") as f:
        data=json.load(f)
    clients=data["inbounds"][0].get("settings", {}).get("clients", [])
    print(sum(1 for c in clients if c.get("email")=="stream-main"))
PY
)"
  if [[ "$count" -eq 0 ]]; then
    python3 - "$(new_uuid)" <<'PY'
import json, sys
uuid=sys.argv[1]
conf="/usr/local/etc/xray/config.json"
with open(conf,"r",encoding="utf-8") as f:
    data=json.load(f)

settings = data["inbounds"][0].setdefault("settings", {})
clients = settings.setdefault("clients", [])

clients.insert(0, {
    "id": uuid,
    "flow": "xtls-rprx-vision",
    "email": "stream-main"
})

with open(conf,"w",encoding="utf-8") as f:
    json.dump(data,f,ensure_ascii=False,indent=2)
PY
    ensure_conf_link
    systemctl restart xray
  fi
}

print_main_link() {
  ensure_base_config
  ensure_main_user
  local line idx name uuid flow
  while IFS='|' read -r idx name uuid flow; do
    [[ "$name" != "$MAIN_USER" ]] && continue
    build_link "$uuid" "$name" "$flow"
    return 0
  done < <(list_users_raw)
  echo "未找到主用户"
  return 1
}

print_first_bootstrap() {
  echo
  echo "====== CAST 部署完成 ======"
  echo
  print_main_link
  echo
  echo "管理命令: cast"
  echo
}

show_links() {
  ensure_base_config
  local idx name uuid flow
  while IFS='|' read -r idx name uuid flow; do
    [[ -z "$uuid" ]] && continue
    echo "[$idx] $name"
    build_link "$uuid" "$name" "$flow"
    echo
  done < <(list_users_raw)
}

add_user() {
  ensure_base_config
  local name uuid
  read -rp "请输入新用户名（如 test1）: " name
  [[ -z "$name" ]] && { echo "用户名不能为空"; return; }

  uuid="$(new_uuid)"

python3 - "$name" "$uuid" <<'PY'
import json, sys
name=sys.argv[1]
uuid=sys.argv[2]
conf="/usr/local/etc/xray/config.json"
with open(conf,"r",encoding="utf-8") as f:
    data=json.load(f)

settings = data["inbounds"][0].setdefault("settings", {})
clients = settings.setdefault("clients", [])

for c in clients:
    if c.get("email")==name:
        print("该用户名已存在")
        sys.exit(1)

clients.append({
    "id": uuid,
    "flow": "xtls-rprx-vision",
    "email": name
})

with open(conf,"w",encoding="utf-8") as f:
    json.dump(data,f,ensure_ascii=False,indent=2)
PY

  ensure_conf_link
  systemctl restart xray
  echo
  echo "已新增用户: $name"
  build_link "$uuid" "$name" "$FLOW"
  echo
}

delete_user() {
  ensure_base_config
  local name
  read -rp "请输入要删除的用户名: " name
  [[ -z "$name" ]] && { echo "用户名不能为空"; return; }
  [[ "$name" == "$MAIN_USER" ]] && { echo "主用户不建议删除"; return; }

python3 - "$name" <<'PY'
import json, sys
name=sys.argv[1]
conf="/usr/local/etc/xray/config.json"
with open(conf,"r",encoding="utf-8") as f:
    data=json.load(f)

settings = data["inbounds"][0].setdefault("settings", {})
clients = settings.setdefault("clients", [])

new_clients=[c for c in clients if c.get("email") != name]

if len(new_clients)==len(clients):
    print("未找到该用户")
    sys.exit(1)

if not new_clients:
    print("至少要保留一个用户")
    sys.exit(1)

data["inbounds"][0]["settings"]["clients"]=new_clients
with open(conf,"w",encoding="utf-8") as f:
    json.dump(data,f,ensure_ascii=False,indent=2)
PY

  ensure_conf_link
  systemctl restart xray
  echo "已删除用户: $name"
}

reset_user() {
  ensure_base_config
  local name uuid
  read -rp "请输入要重置的用户名: " name
  [[ -z "$name" ]] && { echo "用户名不能为空"; return; }

  uuid="$(new_uuid)"

python3 - "$name" "$uuid" <<'PY'
import json, sys
name=sys.argv[1]
uuid=sys.argv[2]
conf="/usr/local/etc/xray/config.json"
with open(conf,"r",encoding="utf-8") as f:
    data=json.load(f)

settings = data["inbounds"][0].setdefault("settings", {})
clients = settings.setdefault("clients", [])

found=False
for c in clients:
    if c.get("email")==name:
        c["id"]=uuid
        c["flow"]="xtls-rprx-vision"
        found=True
        break

if not found:
    print("未找到该用户")
    sys.exit(1)

with open(conf,"w",encoding="utf-8") as f:
    json.dump(data,f,ensure_ascii=False,indent=2)
PY

  ensure_conf_link
  systemctl restart xray
  echo
  echo "已重置用户: $name"
  build_link "$uuid" "$name" "$FLOW"
  echo
}

show_status() {
  systemctl status xray --no-pager -l
}

show_summary() {
  ensure_base_config
  local ip users sid_count
  ip="$(get_public_ip)"
  users="$(list_users_raw | wc -l | awk '{print $1}')"
  sid_count="$(python3 - <<'PY'
import json
with open("/usr/local/etc/xray/config.json","r",encoding="utf-8") as f:
    data=json.load(f)
print(len(data["inbounds"][0]["streamSettings"]["realitySettings"].get("shortIds", [])))
PY
)"
  echo "节点IP: $ip"
  echo "端口: $PORT"
  echo "主用户: $MAIN_USER"
  echo "用户总数: $users"
  echo "shortId数量: $sid_count"
  echo "服务状态: $(systemctl is-active xray 2>/dev/null || true)"
}

probe_target() {
  local target="$1"
  local count="${2:-6}"
  local interval="${3:-5}"
  local label="$4"

  local out_file
  out_file="$(mktemp)"
  local ok=0 fail=0

  for _ in $(seq 1 "$count"); do
    local line
    line="$(ping -c 1 -W 2 "$target" 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}' || true)"
    if [[ -n "$line" ]]; then
      echo "$line" >> "$out_file"
      ok=$((ok+1))
    else
      fail=$((fail+1))
    fi
    sleep "$interval"
  done

  local stats
  stats="$(python3 - "$out_file" "$ok" "$fail" "$label" <<'PY'
import sys, statistics
path, ok, fail, label = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
vals=[]
with open(path,"r",encoding="utf-8") as f:
    for line in f:
        line=line.strip()
        if line:
            vals.append(float(line))
loss = 0.0
total = ok + fail
if total > 0:
    loss = fail * 100.0 / total
if vals:
    avg = sum(vals)/len(vals)
    mn = min(vals)
    mx = max(vals)
    jitter = statistics.pstdev(vals) if len(vals) > 1 else 0.0
    print(f"{label}|{avg:.1f}|{mn:.1f}|{mx:.1f}|{loss:.1f}|{jitter:.1f}")
else:
    print(f"{label}|0.0|0.0|0.0|100.0|0.0")
PY
)"
  rm -f "$out_file"
  echo "$stats"
}

diagnose_conclusion() {
  local xray_ok="$1" port_ok="$2" cpu="$3" mem="$4" hk_loss="$5" hk_jit="$6" gl_loss="$7" gl_jit="$8"

  if [[ "$xray_ok" != "running" || "$port_ok" != "yes" ]]; then
    echo "结论: 节点服务异常"
    echo "推测: 当前问题主要来自服务器侧"
    return
  fi

  if (( cpu >= 90 )) || (( mem >= 90 )); then
    echo "结论: 系统资源异常"
    echo "推测: 当前卡顿更像服务器负载过高"
    return
  fi

  if (( $(echo "$hk_loss >= 5 || $hk_jit >= 20" | bc -l) )); then
    echo "结论: 接入段波动明显"
    echo "推测: 更像前段到节点链路不稳"
    return
  fi

  if (( $(echo "$gl_loss >= 5 || $gl_jit >= 25" | bc -l) )); then
    echo "结论: 出口段波动明显"
    echo "推测: 更像节点到目标平台方向不稳"
    return
  fi

  echo "结论: 节点侧整体正常"
  echo "推测: 更像本地推流端、OBS编码或平台侧波动"
}

doctor() {
  ensure_base_config
  clear
  echo "=============================="
  echo "        CAST DOCTOR"
  echo "=============================="
  echo
  echo "[1] 服务状态"

  local xray_state port_ok cfg_ok
  xray_state="$(systemctl is-active xray 2>/dev/null || true)"
  if ss -lntp 2>/dev/null | grep -q ":${PORT} "; then
    port_ok="yes"
  else
    port_ok="no"
  fi

  if jq -e '.inbounds[0].streamSettings.realitySettings.privateKey and .inbounds[0].settings.clients' "$CONF" >/dev/null 2>&1; then
    cfg_ok="正常"
  else
    cfg_ok="异常"
  fi

  echo "Xray: $xray_state"
  echo "监听端口: $PORT ($port_ok)"
  echo "配置完整: $cfg_ok"
  echo "主用户: $MAIN_USER"
  echo

  echo "[2] 系统状态"
  local cpu mem load disk conn_count
  cpu="$(top -bn1 | awk -F'id,' '/Cpu\(s\)/{gsub(/ /,"",$1); split($1,a,","); split(a[length(a)],b,"."); print 100-b[1] }' | head -n1)"
  [[ -z "${cpu:-}" ]] && cpu=0
  mem="$(free | awk '/Mem:/{printf("%d", $3*100/$2)}')"
  load="$(awk '{print $1" "$2" "$3}' /proc/loadavg)"
  disk="$(df -h / | awk 'NR==2{print $5}')"
  conn_count="$(ss -tn state established 2>/dev/null | tail -n +2 | wc -l | awk '{print $1}')"

  echo "CPU: ${cpu}%"
  echo "内存: ${mem}%"
  echo "负载: $load"
  echo "磁盘: $disk"
  echo "当前连接数: $conn_count"
  echo

  echo "[3] 链路采样（约60秒）"
  local hk_stats gl_stats
  hk_stats="$(probe_target "$HK_TEST_TARGET" 6 5 "香港链路")"
  gl_stats="$(probe_target "$GLOBAL_TEST_TARGET" 6 5 "全球出口")"

  IFS='|' read -r hk_label hk_avg hk_min hk_max hk_loss hk_jit <<< "$hk_stats"
  IFS='|' read -r gl_label gl_avg gl_min gl_max gl_loss gl_jit <<< "$gl_stats"

  echo "${hk_label}:"
  echo "  平均延迟: ${hk_avg} ms"
  echo "  最大延迟: ${hk_max} ms"
  echo "  丢包: ${hk_loss}%"
  echo "  抖动: ${hk_jit} ms"
  echo
  echo "${gl_label}:"
  echo "  平均延迟: ${gl_avg} ms"
  echo "  最大延迟: ${gl_max} ms"
  echo "  丢包: ${gl_loss}%"
  echo "  抖动: ${gl_jit} ms"
  echo

  echo "[4] 诊断结论"
  diagnose_conclusion "$xray_state" "$port_ok" "$cpu" "$mem" "$hk_loss" "$hk_jit" "$gl_loss" "$gl_jit"
  echo
}

watch_once() {
  local xray_state cpu mem conn_count hk_stats gl_stats hk_avg hk_loss hk_jit gl_avg gl_loss gl_jit
  xray_state="$(systemctl is-active xray 2>/dev/null || true)"
  cpu="$(top -bn1 | awk -F'id,' '/Cpu\(s\)/{gsub(/ /,"",$1); split($1,a,","); split(a[length(a)],b,"."); print 100-b[1] }' | head -n1)"
  [[ -z "${cpu:-}" ]] && cpu=0
  mem="$(free | awk '/Mem:/{printf("%d", $3*100/$2)}')"
  conn_count="$(ss -tn state established 2>/dev/null | tail -n +2 | wc -l | awk '{print $1}')"

  hk_stats="$(probe_target "$HK_TEST_TARGET" 2 1 "香港")"
  gl_stats="$(probe_target "$GLOBAL_TEST_TARGET" 2 1 "全球")"

  IFS='|' read -r _ hk_avg _ _ hk_loss hk_jit <<< "$hk_stats"
  IFS='|' read -r _ gl_avg _ _ gl_loss gl_jit <<< "$gl_stats"

  local verdict
  if [[ "$xray_state" != "running" ]]; then
    verdict="服务异常"
  elif (( $(echo "$hk_loss >= 5 || $hk_jit >= 20" | bc -l) )); then
    verdict="香港链路波动"
  elif (( $(echo "$gl_loss >= 5 || $gl_jit >= 25" | bc -l) )); then
    verdict="全球出口波动"
  elif (( cpu >= 90 )) || (( mem >= 90 )); then
    verdict="资源异常"
  else
    verdict="正常"
  fi

  clear
  echo "=============================="
  echo "         CAST WATCH"
  echo "=============================="
  echo
  echo "时间: $(date '+%F %T')"
  echo
  echo "Xray: $xray_state"
  echo "CPU: ${cpu}%"
  echo "内存: ${mem}%"
  echo "连接数: $conn_count"
  echo
  echo "香港: ${hk_avg}ms / loss ${hk_loss}% / jitter ${hk_jit}ms"
  echo "全球: ${gl_avg}ms / loss ${gl_loss}% / jitter ${gl_jit}ms"
  echo
  echo "状态: $verdict"
  echo
  echo "按 Ctrl + C 退出"
}

watch_loop() {
  ensure_base_config
  while true; do
    watch_once
    sleep 5
  done
}

menu_ui() {
  clear
  cat <<EOF
==============================
      CAST 直播管理菜单
==============================
1. 修复/初始化
2. 查看主链接
3. 查看全部链接
4. 新增用户
5. 删除用户
6. 重置用户
7. 节点状态
8. 一次性诊断
9. 实时监控
0. 退出
==============================
EOF

  read -rp "请选择: " choice
  case "$choice" in
    1) ensure_base_config; ensure_main_user; echo "配置已修复/初始化" ;;
    2) print_main_link ;;
    3) show_links ;;
    4) add_user ;;
    5) delete_user ;;
    6) reset_user ;;
    7) show_summary ;;
    8) doctor ;;
    9) watch_loop ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
}

case "${1:-}" in
  --bootstrap)
    ensure_base_config
    ensure_main_user
    print_first_bootstrap
    exit 0
    ;;
  doctor)
    doctor
    exit 0
    ;;
  watch)
    watch_loop
    exit 0
    ;;
esac

while true; do
  menu_ui
  echo
  read -rp "按回车返回菜单..." _
done