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

# 获取真实的公网 IP (解决内网 IP 10.x.x.x 问题)
get_ip() {
  local ip
  # 优先通过三个不同的 API 获取真实公网 IP
  ip=$(curl -s4 --connect-timeout 5 https://api.ipify.org || \
       curl -s4 --connect-timeout 5 https://ifconfig.me || \
       curl -s4 --connect-timeout 5 https://ip.sb)
  
  if [[ -z "$ip" ]]; then
    # 如果接口都挂了，才尝试本地获取
    ip=$(hostname -I | awk '{print $1}')
  fi
  echo "$ip"
}

detect_sockd_bin() {
  local p
  p="$(command -v sockd 2>/dev/null || true)"
  if [[ -n "${p:-}" && -x "$p" ]]; then
    echo "$p"
    return 0
  fi
  for p in /usr/sbin/sockd /usr/local/sbin/sockd; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

# 极速模式：优先使用官方 deb 包安装，跳过源码编译
ensure_sockd() {
  detect_sockd_bin >/dev/null 2>&1 && return 0

  log "检测到 sockd 未安装，启动极速部署模式..."
  
  local ARCH
  ARCH=$(dpkg --print-architecture)
  # 使用 Debian 官方存储池中的稳定预编译包
  local DEB_URL="http://ftp.cn.debian.org/debian/pool/main/d/dante/dante-server_1.4.2+dfsg-10_${ARCH}.deb"
  
  log "正在从官方获取预编译包..."
  if curl -L --connect-timeout 10 "$DEB_URL" -o /tmp/dante.deb; then
    dpkg -i /tmp/dante.deb || apt-get install -f -y >/dev/null 2>&1
    rm -f /tmp/dante.deb
  else
    log "极速模式下载失败，尝试 apt 标准安装..."
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

write_check_script() {
  cat > "$CHECK_SCRIPT" <<'EOF'
#!/usr/bin/env bash
PORT=$(cat /etc/danted_port 2>/dev/null || echo 1080)
[ -f "/tmp/s5_manual_stop" ] && exit 0
if ! ss -lnt | grep -q ":$PORT"; then
  systemctl restart s5 >/dev/null 2>&1
fi
EOF
  chmod +x "$CHECK_SCRIPT"
}

# (其余原有辅助函数保持不变)
port_in_use() { ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$1$"; }
rand_port() {
  local port
  while true; do
    port=$((RANDOM % 50000 + 10000))
    port_in_use "$port" || break
  done
  echo "$port"
}
get_port() { [[ -f "$PORT_FILE" ]] && cat "$PORT_FILE" || rand_port; }
install_cron_check() {
  command -v crontab >/dev/null 2>&1 || return 0
  (crontab -l 2>/dev/null | grep -v "$CHECK_SCRIPT" ; echo "*/2 * * * * $CHECK_SCRIPT") | crontab -
}
open_port() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$1/tcp" >/dev/null 2>&1; ufw allow "$1/udp" >/dev/null 2>&1
  fi
}
close_port() {
  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "$1/tcp" >/dev/null 2>&1; ufw delete allow "$1/udp" >/dev/null 2>&1
  fi
}
self_check() {
  local port="$1"
  detect_sockd_bin >/dev/null 2>&1 || return 1
  systemctl is-active "$SERVICE" >/dev/null 2>&1 || return 1
  ss -lnt | grep -q ":$port" || return 1
  return 0
}

print_info() {
  echo -e "\n--- S5 连接信息 ---"
  echo " $(get_ip)"
  echo " $(get_port)"
  echo " $DEFAULT_USER"
  echo " $DEFAULT_PASS"
  echo -e "格式: $(get_ip):$(get_port):$DEFAULT_USER:$DEFAULT_PASS\n"
}

generate_s5() {
  local port
  port="$(get_port)"
  echo "$port" > "$PORT_FILE"

  log "检查环境与安装 sockd..."
  ensure_sockd || { fail "安装失败"; return 1; }

  log "应用配置..."
  ensure_user
  write_conf "$port"
  write_service
  write_check_script
  install_cron_check
  open_port "$port"
  rm -f "$MANUAL_STOP_FLAG"

  log "启动服务..."
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE"
  
  sleep 1
  self_check "$port" || { fail "自检未通过"; return 1; }

  echo "S5 生成/修复完成"
  print_info
}

# (其余菜单函数 menu_ui, change_port, start_s5, stop_s5 保持原逻辑)
change_port() {
  local old_port new_port
  [[ -f "$PORT_FILE" ]] || { generate_s5; return $?; }
  old_port=$(get_port); new_port=$(rand_port)
  echo "$new_port" > "$PORT_FILE"
  write_conf "$new_port"
  close_port "$old_port"; open_port "$new_port"
  systemctl restart "$SERVICE"
  print_info
}

start_s5() { rm -f "$MANUAL_STOP_FLAG"; systemctl start "$SERVICE"; print_info; }
stop_s5() { touch "$MANUAL_STOP_FLAG"; systemctl stop "$SERVICE"; echo "S5 已停止"; }

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
    2) [[ -f "$PORT_FILE" ]] && print_info || echo "未生成" ;;
    3) change_port ;;
    4) start_s5 ;;
    5) stop_s5 ;;
    0) exit 88 ;;
    *) echo "无效选项" ;;
  esac
}

while true; do
  menu_ui
  read -rp "按回车返回菜单..." _
done
