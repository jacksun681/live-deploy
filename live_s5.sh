#!/usr/bin/env bash
set -u

CONF="/etc/danted.conf"
PORT_FILE="/etc/danted_port"
SERVICE="s5"
DEFAULT_USER="zxwl123"
DEFAULT_PASS="zxwl123"
MANUAL_STOP_FLAG="/tmp/s5_manual_stop"
CHECK_SCRIPT="/usr/local/bin/s5-check.sh"

[[ "$(id -u)" -ne 0 ]] && echo "请用 root 运行" && exit 1

log() { echo "[S5] $*"; }
fail() { echo "[S5] 失败: $*"; return 1; }

get_ip() {
  local ip
  ip=$(curl -s4 --connect-timeout 5 https://api.ipify.org || \
       curl -s4 --connect-timeout 5 https://ifconfig.me || \
       curl -s4 --connect-timeout 5 https://ip.sb)
  [[ -z "$ip" ]] && ip=$(hostname -I | awk '{print $1}')
  echo "$ip"
}

detect_sockd_bin() {
  local p
  p="$(command -v sockd 2>/dev/null || true)"
  if [[ -n "${p:-}" && -x "$p" ]]; then echo "$p"; return 0; fi
  for p in /usr/sbin/sockd /usr/local/sbin/sockd; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done
  return 1
}

ensure_sockd() {
  detect_sockd_bin >/dev/null 2>&1 && return 0

  log "检测到 sockd 未安装，启动极速部署模式..."
  local ARCH
  ARCH=$(dpkg --print-architecture)
  
  # 优先使用镜像源下载 deb，防止官方源在境内连接重置
  local DEB_URL="https://mirrors.ustc.edu.cn/debian/pool/main/d/dante/dante-server_1.4.2+dfsg-10_${ARCH}.deb"
  
  log "正在获取预编译包..."
  if curl -L --connect-timeout 10 "$DEB_URL" -o /tmp/dante.deb && [ -s /tmp/dante.deb ]; then
    dpkg -i /tmp/dante.deb || apt-get install -f -y >/dev/null 2>&1
    rm -f /tmp/dante.deb
  else
    log "极速模式受阻，尝试标准安装..."
    apt-get update -yq >/dev/null 2>&1 || true
    apt-get install -yq dante-server >/dev/null 2>&1
  fi

  detect_sockd_bin >/dev/null 2>&1 || return 1
}

ensure_user() {
  if ! id "$DEFAULT_USER" >/dev/null 2>&1; then
    useradd -M -s /usr/sbin/nologin "$DEFAULT_USER" >/dev/null 2>&1 || true
  fi
  echo "${DEFAULT_USER}:${DEFAULT_PASS}" | chpasswd >/dev/null 2>&1 || return 1
}

write_conf() {
  local port="$1"
  local ip
  ip="$(get_ip)"
  cat > "$CONF" <<EOF
logoutput: stderr
internal: 0.0.0.0 port = ${port}
external: ${ip}
method: username
user.privileged: root
user.unprivileged: nobody
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
pass { from: 0.0.0.0/0 to: 0.0.0.0/0 protocol: tcp udp }
EOF
}

write_service() {
  local sockd_bin
  sockd_bin="$(detect_sockd_bin)" || return 1
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=S5 Proxy
After=network.target
[Service]
ExecStart=${sockd_bin} -f ${CONF}
Restart=always
RestartSec=2
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

port_in_use() { ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$1$"; }
rand_port() {
  local port
  while true; do port=$((RANDOM % 50000 + 10000)); port_in_use "$port" || break; done
  echo "$port"
}
get_port() { [[ -f "$PORT_FILE" ]] && cat "$PORT_FILE" || rand_port; }

# 按图片要求精准输出信息
print_info() {
  local ip
  ip=$(get_ip)
  local port
  port=$(get_port)
  echo "--- S5 连接信息 ---"
  echo "$ip"
  echo "$port"
  echo "$DEFAULT_USER"
  echo "$DEFAULT_PASS"
  echo "格式：$ip:$port:$DEFAULT_USER:$DEFAULT_PASS"
  echo
}

generate_s5() {
  local port
  port="$(get_port)"
  echo "$port" > "$PORT_FILE"
  
  log "检查环境与安装 sockd..."
  ensure_sockd || { fail "安装失败"; return 1; }
  
  log "写入账号..."
  ensure_user
  
  log "写入配置..."
  write_conf "$port"
  
  log "写入服务..."
  write_service
  
  if command -v ufw >/dev/null 2>&1; then ufw allow "$port/tcp" >/dev/null 2>&1; fi
  
  rm -f "$MANUAL_STOP_FLAG"
  log "启动服务..."
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE"
  
  echo "S5 已生成完成"
  echo
  print_info
}

menu_ui() {
  clear
  cat <<EOF
==============================
      S5 极速管理菜单
==============================
1. 生成 S5
2. 查看 S5 信息
3. 修改端口 (随机)
4. 启动 S5
5. 停止 S5
0. 返回上级菜单
==============================
EOF
  read -rp "请选择: " choice
  case "$choice" in
    1) generate_s5 ;;
    2) [[ -f "$PORT_FILE" ]] && print_info || echo "S5 未生成" ;;
    3) 
       old_port=$(get_port)
       new_port=$(rand_port)
       echo "$new_port" > "$PORT_FILE"
       write_conf "$new_port"
       systemctl restart "$SERVICE" || echo "Failed to restart s5.service"
       print_info 
       ;;
    4) rm -f "$MANUAL_STOP_FLAG"; systemctl start "$SERVICE"; print_info ;;
    5) touch "$MANUAL_STOP_FLAG"; systemctl stop "$SERVICE"; echo "S5 已停止" ;;
    0) exit 88 ;;
  esac
}

while true; do menu_ui; read -rp "按回车返回菜单..." _; done
