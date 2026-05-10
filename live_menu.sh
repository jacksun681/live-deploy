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
