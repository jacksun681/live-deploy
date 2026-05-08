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

# 1. 极速获取真实公网 IP (解决 10.x.x.x 内网 IP 问题)
get_public_ip() {
  local ip
  ip=$(curl -s4 https://api.ipify.org || curl -s4 https://ifconfig.me || curl -s4 https://ip.sb)
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I | awk '{print $1}') # 保底逻辑
  fi
  echo "$ip"
}

# 2. 彻底移除编译，直接秒装
ensure_sockd() {
  if command -v sockd >/dev/null 2>&1; then return 0; fi
  
  log "正在从系统仓库秒装 dante-server..."
  # 针对 Debian 12 优化，直接安装，不更新全部索引以节省时间
  apt-get install -y dante-server >/dev/null 2>&1
  
  if ! command -v sockd >/dev/null 2>&1; then
    log "正在刷新索引并重试..."
    apt-get update -yq >/dev/null 2>&1
    apt-get install -y dante-server >/dev/null 2>&1
  fi
}

# 3. 极速配置与启动
generate_s5() {
  ensure_sockd
  
  local ip port
  ip=$(get_public_ip)
  # 如果没有记录端口，随机生成一个
  if [[ -f "$PORT_FILE" ]]; then
    port=$(cat "$PORT_FILE")
  else
    port=$((RANDOM % 40000 + 10000))
    echo "$port" > "$PORT_FILE"
  fi

  # 写入账号
  id "$DEFAULT_USER" &>/dev/null || useradd -M -s /usr/sbin/nologin "$DEFAULT_USER"
  echo "${DEFAULT_USER}:${DEFAULT_PASS}" | chpasswd

  # 写入精简配置
  cat > "$CONF" <<EOF
logoutput: stderr
internal: 0.0.0.0 port = ${port}
external: ${ip}
socksmethod: username
user.privileged: root
user.unprivileged: nobody
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
pass { from: 0.0.0.0/0 to: 0.0.0.0/0 protocol: tcp udp }
EOF

  # 写入 Service
  local sockd_bin
  sockd_bin=$(command -v sockd || echo "/usr/sbin/sockd")
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
  systemctl enable s5 &>/dev/null
  systemctl restart s5
  
  # 防火墙
  if command -v ufw &>/dev/null; then ufw allow "$port/tcp" &>/dev/null; fi

  echo -e "\n=== 部署成功 ==="
  echo "IP:   $ip"
  echo "端口: $port"
  echo "账号: $DEFAULT_USER"
  echo "密码: $DEFAULT_PASS"
  echo -e "格式: $ip:$port:$DEFAULT_USER:$DEFAULT_PASS\n"
}

# 菜单 UI
menu() {
  clear
  echo "Debian 12 极速 S5 管理器"
  echo "1. 一键生成 (秒级)"
  echo "2. 停止服务"
  echo "0. 退出"
  read -p "选择: " opt
  case $opt in
    1) generate_s5 ;;
    2) systemctl stop s5; echo "已停止" ;;
    *) exit ;;
  esac
}

while true; do menu; read -p "按回车继续..." _; done
