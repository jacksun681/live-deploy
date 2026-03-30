垃圾桶#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/danted.conf"
PORT_FILE="/etc/danted_port"
SYSCTL_CONF="/etc/sysctl.d/99-live-s5.conf"
DEFAULT_USER="zxwl123"
DEFAULT_PASS="zxwl123"

[[ "$(id -u)" -ne 0 ]] && echo "请用 root 运行" && exit 1

need_pkg() {
  dpkg -s "$1" >/dev/null 2>&1 || {
    apt-get update -yq
    apt-get install -yq \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      "$1"
  }
}

install_deps() {
  need_pkg dante-server
  need_pkg iproute2
  need_pkg curl
  need_pkg passwd
}

get_service_name() {
  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx 'sockd.service'; then
    echo "sockd"
    return
  fi
  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx 'danted.service'; then
    echo "danted"
    return
  fi
  if [[ -f /lib/systemd/system/sockd.service || -f /etc/systemd/system/sockd.service ]]; then
    echo "sockd"
    return
  fi
  echo "danted"
}

svc_enable()  { systemctl enable  "$(get_service_name)" >/dev/null 2>&1 || true; }
svc_start()   { systemctl start   "$(get_service_name)"; }
svc_stop()    { systemctl stop    "$(get_service_name)"; }
svc_restart() { systemctl restart "$(get_service_name)"; }

get_iface() {
  ip route | awk '/default/ {print $5; exit}'
}

get_ip() {
  curl -4 -s https://api.ipify.org || hostname -I | awk '{print $1}'
}

port_in_use() {
  local p="$1"
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"
}

get_port() {
  [[ -f "$PORT_FILE" ]] && { cat "$PORT_FILE"; return; }

  local port
  while true; do
    port=$((RANDOM % 50000 + 10000))
    port_in_use "$port" || break
  done

  echo "$port" > "$PORT_FILE"
  chmod 600 "$PORT_FILE"
  echo "$port"
}

write_sysctl() {
  cat >"$SYSCTL_CONF" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_no_metrics_save=1
net.core.somaxconn=4096
net.core.netdev_max_backlog=16384
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
  sysctl --system >/dev/null 2>&1 || true
}

write_conf() {
  local iface port
  iface="$(get_iface)"
  port="$(get_port)"

  cat >"$CONF" <<EOF
logoutput: syslog
internal: 0.0.0.0 port = ${port}
external: ${iface}

user.privileged: root
user.unprivileged: nobody
user.libwrap: nobody

socksmethod: username
clientmethod: none

timeout.negotiate: 30
timeout.io: 300

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: error connect disconnect
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp udp
  socksmethod: username
  log: error connect disconnect
}
EOF
}

write_service_override() {
  local svc
  svc="$(get_service_name)"
  mkdir -p "/etc/systemd/system/${svc}.service.d"
  cat >"/etc/systemd/system/${svc}.service.d/override.conf" <<'EOF'
[Service]
Restart=always
RestartSec=3

[Unit]
StartLimitIntervalSec=0
EOF
  systemctl daemon-reload
}

ensure_user() {
  if ! id "$DEFAULT_USER" >/dev/null 2>&1; then
    useradd -M -s /usr/sbin/nologin "$DEFAULT_USER"
  fi
  echo "${DEFAULT_USER}:${DEFAULT_PASS}" | chpasswd
}

open_port() {
  local port
  port="$(get_port)"

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    ufw allow "${port}/udp" >/dev/null 2>&1 || true
  fi
}

close_port() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
    ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
  fi
}

print_info() {
  echo
  echo "$(get_ip)"
  echo "$(get_port)"
  echo "${DEFAULT_USER}"
  echo "${DEFAULT_PASS}"
  echo
}

generate_s5() {
  install_deps
  write_sysctl
  write_conf
  ensure_user
  write_service_override
  svc_enable
  open_port
  svc_restart
  echo "S5 已生成完成"
  print_info
}

show_info() {
  generate_s5 >/dev/null 2>&1 || true
  print_info
}

change_port() {
  generate_s5 >/dev/null 2>&1 || true

  local old_port new_port
  old_port="$(get_port)"
  rm -f "$PORT_FILE"

  while true; do
    new_port=$((RANDOM % 50000 + 10000))
    port_in_use "$new_port" || break
  done

  echo "$new_port" > "$PORT_FILE"
  chmod 600 "$PORT_FILE"

  write_conf
  close_port "$old_port"
  open_port
  svc_restart

  echo "端口已修改，原端口已失效"
  print_info
}

start_s5() {
  generate_s5 >/dev/null 2>&1 || true
  svc_start
  echo "S5 已启动"
  print_info
}

stop_s5() {
  svc_stop
  echo "S5 已停止"
}

menu_ui() {
  clear
  cat <<EOF
==============================
         S5 管理菜单
==============================
1. 生成 S5
2. 查看 S5 信息
3. 修改端口
4. 启动 S5
5. 停止 S5
0. 返回上级菜单
==============================
EOF

  read -rp "请选择: " choice
  case "$choice" in
    1) generate_s5 ;;
    2) show_info ;;
    3) change_port ;;
    4) start_s5 ;;
    5) stop_s5 ;;
    0) exit 88 ;;
    *) echo "无效选项" ;;
  esac
}

while true; do
  rc=0
  menu_ui || rc=$?
  [[ "$rc" -eq 88 ]] && exit 88
  echo
  read -rp "按回车返回菜单..." _
done
