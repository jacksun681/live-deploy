#!/usr/bin/env bash
set -euo pipefail

CONF="/usr/local/etc/xray/config.json"
SYSCTL_CONF="/etc/sysctl.d/99-live.conf"
DOMAIN="www.cloudflare.com"
DEFAULT_PORT="443"

[[ "$(id -u)" -ne 0 ]] && echo "请用 root 运行" && exit 1

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    apt update -y
    apt install -y "$2"
  }
}

install_deps() {
  need_cmd curl curl
  need_cmd qrencode qrencode
  need_cmd bc bc
  need_cmd ping iputils-ping
  need_cmd ip iproute2
  need_cmd python3 python3
}

install_xray() {
  command -v xray >/dev/null 2>&1 || \
    bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install
}

get_public_ip() {
  local ip
  ip="$(curl -4 -s https://api.ipify.org || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -s https://ifconfig.me || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -s https://ip.sb || true)"
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

  if [[ -n "$bbr_jitter" && -n "$cubic_jitter" ]] && (( $(echo "$bbr_jitter <= $cubic_jitter" | bc -l) )); then
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

  sysctl --system >/dev/null

  local iface
  iface="$(ip route | awk '/default/ {print $5; exit}')"
  [[ -n "$iface" ]] && tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 || true
}

new_uuid() {
  cat /proc/sys/kernel/random/uuid
}

make_keys() {
  local raw pri pub
  raw="$(xray x25519 2>/dev/null || true)"
  pri="$(echo "$raw" | awk -F': ' '/Private key|PrivateKey/ {print $2}' | head -n1 | tr -d '\r')"
  [[ -z "$pri" ]] && { echo "生成 privateKey 失败"; return 1; }

  pub="$(xray x25519 -i "$pri" 2>/dev/null | awk -F': ' '/Public key|PublicKey|Password/ {print $2}' | head -n1 | tr -d '\r')"
  [[ -z "$pub" ]] && { echo "推导 publicKey/pbk 失败"; return 1; }

  echo "$pri|$pub"
}

get_private_key() {
  grep -oP '"privateKey"\s*:\s*"\K[^"]+' "$CONF" 2>/dev/null | head -n1 || true
}

get_port() {
  grep -oP '"port"\s*:\s*\K\d+' "$CONF" 2>/dev/null | head -n1 || true
}

get_pbk() {
  local pri
  pri="$(get_private_key)"
  [[ -z "$pri" ]] && return 1
  xray x25519 -i "$pri" 2>/dev/null | awk -F': ' '/Public key|PublicKey|Password/ {print $2}' | head -n1 | tr -d '\r'
}

ensure_base_config() {
  mkdir -p /usr/local/etc/xray

  if [[ ! -f "$CONF" ]]; then
    local algo keys pri uuid port
    algo="$(choose_tcp_algo)"
    echo "自动选择 TCP 算法: $algo"
    write_sysctl "$algo"

    keys="$(make_keys)"
    pri="${keys%%|*}"
    uuid="$(new_uuid)"
    port="$DEFAULT_PORT"

    cat >"$CONF" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {"id": "$uuid", "email": "user1"}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DOMAIN:443",
          "xver": 0,
          "serverNames": ["$DOMAIN"],
          "privateKey": "$pri",
          "shortIds": [""]
        }
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom"}
  ]
}
EOF
  fi

  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
}

list_users_raw() {
python3 - <<'PY'
import json
conf = "/usr/local/etc/xray/config.json"
with open(conf, "r", encoding="utf-8") as f:
    data = json.load(f)
clients = data["inbounds"][0]["settings"]["clients"]
for i, c in enumerate(clients, 1):
    print(f"{i}|{c.get('email','') or 'user'+str(i)}|{c.get('id','')}")
PY
}

build_link() {
  local uuid="$1"
  local name="$2"
  local ip port pbk safe_name

  port="$(get_port)"
  [[ -z "$port" ]] && port="$DEFAULT_PORT"

  pbk="$(get_pbk)"
  [[ -z "$pbk" ]] && { echo "无法推导 pbk"; return 1; }

  ip="$(get_public_ip)"
  safe_name="$(printf '%s' "$name" | sed 's/ /%20/g')"

  echo "vless://${uuid}@${ip}:${port}?encryption=none&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${pbk}&type=tcp&headerType=none#${safe_name}"
}

