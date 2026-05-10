#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

CONF="/usr/local/etc/xray/config.json"
ETC_CONF="/etc/xray/config.json"
INFO="/etc/live_menu_info"
SERVICE="xray"
REAL_PATH="/usr/local/bin/live_menu.real"
MENU_PATH="/usr/local/bin/menu"
SYSCTL_CONF="/etc/sysctl.d/99-live.conf"
UPDATE_URL="https://raw.githubusercontent.com/jacksun681/live-deploy/main/live_menu.sh"

V_PORT="443"
SNI="www.microsoft.com"
DEST="www.microsoft.com:443"
FP="chrome"
FLOW="xtls-rprx-vision"

S_USER="zxwl123"
S_PASS="zxwl123"

green="\033[32m"
plain="\033[0m"

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
  need_cmd update-ca-certificates ca-certificates
  need_cmd openssl openssl
  need_cmd jq jq
  need_cmd ss iproute2
  need_cmd ip iproute2
  need_cmd python3 python3
  need_cmd awk gawk
}

install_xray() {
  command -v xray >/dev/null 2>&1 || \
    bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install
}

get_ip() {
  curl -4 -s --connect-timeout 3 --max-time 5 https://api.ipify.org || \
  curl -4 -s --connect-timeout 3 --max-time 5 https://ifconfig.me || \
  hostname -I | awk '{print $1}'
}

rand_port() {
  local p
  while true; do
    p=$((RANDOM % 50000 + 10000))
    ss -lnt 2>/dev/null | grep -q ":$p " || {
      echo "$p"
      return
    }
  done
}

new_uuid() {
  cat /proc/sys/kernel/random/uuid
}

make_keys() {
  local raw pri pub
  raw="$(xray x25519)"
  pri="$(echo "$raw" | awk -F': ' '/Private key|PrivateKey/ {print $2}' | head -n1)"
  pub="$(echo "$raw" | awk -F': ' '/Public key|PublicKey|Password/ {print $2}' | head -n1)"
  [[ -z "$pri" || -z "$pub" ]] && { echo "生成 Reality 密钥失败"; exit 1; }
  echo "$pri|$pub"
}

new_sid() {
  openssl rand -hex 8
}

write_sysctl() {
  cat > "$SYSCTL_CONF" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
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
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF

  sysctl --system >/dev/null 2>&1 || true

  local iface
  iface="$(ip route | awk '/default/ {print $5; exit}')"
  [[ -n "${iface:-}" ]] && tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 || true
}

load_info() {
  V_IDS=()
  V_NAMES=()
  V_PORT="$V_PORT"
  V_PRI=""
  V_PUB=""
  M_PORT=0
  M_ID=""
  S_PORT=0
  S_USER="$S_USER"
  S_PASS="$S_PASS"
  SID=""
  SNI="$SNI"
  DEST="$DEST"
  FP="$FP"
  FLOW="$FLOW"

  if [[ -f "$INFO" ]]; then
    # shellcheck disable=SC1090
    source "$INFO" || true
  fi

  [[ -z "${V_PORT:-}" ]] && V_PORT="443"
  [[ -z "${SNI:-}" ]] && SNI="www.microsoft.com"
  [[ -z "${DEST:-}" ]] && DEST="www.microsoft.com:443"
  [[ -z "${FP:-}" ]] && FP="chrome"
  [[ -z "${FLOW:-}" ]] && FLOW="xtls-rprx-vision"
  [[ -z "${S_USER:-}" ]] && S_USER="zxwl123"
  [[ -z "${S_PASS:-}" ]] && S_PASS="zxwl123"
  [[ -z "${SID:-}" ]] && SID="$(new_sid)"

  if [[ -z "${V_PRI:-}" || -z "${V_PUB:-}" ]]; then
    local keys
    keys="$(make_keys)"
    V_PRI="${keys%%|*}"
    V_PUB="${keys##*|}"
  fi
}

save_info() {
  cat > "$INFO" <<EOF
V_IDS=(${V_IDS[*]})
V_NAMES=(${V_NAMES[*]})
V_PORT="$V_PORT"
V_PRI="$V_PRI"
V_PUB="$V_PUB"

M_PORT=$M_PORT
M_ID="$M_ID"

S_PORT=$S_PORT
S_USER="$S_USER"
S_PASS="$S_PASS"

SNI="$SNI"
DEST="$DEST"
FP="$FP"
FLOW="$FLOW"
SID="$SID"
EOF
}

ensure_first_vless() {
  if [[ "${#V_IDS[@]}" -eq 0 ]]; then
    V_IDS+=("$(new_uuid)")
    V_NAMES+=("vless1")
  fi
}

ensure_vmess() {
  if [[ "${M_PORT:-0}" -eq 0 ]]; then
    M_PORT="$(rand_port)"
    M_ID="$(new_uuid)"
  fi
}

