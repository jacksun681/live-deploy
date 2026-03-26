#!/usr/bin/env bash
set -e

CONF="/usr/local/etc/xray/config.json"
SYSCTL="/etc/sysctl.d/99-live.conf"
DOMAIN="www.cloudflare.com"

[ "$(id -u)" != 0 ] && echo "请用 root 运行" && exit 1

need() {
  command -v "$1" >/dev/null 2>&1 || { apt update -y && apt install -y "$2"; }
}

deps() {
  need curl curl
  need qrencode qrencode
  need bc bc
  need ping iputils-ping
  need ip iproute2
}

xray_install() {
  command -v xray >/dev/null 2>&1 || \
    bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install
}

public_ip() {
  local ip
  ip="$(curl -4 -s https://api.ipify.org || true)"
  [ -z "$ip" ] && ip="$(curl -4 -s https://ifconfig.me || true)"
  [ -z "$ip" ] && ip="$(curl -4 -s https://ip.sb || true)"
  [ -z "$ip" ] && read -rp "请输入公网 IP: " ip
  echo "$ip"
}

tcp_test() {
  sysctl -w net.ipv4.tcp_congestion_control="$1" >/dev/null 2>&1 || true
  sleep 2
  ping -c 6 -W 2 8.8.8.8 2>/dev/null | awk -F'/' '/rtt|round-trip/ {print $7}'
}

tcp_choose() {
  local a b c
  a="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  echo "$a" | grep -qw bbr || { echo cubic; return; }
  b="$(tcp_test bbr)"; c="$(tcp_test cubic)"
  (( $(echo "$b <= $c" | bc -l) )) && echo bbr || echo cubic
}

sysctl_write() {
  cat >"$SYSCTL" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$1
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
  [ -n "$iface" ] && tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 || true
}

keys_make() {
  local pri pub raw
  raw="$(xray x25519 2>/dev/null || true)"
  pri="$(echo "$raw" | awk -F': ' '/Private key|PrivateKey/ {print $2}' | head -n1 | tr -d '\r')"
  [ -z "$pri" ] && { echo "生成 privateKey 失败"; return 1; }
  pub="$(xray x25519 -i "$pri" 2>/dev/null | awk -F': ' '/Public key|PublicKey|Password/ {print $2}' | head -n1 | tr -d '\r')"
  [ -z "$pub" ] && { echo "推导 pbk 失败"; return 1; }
  echo "$pri|$pub"
}

cfg_get() {
  grep -oP "$2" "$CONF" 2>/dev/null | head -n1 || true
}

cfg_write() {
  mkdir -p /usr/local/etc/xray
  cat >"$CONF" <<EOF
{
  "log":{"loglevel":"warning"},
  "inbounds":[
    {
      "port":$3,
      "protocol":"vless",
      "settings":{"clients":[{"id":"$1"}],"decryption":"none"},
      "streamSettings":{
        "network":"tcp",
        "security":"reality",
        "realitySettings":{
          "show":false,
          "dest":"$DOMAIN:443",
          "xver":0,
          "serverNames":["$DOMAIN"],
          "privateKey":"$2",
          "shortIds":[""]
        }
      }
    }
  ],
  "outbounds":[{"protocol":"freedom"}]
}
EOF
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
}

link_make() {
  local uuid="$1" port="$2" pri="$3" name="$4" pbk ip
  pbk="$(xray x25519 -i "$pri" 2>/dev/null | awk -F': ' '/Public key|PublicKey|Password/ {print $2}' | head -n1 | tr -d '\r')"
  ip="$(public_ip)"
  name="$(printf '%s' "${name:-Live}" | sed 's/ /%20/g')"
  echo "vless://${uuid}@${ip}:${port}?encryption=none&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${pbk}&type=tcp&headerType=none#${name}"
}

show_qr() {
  command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$1"
}

install_init() {
  deps
  xray_install
  local algo kp pri pub uuid port link
  algo="$(tcp_choose)"
  echo "自动选择 TCP 算法: $algo"
  sysctl_write "$algo"
  kp="$(keys_make)"
  pri="${kp%%|*}"; pub="${kp##*|}"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  read -rp "请输入端口（默认 443）: " port
  port="${port:-443}"
  cfg_write "$uuid" "$pri" "$port"
  link="$(link_make "$uuid" "$port" "$pri" "Live")"
  echo
  echo "安装完成"
  echo "UUID: $uuid"
  echo "PBK: $pub"
  echo "端口: $port"
  echo "$link"
  echo
  show_qr "$link"
}

show_link() {
  local uuid pri port name link
  uuid="$(cfg_get uuid '"id"\s*:\s*"\K[^"]+')"
  pri="$(cfg_get pri '"privateKey"\s*:\s*"\K[^"]+')"
  port="$(cfg_get port '"port"\s*:\s*\K\d+')"
  [ -z "$uuid" ] && echo "未找到配置，请先安装/初始化" && return
  [ -z "$pri" ] && echo "未找到 privateKey" && return
  [ -z "$port" ] && port=443
  read -rp "节点备注名（默认 Live）: " name
  link="$(link_make "$uuid" "$port" "$pri" "${name:-Live}")"
  echo
  echo "$link"
  echo
  show_qr "$link"
}

reset_node() {
  deps
  xray_install
  local kp pri pub uuid port link
  kp="$(keys_make)"
  pri="${kp%%|*}"; pub="${kp##*|}"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  port="$(cfg_get port '"port"\s*:\s*\K\d+')"
  [ -z "$port" ] && port=443
  cfg_write "$uuid" "$pri" "$port"
  link="$(link_make "$uuid" "$port" "$pri" "Live")"
  echo
  echo "已重置节点，旧链接失效"
  echo "UUID: $uuid"
  echo "PBK: $pub"
  echo "$link"
  echo
  show_qr "$link"
}

change_port() {
  local uuid pri port
  uuid="$(cfg_get uuid '"id"\s*:\s*"\K[^"]+')"
  pri="$(cfg_get pri '"privateKey"\s*:\s*"\K[^"]+')"
  [ -z "$uuid" ] && echo "未找到现有配置" && return
  [ -z "$pri" ] && echo "未找到 privateKey" && return
  read -rp "请输入新端口: " port
  [ -z "$port" ] && echo "端口不能为空" && return
  cfg_write "$uuid" "$pri" "$port"
  echo "端口已修改为: $port"
}

restart_x() { systemctl restart xray && echo "Xray 已重启"; }
status_x() { systemctl status xray --no-pager -l; }

uninstall_x() {
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  rm -f /usr/local/bin/xray
  rm -rf /usr/local/etc/xray
  rm -f /etc/systemd/system/xray.service
  rm -f "$SYSCTL"
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
1. 安装/初始化
2. 查看当前节点链接
3. 重置节点（旧链接失效）
4. 修改端口
5. 重启 Xray
6. 查看运行状态
7. 卸载
0. 退出
==============================
EOF
  read -rp "请选择: " n
  case "$n" in
    1) install_init ;;
    2) show_link ;;
    3) reset_node ;;
    4) change_port ;;
    5) restart_x ;;
    6) status_x ;;
    7) uninstall_x ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
}

while true; do
  menu
  echo
  read -rp "按回车返回菜单..." _
done