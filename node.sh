#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

CONF="/usr/local/etc/xray/config.json"
ETC_CONF="/etc/xray/config.json"
INFO="/etc/node_info"
SERVICE="xray"
CMD="/usr/local/bin/node"
SYSCTL_CONF="/etc/sysctl.d/99-node.conf"
UPDATE_URL="https://raw.githubusercontent.com/jacksun681/live-deploy/main/node.sh"

SNI="www.microsoft.com"
DEST="www.microsoft.com:443"
FP="chrome"
FLOW="xtls-rprx-vision"
S_USER="zxwl123"
S_PASS="zxwl123"

green="\033[32m"
yellow="\033[33m"
red="\033[31m"
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
  need_cmd openssl openssl
  need_cmd jq jq
  need_cmd ss iproute2
  need_cmd ip iproute2
  need_cmd python3 python3
}

install_xray() {
  if ! command -v xray >/dev/null 2>&1; then
    bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install
  fi
}

get_ip() {
  local ip
  ip="$(curl -4 -s --connect-timeout 3 --max-time 5 https://api.ipify.org || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -s --connect-timeout 3 --max-time 5 https://ifconfig.me || true)"
  [[ -z "$ip" ]] && ip="$(hostname -I | awk '{print $1}')"
  echo "$ip"
}

rand_port() {
  local p
  while true; do
    p=$((RANDOM % 50000 + 10000))
    ss -lnt 2>/dev/null | grep -q ":$p " || { echo "$p"; return; }
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
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF

  sysctl --system >/dev/null 2>&1 || true

  local iface
  iface="$(ip route | awk '/default/ {print $5; exit}')"
  [[ -n "${iface:-}" ]] && tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 || true
}

load_info() {
  if [[ -f "$INFO" ]]; then
    # shellcheck disable=SC1090
    source "$INFO"
  else
    V_PORTS=()
    V_IDS=()
    V_PRI_KEYS=()
    V_PUB_KEYS=()
    V_NAMES=()
    S_PORT=0
    SID="$(new_sid)"
  fi
}

save_info() {
  cat > "$INFO" <<EOF
V_PORTS=(${V_PORTS[*]})
V_IDS=(${V_IDS[*]})
V_PRI_KEYS=(${V_PRI_KEYS[*]})
V_PUB_KEYS=(${V_PUB_KEYS[*]})
V_NAMES=(${V_NAMES[*]})
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
  if [[ "${#V_PORTS[@]}" -eq 0 ]]; then
    local keys pri pub
    keys="$(make_keys)"
    pri="${keys%%|*}"
    pub="${keys##*|}"

    V_PORTS+=("$(rand_port)")
    V_IDS+=("$(new_uuid)")
    V_PRI_KEYS+=("$pri")
    V_PUB_KEYS+=("$pub")
    V_NAMES+=("vless1")
  fi
}

ensure_s5() {
  if [[ "${S_PORT:-0}" -le 0 ]]; then
    S_PORT="$(rand_port)"
  fi
}

