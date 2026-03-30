#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

CONF="/usr/local/etc/xray/config.json"
ETC_CONF="/etc/xray/config.json"
SYSCTL_CONF="/etc/sysctl.d/99-live.conf"
DOMAIN="www.cloudflare.com"
PORT="443"
FLOW="xtls-rprx-vision"

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

new_short_id() {
  openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | xxd -p
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
            "email": "user1"
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
if not isinstance(shortids, list) or not shortids or not shortids[0]:
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
  pri="$(python3 - <<'PY'
import json
with open("/usr/local/etc/xray/config.json","r",encoding="utf-8") as f:
    data=json.load(f)
print(data["inbounds"][0]["streamSettings"]["realitySettings"].get("privateKey",""))
PY
)"
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

show_user_index_list() {
  echo "当前用户列表："
  while IFS='|' read -r idx name uuid flow; do
    [[ -z "$uuid" ]] && continue
    echo "  $idx. $name"
  done < <(list_users_raw)
  echo
}

user_name_by_index() {
  local idx="$1"
  list_users_raw | awk -F'|' -v i="$idx" '$1==i{print $2}'
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

ensure_default_user() {
  local count
  count="$(list_users_raw | wc -l | awk '{print $1}')"
  if [[ "$count" -eq 0 ]]; then
    python3 - "$(new_uuid)" <<'PY'
import json, sys
uuid=sys.argv[1]
conf="/usr/local/etc/xray/config.json"
with open(conf,"r",encoding="utf-8") as f:
    data=json.load(f)

settings = data["inbounds"][0].setdefault("settings", {})
clients = settings.setdefault("clients", [])

clients.append({
    "id": uuid,
    "flow": "xtls-rprx-vision",
    "email": "user1"
})

with open(conf,"w",encoding="utf-8") as f:
    json.dump(data,f,ensure_ascii=False,indent=2)
PY
    ensure_conf_link
    systemctl restart xray
  fi
}

print_first_link() {
  ensure_base_config
  ensure_default_user
  local idx name uuid flow
  while IFS='|' read -r idx name uuid flow; do
    [[ -z "$uuid" ]] && continue
    echo
    echo "====== 部署完成 ======"
    echo
    build_link "$uuid" "$name" "$flow"
    echo
    echo "管理命令: menu"
    echo
    break
  done < <(list_users_raw)
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
  local next_num name uuid
  next_num="$(list_users_raw | wc -l | awk '{print $1}')"
  next_num=$((next_num + 1))
  name="user${next_num}"
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
  show_user_index_list

  local idx name
  read -rp "请输入要删除的用户序号: " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || { echo "请输入数字序号"; return 1; }

  name="$(user_name_by_index "$idx")"
  [[ -n "$name" ]] || { echo "序号无效"; return 1; }

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
  show_user_index_list

  local idx name uuid
  read -rp "请输入要重置的用户序号: " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || { echo "请输入数字序号"; return 1; }

  name="$(user_name_by_index "$idx")"
  [[ -n "$name" ]] || { echo "序号无效"; return 1; }

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

restart_xray() {
  systemctl restart xray
  echo "Xray 已重启"
}

# ===== 新增：S5 管理入口 =====
run_s5_menu() {
  local s5_real="/usr/local/bin/live_s5.real"
  [[ -x "$s5_real" ]] || { echo "S5 工具不存在"; return 1; }
  bash "$s5_real"
  local rc=$?
  if [[ "$rc" -eq 88 ]]; then
    return 10
  fi
  return 10
}
# ===== 新增结束 =====

menu_ui() {
  clear
  cat <<EOF
==============================
   Xray Reality 管理菜单
==============================
1. 修复/初始化
2. 查看链接
3. 新增用户
4. 删除用户
5. 重置用户
6. 状态
7. 重启
8. S5 管理
0. 退出
==============================
EOF

  read -rp "请选择: " choice
  case "$choice" in
    1) ensure_base_config; echo "配置已修复/初始化" ;;
    2) show_links ;;
    3) add_user ;;
    4) delete_user ;;
    5) reset_user ;;
    6) show_status ;;
    7) restart_xray ;;
    8) run_s5_menu; return $? ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
}

case "${1:-}" in
  --bootstrap)
    print_first_link
    exit 0
    ;;
esac

while true; do
  rc=0
  menu_ui || rc=$?
  if [[ "$rc" -eq 10 ]]; then
    continue
  fi
  echo
  read -rp "按回车返回菜单..." _
done
