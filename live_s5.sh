#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/danted.conf"
PORT_FILE="/etc/danted_port"
SERVICE_NAME="s5"
SOCKD_BIN="/usr/local/sbin/sockd"

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

get_port() {
  [[ -f "$PORT_FILE" ]] && { cat "$PORT_FILE"; return; }

  local port
  while true; do
    port=$((RANDOM % 50000 + 10000))
    port_in_use "$port" || break
  done
  echo "$port" > "$PORT_FILE"
  echo "$port"
}

write_conf() {
  local iface port
  iface="$(get_iface)"
  port="$(get_port)"

  cat > "$CONF" <<EOF
logoutput: stderr

internal: ${iface} port = ${port}
external: ${iface}

user.privileged: root
user.unprivileged: nobody

socksmethod: none
clientmethod: none

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp udp
}
EOF
}

write_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Socks5 Proxy (Dante)
After=network.target

[Service]
ExecStart=${SOCKD_BIN} -f ${CONF}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

ensure_sockd() {
  if [[ -x "$SOCKD_BIN" ]]; then
    return 0
  fi

  need_cmd wget wget
  need_cmd gcc gcc
  need_cmd g++ g++
  need_cmd make make

  cd /root
  rm -rf dante-1.4.2 dante-1.4.2.tar.gz
  wget -q https://www.inet.no/dante/files/dante-1.4.2.tar.gz
  tar -xzf dante-1.4.2.tar.gz
  cd dante-1.4.2
  ./configure >/dev/null
  make -j"$(nproc)" >/dev/null
  make install >/dev/null

  [[ -x "$SOCKD_BIN" ]] || { echo "sockd 安装失败"; exit 1; }
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
  echo
}

generate_s5() {
  ensure_sockd
  write_conf
  write_service
  open_port
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"
  echo "S5 已生成完成"
  print_info
}

show_info() {
  [[ -x "$SOCKD_BIN" ]] || { echo "S5 未生成"; return 1; }
  [[ -f "$CONF" ]] || { echo "S5 未生成"; return 1; }
  print_info
}

change_port() {
  [[ -f "$PORT_FILE" ]] || { generate_s5; return; }

  local old_port new_port
  old_port="$(cat "$PORT_FILE")"
  rm -f "$PORT_FILE"

  while true; do
    new_port=$((RANDOM % 50000 + 10000))
    port_in_use "$new_port" || break
  done

  echo "$new_port" > "$PORT_FILE"
  write_conf
  close_port "$old_port"
  open_port
  systemctl restart "$SERVICE_NAME"

  echo "端口已修改，原端口已失效"
  print_info
}

start_s5() {
  [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] || { generate_s5; return; }
  systemctl start "$SERVICE_NAME"
  echo "S5 已启动"
  print_info
}

stop_s5() {
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
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
