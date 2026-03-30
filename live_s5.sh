#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/danted.conf"
PORT_FILE="/etc/danted_port"
SERVICE="s5"
SOCKD_BIN="/usr/local/sbin/sockd"
DEFAULT_USER="zxwl123"
DEFAULT_PASS="zxwl123"

[[ "$(id -u)" -ne 0 ]] && echo "请用 root 运行" && exit 1

get_iface() {
  ip route | awk '/default/ {print $5; exit}'
}

get_ip() {
  hostname -I | awk '{print $1}'
}

port_in_use() {
  local p="$1"
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"
}

rand_port() {
  local port
  while true; do
    port=$((RANDOM % 50000 + 10000))
    port_in_use "$port" || break
  done
  echo "$port"
}

get_port() {
  [[ -f "$PORT_FILE" ]] && cat "$PORT_FILE" || echo "1080"
}

ensure_sockd() {
  [[ -x "$SOCKD_BIN" ]] || { echo "sockd 不存在: $SOCKD_BIN"; exit 1; }
}

ensure_user() {
  useradd -M -s /usr/sbin/nologin "$DEFAULT_USER" 2>/dev/null || true
  echo "${DEFAULT_USER}:${DEFAULT_PASS}" | chpasswd
}

write_conf() {
  local port iface ip
  port="$1"
  iface="$(get_iface)"
  ip="$(get_ip)"

  cat > "$CONF" <<EOF
logoutput: stderr

internal: 0.0.0.0 port = ${port}
external: ${ip}

socksmethod: username
clientmethod: none

user.privileged: root
user.unprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    socksmethod: username
}
EOF
}

write_service() {
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=S5 Proxy
After=network.target

[Service]
ExecStart=${SOCKD_BIN} -f ${CONF}
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

open_port() {
  local port="$1"
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
  echo "$DEFAULT_USER"
  echo "$DEFAULT_PASS"
  echo
}

generate_s5() {
  local port
  ensure_sockd
  ensure_user
  port="$(get_port)"
  [[ "$port" =~ ^[0-9]+$ ]] || port="1080"
  echo "$port" > "$PORT_FILE"
  write_conf "$port"
  write_service
  open_port "$port"
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE"
  echo "S5 已生成完成"
  print_info
}

show_info() {
  [[ -f "$PORT_FILE" ]] || { echo "S5 未生成"; return 1; }
  print_info
}

change_port() {
  local old_port new_port
  old_port="$(get_port)"
  new_port="$(rand_port)"
  echo "$new_port" > "$PORT_FILE"
  write_conf "$new_port"
  close_port "$old_port"
  open_port "$new_port"
  systemctl restart "$SERVICE"
  echo "端口已修改，原端口已失效"
  print_info
}

start_s5() {
  systemctl start "$SERVICE"
  echo "S5 已启动"
  print_info
}

stop_s5() {
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
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
