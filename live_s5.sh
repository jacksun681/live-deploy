#!/usr/bin/env bash
set -u

CONF="/etc/danted.conf"
PORT_FILE="/etc/danted_port"
SERVICE="s5"
DEFAULT_USER="zxwl123"
DEFAULT_PASS="zxwl123"
MANUAL_STOP_FLAG="/tmp/s5_manual_stop"

[[ "$(id -u)" -ne 0 ]] && echo "请用 root 运行" && exit 1

log() { echo "[S5] $*"; }

# 1. 极速公网 IP 获取逻辑 (解决 10.x 内网 IP 问题)
get_ip() {
  local ip
  ip=$(curl -s4 --connect-timeout 5 https://api.ipify.org || \
       curl -s4 --connect-timeout 5 https://ifconfig.me || \
       curl -s4 --connect-timeout 5 https://ip.sb)
  [[ -z "$ip" ]] && ip=$(hostname -I | awk '{print $1}')
  echo "$ip"
}

# 2. 针对 Debian 12 的极速安装
ensure_sockd() {
  if command -v sockd >/dev/null 2>&1; then return 0; fi
  
  log "正在通过系统仓库极速安装..."
  # 因为你手动执行 apt 已经成功，这里直接调用系统安装即可
  apt-get update -yq >/dev/null 2>&1
  apt-get install -yq dante-server >/dev/null 2>&1
  
  command -v sockd >/dev/null 2>&1 || return 1
}

# 3. 端口管理
port_in_use() { ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$1$"; }
rand_port() {
  local port
  while true; do port=$((RANDOM % 50000 + 10000)); port_in_use "$port" || break; done
  echo "$port"
}
get_port() { [[ -f "$PORT_FILE" ]] && cat "$PORT_FILE" || rand_port; }

# 4. 精准对齐你的图片输出格式
print_info() {
  local ip=$(get_ip)
  local port=$(get_port)
  echo "--- S5 连接信息 ---"
  echo "$ip"
  echo "$port"
  echo "$DEFAULT_USER"
  echo "$DEFAULT_PASS"
  echo "格式：$ip:$port:$DEFAULT_USER:$DEFAULT_PASS"
  echo
}

# 5. 生成/修复核心逻辑
generate_s5() {
  local port=$(get_port)
  echo "$port" > "$PORT_FILE"
  
  log "检查环境与安装 sockd..."
  ensure_sockd || { echo "安装失败，请手动运行 apt install dante-server"; return 1; }
  
  # 写入账号
  id "$DEFAULT_USER" &>/dev/null || useradd -M -s /usr/sbin/nologin "$DEFAULT_USER"
  echo "${DEFAULT_USER}:${DEFAULT_PASS}" | chpasswd
  
  # 写入配置 (使用识别到的公网 IP)
  local ip=$(get_ip)
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

  # 写入服务并启动
  local sockd_bin=$(command -v sockd || echo "/usr/sbin/sockd")
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=S5 Proxy
After=network.target
[Service]
ExecStart=${sockd_bin} -f ${CONF}
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE" &>/dev/null
  systemctl restart "$SERVICE"
  rm -f "$MANUAL_STOP_FLAG"
  
  echo "S5 已生成完成"
  echo
  print_info
}

# 菜单 UI
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
       new_port=$(rand_port)
       echo "$new_port" > "$PORT_FILE"
       generate_s5
       ;;
    4) rm -f "$MANUAL_STOP_FLAG"; systemctl start "$SERVICE"; print_info ;;
    5) touch "$MANUAL_STOP_FLAG"; systemctl stop "$SERVICE"; echo "S5 已停止" ;;
    0) exit 88 ;;
  esac
}

while true; do menu_ui; read -rp "按回车继续..." _; done