write_config() {
  mkdir -p /usr/local/etc/xray /etc/xray

  python3 - "$CONF" <<PY
import json

conf_path = "$CONF"

v_ports = "${V_PORTS[*]}".split()
v_ids = "${V_IDS[*]}".split()
v_pris = "${V_PRI_KEYS[*]}".split()
s_port = int("$S_PORT")

sni = "$SNI"
dest = "$DEST"
sid = "$SID"
flow = "$FLOW"
s_user = "$S_USER"
s_pass = "$S_PASS"

inbounds = []

for i, port in enumerate(v_ports):
    inbounds.append({
        "port": int(port),
        "protocol": "vless",
        "settings": {
            "clients": [
                {
                    "id": v_ids[i],
                    "flow": flow,
                    "email": f"user{i+1}"
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
                "show": False,
                "dest": dest,
                "xver": 0,
                "serverNames": [sni],
                "privateKey": v_pris[i],
                "shortIds": [sid]
            }
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

data = {
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

write_show_commands() {
  cat > /usr/local/bin/show_vless <<'EOF'
#!/usr/bin/env bash
INFO="/etc/node_info"
[[ -f "$INFO" ]] || { echo "未找到节点信息"; exit 1; }
source "$INFO"

IP="$(curl -4 -s --connect-timeout 3 --max-time 5 https://api.ipify.org || curl -4 -s --connect-timeout 3 --max-time 5 https://ifconfig.me || hostname -I | awk '{print $1}')"

for i in "${!V_PORTS[@]}"; do
  NAME="${V_NAMES[$i]:-vless$((i+1))}"
  echo "vless://${V_IDS[$i]}@${IP}:${V_PORTS[$i]}?encryption=none&security=reality&sni=${SNI}&fp=${FP}&pbk=${V_PUB_KEYS[$i]}&sid=${SID}&type=tcp&headerType=none&flow=${FLOW}#${NAME}"
done
EOF
  chmod +x /usr/local/bin/show_vless

  cat > /usr/local/bin/show_s5 <<'EOF'
#!/usr/bin/env bash
INFO="/etc/node_info"
[[ -f "$INFO" ]] || { echo "未找到 S5 信息"; exit 1; }
source "$INFO"

IP="$(curl -4 -s --connect-timeout 3 --max-time 5 https://api.ipify.org || curl -4 -s --connect-timeout 3 --max-time 5 https://ifconfig.me || hostname -I | awk '{print $1}')"

echo "$IP"
echo "$S_PORT"
echo "$S_USER"
echo "$S_PASS"
EOF
  chmod +x /usr/local/bin/show_s5
}

apply_all() {
  save_info
  write_config
  write_show_commands
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE"
}

init_node() {
  install_deps
  install_xray
  write_sysctl
  load_info
  ensure_first_vless
  ensure_s5
  apply_all
}

print_links() {
  local ip
  ip="$(get_ip)"

  echo
  echo -e "${green}--- VLESS 链接 ---${plain}"
  for i in "${!V_PORTS[@]}"; do
    local name
    name="${V_NAMES[$i]:-vless$((i+1))}"
    echo "vless://${V_IDS[$i]}@${ip}:${V_PORTS[$i]}?encryption=none&security=reality&sni=${SNI}&fp=${FP}&pbk=${V_PUB_KEYS[$i]}&sid=${SID}&type=tcp&headerType=none&flow=${FLOW}#${name}"
  done

  echo
  echo -e "${green}--- S5 信息 ---${plain}"
  echo "$ip"
  echo "$S_PORT"
  echo "$S_USER"
  echo "$S_PASS"
  echo
  echo "快捷命令：show_vless / show_s5"
  echo
}

add_vless() {
  local keys pri pub num
  keys="$(make_keys)"
  pri="${keys%%|*}"
  pub="${keys##*|}"

  num=$(( ${#V_PORTS[@]} + 1 ))

  V_PORTS+=("$(rand_port)")
  V_IDS+=("$(new_uuid)")
  V_PRI_KEYS+=("$pri")
  V_PUB_KEYS+=("$pub")
  V_NAMES+=("vless${num}")

  apply_all
  print_links
}

reset_vless() {
  echo
  echo "当前 VLESS："
  for i in "${!V_PORTS[@]}"; do
    echo "$((i+1)). ${V_NAMES[$i]:-vless$((i+1))} 端口:${V_PORTS[$i]}"
  done
  echo
  read -rp "请输入要重置的编号，或输入 all: " opt

  if [[ "$opt" == "all" ]]; then
    for i in "${!V_PORTS[@]}"; do
      local keys pri pub
      keys="$(make_keys)"
      pri="${keys%%|*}"
      pub="${keys##*|}"
      V_PORTS[$i]="$(rand_port)"
      V_IDS[$i]="$(new_uuid)"
      V_PRI_KEYS[$i]="$pri"
      V_PUB_KEYS[$i]="$pub"
    done
  else
    [[ "$opt" =~ ^[0-9]+$ ]] || { echo "请输入数字或 all"; return; }
    local idx=$((opt-1))
    [[ "$idx" -ge 0 && "$idx" -lt "${#V_PORTS[@]}" ]] || { echo "编号无效"; return; }

    local keys pri pub
    keys="$(make_keys)"
    pri="${keys%%|*}"
    pub="${keys##*|}"

    V_PORTS[$idx]="$(rand_port)"
    V_IDS[$idx]="$(new_uuid)"
    V_PRI_KEYS[$idx]="$pri"
    V_PUB_KEYS[$idx]="$pub"
  fi

  apply_all
  print_links
}

reset_s5() {
  S_PORT="$(rand_port)"
  apply_all
  print_links
}

show_status() {
  systemctl status xray --no-pager -l
}

restart_node() {
  systemctl restart xray
  echo "Xray 已重启"
}

update_script() {
  echo "正在更新 node..."
  curl -fsSL "$UPDATE_URL" -o /usr/local/bin/node.tmp || {
    echo "更新失败"
    return 1
  }
  sed -i 's/\r$//' /usr/local/bin/node.tmp
  chmod +x /usr/local/bin/node.tmp
  mv /usr/local/bin/node.tmp "$CMD"
  echo "node 已更新"
}

uninstall_node() {
  read -rp "确认卸载？输入 yes: " ok
  [[ "$ok" == "yes" ]] || return

  systemctl stop xray >/dev/null 2>&1 || true
  rm -f "$INFO"
  rm -f "$CONF"
  rm -f /usr/local/bin/show_vless /usr/local/bin/show_s5
  echo "已卸载 node 配置"
}

menu() {
  load_info

  clear
  echo -e "${green}==========================================${plain}"
  echo "        node 管理菜单 | IP: $(get_ip)"
  echo -e "${green}==========================================${plain}"
  echo "1. 查看链接"
  echo "2. 新增 VLESS"
  echo "3. 重置 VLESS"
  echo "4. 重置 S5"
  echo "5. 状态"
  echo "6. 重启"
  echo "7. 更新脚本"
  echo "8. 卸载配置"
  echo "0. 退出"
  echo "------------------------------------------"
  read -rp "请选择: " opt

  case "$opt" in
    1) print_links; read -rp "按回车返回菜单..." _ ;;
    2) add_vless; read -rp "按回车返回菜单..." _ ;;
    3) reset_vless; read -rp "按回车返回菜单..." _ ;;
    4) reset_s5; read -rp "按回车返回菜单..." _ ;;
    5) show_status; read -rp "按回车返回菜单..." _ ;;
    6) restart_node; read -rp "按回车返回菜单..." _ ;;
    7) update_script; read -rp "按回车返回菜单..." _ ;;
    8) uninstall_node; read -rp "按回车返回菜单..." _ ;;
    0) exit 0 ;;
    *) echo "无效输入"; sleep 1 ;;
  esac
}

case "${1:-}" in
  --bootstrap)
    init_node
    print_links
    exit 0
    ;;
esac

init_node

while true; do
  menu
done