show_all_links() {
  local line idx name uuid link
  while IFS='|' read -r idx name uuid; do
    [[ -z "$uuid" ]] && continue
    link="$(build_link "$uuid" "$name")"
    echo "[$idx] $name"
    echo "$link"
    echo
  done < <(list_users_raw)
}

add_user() {
  local name uuid
  read -rp "请输入新用户名（如 user2）: " name
  [[ -z "$name" ]] && { echo "用户名不能为空"; return; }

  uuid="$(new_uuid)"

python3 - "$name" "$uuid" <<'PY'
import json, sys
name = sys.argv[1]
uuid = sys.argv[2]
conf = "/usr/local/etc/xray/config.json"
with open(conf, "r", encoding="utf-8") as f:
    data = json.load(f)

clients = data["inbounds"][0]["settings"]["clients"]
for c in clients:
    if c.get("email") == name:
        print("该用户名已存在")
        sys.exit(1)

clients.append({"id": uuid, "email": name})

with open(conf, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

  systemctl restart xray
  echo
  echo "已新增用户: $name"
  echo "$(build_link "$uuid" "$name")"
}

delete_user() {
  local name
  read -rp "请输入要删除的用户名: " name
  [[ -z "$name" ]] && { echo "用户名不能为空"; return; }

python3 - "$name" <<'PY'
import json, sys
name = sys.argv[1]
conf = "/usr/local/etc/xray/config.json"
with open(conf, "r", encoding="utf-8") as f:
    data = json.load(f)

clients = data["inbounds"][0]["settings"]["clients"]
new_clients = [c for c in clients if c.get("email") != name]

if len(new_clients) == len(clients):
    print("未找到该用户")
    sys.exit(1)

if not new_clients:
    print("至少要保留一个用户")
    sys.exit(1)

data["inbounds"][0]["settings"]["clients"] = new_clients

with open(conf, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

  systemctl restart xray
  echo "已删除用户: $name"
}

reset_one_user() {
  local name next_uuid
  read -rp "请输入要重置的用户名: " name
  [[ -z "$name" ]] && { echo "用户名不能为空"; return; }

  next_uuid="$(new_uuid)"

python3 - "$name" "$next_uuid" <<'PY'
import json, sys
name = sys.argv[1]
new_uuid = sys.argv[2]
conf = "/usr/local/etc/xray/config.json"
with open(conf, "r", encoding="utf-8") as f:
    data = json.load(f)

clients = data["inbounds"][0]["settings"]["clients"]
found = False
for c in clients:
    if c.get("email") == name:
        c["id"] = new_uuid
        found = True
        break

if not found:
    print("未找到该用户")
    sys.exit(1)

with open(conf, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

  systemctl restart xray
  echo
  echo "已重置用户: $name"
  echo "$(build_link "$next_uuid" "$name")"
}

show_status() {
  systemctl status xray --no-pager -l
}

restart_xray() {
  systemctl restart xray
  echo "Xray 已重启"
}

uninstall_xray() {
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  rm -f /usr/local/bin/xray
  rm -rf /usr/local/etc/xray
  rm -rf /usr/local/share/xray
  rm -f /etc/systemd/system/xray.service
  rm -f "$SYSCTL_CONF"
  systemctl daemon-reload
  sysctl --system >/dev/null 2>&1 || true
  echo "已彻底卸载"
}

menu() {
  clear
  cat <<EOF
==============================
   Xray Reality 多用户管理
==============================
1. 初始化/修复配置
2. 查看所有用户链接
3. 新增用户
4. 删除用户
5. 重置某个用户（旧链接失效）
6. 查看运行状态
7. 重启 Xray
8. 卸载
0. 退出
==============================
EOF

  read -rp "请选择: " choice
  case "$choice" in
    1) ensure_base_config; echo "配置已就绪" ;;
    2) show_all_links ;;
    3) add_user ;;
    4) delete_user ;;
    5) reset_one_user ;;
    6) show_status ;;
    7) restart_xray ;;
    8) uninstall_xray ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
}

install_deps
install_xray
ensure_base_config

while true; do
  menu
  echo
  read -rp "按回车返回菜单..." _
done