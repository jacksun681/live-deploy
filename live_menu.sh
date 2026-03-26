#!/usr/bin/env bash
set -e

CONF="/usr/local/etc/xray/config.json"
SYSCTL_CONF="/etc/sysctl.d/99-live.conf"
DOMAIN="www.cloudflare.com"

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

  if (( $(echo "$bbr_jitter <= $cubic_jitter" | bc -l) )); then
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

cfg_get() {
  grep -oP "$1" "$CONF" 2>/dev/null | head -n1 || true
}

write_config() {
  local uuid="$1" pri="$2" port="$3"
  mkdir -p /usr/local/etc/xray

  cat >"$CONF" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$uuid"}],
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

  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
}

build_link() {
  local uuid="$1" port="$2" pri="$3" name="$4"
  local pub ip safe_name

  pub="$(xray x25519 -i "$pri" 2>/dev/null | awk -F': ' '/Public key|PublicKey|Password/ {print $2}' | head -n1 | tr -d '\r')"
  [[ -z "$pub" ]] && { echo "无法推导 pbk"; return 1; }

  ip="$(get_public_ip)"
  safe_name="$(printf '%s' "${name:-Live}" | sed 's/ /%20/g')"

  echo "vless://${uuid}@${ip}:${port}?encryption=none&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${pub}&type=tcp&headerType=none#${safe_name}"
}

show_qr() {
  command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$1"
}

install_init() {
  install_deps
  install_xray

  local algo keys pri pub uuid port link
  algo="$(choose_tcp_algo)"
  echo "自动选择 TCP 算法: $algo"
  write_sysctl "$algo"

  keys="$(make_keys)"
  pri="${keys%%|*}"
  pub="${keys##*|}"
  uuid="$(new_uuid)"
  port="443"

  write_config "$uuid" "$pri" "$port"
  link="$(build_link "$uuid" "$port" "$pri" "Live")"

  echo
  echo "安装完成"
  echo "UUID: $uuid"
  echo "PBK: $pub"
  echo "端口: $port"
  echo
  echo "$link"
  echo
  show_qr "$link"
}

show_link() {
  local uuid pri port name link
  uuid="$(cfg_get '"id"\s*:\s*"\K[^"]+')"
  pri="$(cfg_get '"privateKey"\s*:\s*"\K[^"]+')"
  port="$(cfg_get '"port"\s*:\s*\K\d+')"

  [[ -z "$uuid" ]] && { echo "未找到配置，请先安装"; return; }
  [[ -z "$pri" ]] && { echo "未找到 privateKey"; return; }
  [[ -z "$port" ]] && port=443

  read -rp "节点备注名（默认 Live）: " name
  link="$(build_link "$uuid" "$port" "$pri" "${name:-Live}")"

  echo
  echo "$link"
  echo
  show_qr "$link"
}

reset_node() {
  install_deps
  install_xray

  local keys pri pub uuid port link
  keys="$(make_keys)"
  pri="${keys%%|*}"
  pub="${keys##*|}"
  uuid="$(new_uuid)"
  port="$(cfg_get '"port"\s*:\s*\K\d+')"
  [[ -z "$port" ]] && port=443

  write_config "$uuid" "$pri" "$port"
  link="$(build_link "$uuid" "$port" "$pri" "Live")"

  echo
  echo "已重置节点，旧链接失效"
  echo "UUID: $uuid"
  echo "PBK: $pub"
  echo "端口: $port"
  echo
  echo "$link"
  echo
  show_qr "$link"
}

change_port() {
  local uuid pri port
  uuid="$(cfg_get '"id"\s*:\s*"\K[^"]+')"
  pri="$(cfg_get '"privateKey"\s*:\s*"\K[^"]+')"

  [[ -z "$uuid" ]] && { echo "未找到现有配置"; return; }
  [[ -z "$pri" ]] && { echo "未找到 privateKey"; return; }

  read -rp "请输入新端口: " port
  [[ -z "$port" ]] && { echo "端口不能为空"; return; }

  write_config "$uuid" "$pri" "$port"
  echo "端口已修改为: $port"
}

restart_xray() {
  systemctl restart xray
  echo "Xray 已重启"
}

show_status() {
  systemctl status xray --no-pager -l
}

uninstall_xray() {
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  rm -f /usr/local/bin/xray
  rm -rf /usr/local/etc/xray
  rm -f /etc/systemd/system/xray.service
  rm -f "$SYSCTL_CONF"
  systemctl daemon-reload
  sysctl --system >/dev/null 2>&1 || true
  echo "已卸载完成"
}

menu() {
  clear
  cat <<EOF
==============================
   Xray Reality 菜单管理
==============================
1. 查看当前节点链接
2. 重置节点（旧链接失效）
3. 修改端口
4. 重启 Xray
5. 查看运行状态
6. 卸载
0. 退出
==============================
EOF

  read -rp "请选择: " choice
  case "$choice" in
    1) show_link ;;
    2) reset_node ;;
    3) change_port ;;
    4) restart_xray ;;
    5) show_status ;;
    6) uninstall_xray ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
}

# 首次运行：未安装则直接自动安装并输出链接
if [[ ! -f "$CONF" ]]; then
  install_init
  exit 0
fi

# 已安装：进入菜单
while true; do
  menu
  echo
  read -rp "按回车返回菜单..." _
done