ensure_s5() {
  if [[ "${S_PORT:-0}" -eq 0 ]]; then
    S_PORT="$(rand_port)"
  fi
}

write_config() {
  mkdir -p /usr/local/etc/xray /etc/xray

  python3 - "$CONF" <<PY
import json

conf_path="$CONF"

v_ids="${V_IDS[*]}".split()
v_port=int("$V_PORT")
v_pri="$V_PRI"

m_port=int("$M_PORT")
m_id="$M_ID"

s_port=int("$S_PORT")
s_user="$S_USER"
s_pass="$S_PASS"

sni="$SNI"
dest="$DEST"
sid="$SID"
flow="$FLOW"

clients=[]
for i, uid in enumerate(v_ids):
    clients.append({
        "id": uid,
        "flow": flow,
        "email": f"user{i+1}"
    })

inbounds=[]

inbounds.append({
    "port": v_port,
    "protocol": "vless",
    "settings": {
        "clients": clients,
        "decryption": "none"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "sockopt": {
            "tcpKeepAliveIdle": 300,
            "tcpKeepAliveInterval": 30
        },
        "realitySettings": {
            "show": False,
            "dest": dest,
            "xver": 0,
            "serverNames": [sni],
            "privateKey": v_pri,
            "shortIds": [sid]
        }
    }
})

if m_port > 0:
    inbounds.append({
        "port": m_port,
        "protocol": "vmess",
        "settings": {
            "clients": [
                {
                    "id": m_id,
                    "alterId": 0
                }
            ]
        },
        "streamSettings": {
            "network": "tcp"
        }
    })

if s_port > 0:
    inbounds.append({
        "port": s_port,
        "listen": "0.0.0.0",
        "protocol": "socks",
        "settings": {
            "auth": "password",
            "accounts": [
                {
                    "user": s_user,
                    "pass": s_pass
                }
            ],
            "udp": True
        }
    })

data={
    "log": {
        "loglevel": "warning"
    },
    "inbounds": inbounds,
    "outbounds": [
        {
            "protocol": "freedom"
        }
    ]
}

with open(conf_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

  ln -sf "$CONF" "$ETC_CONF"
}

restart_xray() {
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
}

build_vless_link() {
  local uuid="$1"
  local name="$2"
  local ip
  ip="$(get_ip)"

  echo "vless://${uuid}@${ip}:${V_PORT}?encryption=none&security=reality&sni=${SNI}&fp=${FP}&pbk=${V_PUB}&sid=${SID}&flow=${FLOW}&type=tcp&headerType=none#${name}"
}

build_vmess_link() {
  local ip
  ip="$(get_ip)"

  python3 - <<PY
import json, base64

obj = {
    "v": "2",
    "ps": "vmess",
    "add": "$ip",
    "port": "$M_PORT",
    "id": "$M_ID",
    "aid": "0",
    "scy": "auto",
    "net": "tcp",
    "type": "none",
    "host": "",
    "path": "",
    "tls": ""
}

print("vmess://" + base64.b64encode(json.dumps(obj).encode()).decode())
PY
}

show_vless() {
  for i in "${!V_IDS[@]}"; do
    build_vless_link "${V_IDS[$i]}" "${V_NAMES[$i]}"
  done
}

show_vmess() {
  build_vmess_link
}

show_s5() {
  local ip
  ip="$(get_ip)"

  echo "$ip"
  echo "$S_PORT"
  echo "$S_USER"
  echo "$S_PASS"
  echo
  echo "${ip}:${S_PORT}:${S_USER}:${S_PASS}"
}

show_all_links() {
  echo
  echo -e "${green}========== VLESS ==========${plain}"
  show_vless

  echo
  echo -e "${green}========== VMESS ==========${plain}"
  show_vmess

  echo
  echo -e "${green}========== S5 ==========${plain}"
  show_s5
  echo
}

add_vless() {
  local name
  name="vless$(( ${#V_IDS[@]} + 1 ))"

  V_IDS+=("$(new_uuid)")
  V_NAMES+=("$name")

  save_info
  write_config
  restart_xray

  echo
  echo "已新增: $name"
  build_vless_link "${V_IDS[-1]}" "$name"
  echo
}

reset_vless() {
  if [[ "${#V_IDS[@]}" -eq 0 ]]; then
    echo "没有 VLESS 用户"
    return
  fi

  echo
  for i in "${!V_IDS[@]}"; do
    echo "$((i+1)). ${V_NAMES[$i]}"
  done
  echo

  read -rp "请输入编号: " idx

  [[ "$idx" =~ ^[0-9]+$ ]] || {
    echo "请输入数字"
    return
  }

  idx=$((idx-1))

  [[ "$idx" -lt 0 || "$idx" -ge "${#V_IDS[@]}" ]] && {
    echo "编号不存在"
    return
  }

  V_IDS[$idx]="$(new_uuid)"

  save_info
  write_config
  restart_xray

  echo
  echo "已重置: ${V_NAMES[$idx]}"
  build_vless_link "${V_IDS[$idx]}" "${V_NAMES[$idx]}"
  echo
}

delete_vless() {
  if [[ "${#V_IDS[@]}" -le 1 ]]; then
    echo "至少保留一个 VLESS"
    return
  fi

  echo
  for i in "${!V_IDS[@]}"; do
    echo "$((i+1)). ${V_NAMES[$i]}"
  done
  echo

  read -rp "请输入编号: " idx

  [[ "$idx" =~ ^[0-9]+$ ]] || {
    echo "请输入数字"
    return
  }

  idx=$((idx-1))

  [[ "$idx" -lt 0 || "$idx" -ge "${#V_IDS[@]}" ]] && {
    echo "编号不存在"
    return
  }

  unset 'V_IDS[idx]'
  unset 'V_NAMES[idx]'

  V_IDS=("${V_IDS[@]}")
  V_NAMES=("${V_NAMES[@]}")

  save_info
  write_config
  restart_xray

  echo
  echo "已删除"
  echo
}

reset_vmess() {
  M_PORT="$(rand_port)"
  M_ID="$(new_uuid)"

  save_info
  write_config
  restart_xray

  echo
  echo "VMess 已重置"
  show_vmess
  echo
}

reset_s5() {
  S_PORT="$(rand_port)"

  save_info
  write_config
  restart_xray

  echo
  echo "S5 已重置"
  show_s5
  echo
}

update_script() {
  curl -fsSL "$UPDATE_URL" -o "$REAL_PATH"
  sed -i 's/\r$//' "$REAL_PATH"
  chmod +x "$REAL_PATH"

  echo
  echo "脚本已更新"
  echo
}

uninstall_all() {
  systemctl stop xray >/dev/null 2>&1 || true

  rm -f "$CONF"
  rm -f "$INFO"
  rm -f "$REAL_PATH"
  rm -f "$MENU_PATH"
  rm -f /usr/local/bin/show_vless
  rm -f /usr/local/bin/show_vmess
  rm -f /usr/local/bin/show_s5

  echo
  echo "已卸载"
  echo
  exit 0
}

create_shortcuts() {
cat > /usr/local/bin/show_vless << 'EOF'
#!/usr/bin/env bash
bash /usr/local/bin/live_menu.real internal_show_vless
EOF

cat > /usr/local/bin/show_vmess << 'EOF'
#!/usr/bin/env bash
bash /usr/local/bin/live_menu.real internal_show_vmess
EOF

cat > /usr/local/bin/show_s5 << 'EOF'
#!/usr/bin/env bash
bash /usr/local/bin/live_menu.real internal_show_s5
EOF

chmod +x /usr/local/bin/show_vless
chmod +x /usr/local/bin/show_vmess
chmod +x /usr/local/bin/show_s5
}

bootstrap() {
  install_deps
  install_xray
  write_sysctl

  load_info

  ensure_first_vless
  ensure_vmess
  ensure_s5

  save_info
  write_config
  create_shortcuts
  restart_xray

  show_all_links
}

menu_ui() {
  clear

  echo "===================================="
  echo
  echo "        node 管理菜单"
  echo "         $(get_ip)"
  echo
  echo "===================================="
  echo
  echo "1. 查看全部链接"
  echo "2. 新增 VLESS"
  echo "3. 重置 VLESS"
  echo "4. 删除 VLESS"
  echo "5. 重置 VMess"
  echo "6. 重置 S5"
  echo "7. 更新脚本"
  echo "8. 卸载配置"
  echo "0. 退出"
  echo
  echo "------------------------------------"
  echo

  read -rp "请选择: " choice

  case "$choice" in
    1)
      show_all_links
      ;;
    2)
      add_vless
      ;;
    3)
      reset_vless
      ;;
    4)
      delete_vless
      ;;
    5)
      reset_vmess
      ;;
    6)
      reset_s5
      ;;
    7)
      update_script
      ;;
    8)
      uninstall_all
      ;;
    0)
      exit 0
      ;;
    *)
      echo "无效选择"
      ;;
  esac

  echo
  read -rp "按回车继续..." _
}

case "${1:-}" in
  --bootstrap)
    bootstrap
    exit 0
    ;;

  internal_show_vless)
    load_info
    show_vless
    exit 0
    ;;

  internal_show_vmess)
    load_info
    show_vmess
    exit 0
    ;;

  internal_show_s5)
    load_info
    show_s5
    exit 0
    ;;
esac

load_info

while true; do
  menu_ui
done
