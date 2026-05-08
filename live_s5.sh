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

# 1. 强制获取真实公网 IP (解决 10.11.x.x 问题)
get_ip() {
  local ip
  ip=$(curl -s4 --connect-timeout 5 https://api.ipify.org || \
       curl -s4 --connect-timeout 5 https://ifconfig.me || \
       curl -s4 --connect-timeout 5 https://ip.sb)
  [[ -z "$ip" ]] && ip=$(hostname -I | awk '{print $1}')
  echo "$ip"
}

# 2. 针对 Debian 13 的编译安装逻辑 (跳过寻找 deb 包)
ensure_sockd() {
  if command -v sockd >/dev/null 2>&1; then return 0; fi
  
  log "检测到 Debian 13 环境，正在准备编译环境 (约需 1-2 分钟)..."
  apt-get update -yq >/dev/null 2>&1
  apt-get install -yq build-essential libwrap0-dev libpam0g-dev libkrb5-dev libsasl2-dev curl >/dev/null 2>&1
  
  log "正在下载并编译 Dante 1.4.2..."
  cd /tmp
  curl -L -O https://www.inet.no/dante/files/dante-1.4.2.tar.gz
  tar -zxf dante-1.4.2.tar.gz
  cd dante-1.4.2
  ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --libdir=/usr/lib >/dev/null 2>&1
  make -j$(nproc) >/dev/null 2>&1
  make install >/dev/null 2>&1
  
  cd /tmp && rm -rf dante-1.4.2*
  command -v sockd >/dev/null 2>&1 || return 1
}

# 3. 输出格式对齐
print_info() {
  local ip=$(get_ip)
  local port=$(cat "$PORT_FILE" 2>/dev/null || echo "1080")
  echo "--- S5 连接信息 ---"
  echo "$ip"
  echo "$port"
  echo "$DEFAULT_USER"
  echo "$DEFAULT_PASS"
  echo "常用格式：$ip:$port:$DEFAULT_USER:$DEFAULT_PASS"
  echo
}

# 4. 生成与配置核心逻辑
generate_s5() {
  local port
  if [[ -f "$PORT_FILE" ]]; then port=$(cat "$PORT_FILE"); else port=$((RANDOM % 50000 + 10000)); echo "$port" > "$PORT_FILE"; fi
  
  log "检查环境与编译安装 sockd..."
  ensure_sockd || { echo "编译安装失败，请检查网络或联系支持"; return 1; }
  
  # 账号处理
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
    3) rm -f "$PORT_FILE"; generate_s5 ;;
    4) rm -f "$MANUAL_STOP_FLAG"; systemctl start "$SERVICE"; print_info ;;
    5) touch "$MANUAL_STOP_FLAG"; systemctl stop "$SERVICE"; echo "S5 已停止" ;;
    0) exit 88 ;;
  esac
}

while true; do menu_ui; read -rp "按回车继续..." _; done
