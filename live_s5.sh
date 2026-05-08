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

# 1. 强制获取真实公网 IP (彻底解决图中显示的 10.11.37.97 问题)
get_ip() {
  local ip
  # 依次尝试三个不同的公网接口，确保拿到的是外网地址
  ip=$(curl -s4 --connect-timeout 5 https://api.ipify.org || \
       curl -s4 --connect-timeout 5 https://ifconfig.me || \
       curl -s4 --connect-timeout 5 https://ip.sb)
  
  if [[ -z "$ip" || "$ip" == 10.* || "$ip" == 172.* || "$ip" == 192.* ]]; then
    # 如果接口失败或拿到的是内网 IP，尝试保底逻辑
    ip=$(curl -s4 --connect-timeout 5 http://whatismyip.akamai.com/)
  fi
  echo "$ip"
}

# 2. 针对你已经手动装好环境的 Debian 12 进行检测
ensure_sockd() {
  if command -v sockd >/dev/null 2>&1; then return 0; fi
  
  log "正在通过系统仓库极速安装..."
  # 既然你手动能装成功，脚本里直接调用同样命令
  apt-get update -yq >/dev/null 2>&1
  apt-get install -yq dante-server >/dev/null 2>&1
  
  if ! command -v sockd >/dev/null 2>&1; then
    echo "错误：无法自动安装 dante-server，请手动运行 apt-get install dante-server -y"
    return 1
  fi
}

# 3. 精准匹配你要求的输出格式
print_info() {
  local ip=$(get_ip)
  local port=$(cat "$PORT_FILE" 2>/dev/null || echo "未知")
  echo "--- S5 连接信息 ---"
  echo "$ip"
  echo "$port"
  echo "$DEFAULT_USER"
  echo "$DEFAULT_PASS"
  echo "格式：$ip:$port:$DEFAULT_USER:$DEFAULT_PASS"
  echo
}

# 4. 生成与配置逻辑
generate_s5() {
  # 端口处理
  local port
  if [[ -f "$PORT_FILE" ]]; then
    port=$(cat "$PORT_FILE")
  else
    port=$((RANDOM % 50000 + 10000))
    echo "$port" > "$PORT_FILE"
  fi

  log "检查环境与安装 sockd..."
  ensure_sockd || return 1
  
  # 账号处理
  id "$DEFAULT_USER" &>/dev/null || useradd -M -s /usr/sbin/nologin "$DEFAULT_USER"
  echo "${DEFAULT_USER}:${DEFAULT_PASS}" | chpasswd

  # 写入配置 (关键：必须使用外网 IP)
  local public_ip=$(get_ip)
  cat > "$CONF" <<EOF
logoutput: stderr
internal: 0.0.0.0 port = ${port}
external: ${public_ip}
method: username
user.privileged: root
user.unprivileged: nobody
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
pass { from: 0.0.0.0/0 to: 0.0.0.0/0 protocol: tcp udp }
EOF

  # 写入服务
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

# 菜单 UI (保持原样)
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
       rm -f "$PORT_FILE" # 强制重新生成端口
       generate_s5 
       ;;
    4) rm -f "$MANUAL_STOP_FLAG"; systemctl start "$SERVICE" 2>/dev/null; print_info ;;
    5) touch "$MANUAL_STOP_FLAG"; systemctl stop "$SERVICE" 2>/dev/null; echo "S5 已停止" ;;
    0) exit 88 ;;
  esac
}

while true; do menu_ui; read -rp "按回车继续..." _; done
