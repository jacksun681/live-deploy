#!/usr/bin/env bash
set -u

CONF="/etc/danted.conf"
PORT_FILE="/etc/danted_port"
SERVICE="s5"
DEFAULT_USER="zxwl123"
DEFAULT_PASS="zxwl123"
MANUAL_STOP_FLAG="/tmp/s5_manual_stop"
CHECK_SCRIPT="/usr/local/bin/s5-check.sh"

SRC_DIR="/root/dante-1.4.2"
SRC_TAR="/root/dante-1.4.2.tar.gz"

[[ "$(id -u)" -ne 0 ]] && echo "请用 root 运行" && exit 1

log() { echo "[S5] $*"; }
fail() { echo "[S5] 失败: $*"; return 1; }

detect_sockd_bin() {
  local p
  p="$(command -v sockd 2>/dev/null || true)"
  [[ -n "${p:-}" && -x "$p" ]] && { echo "$p"; return 0; }
  for p in /usr/sbin/sockd /usr/local/sbin/sockd; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

get_ip() {
  local ip
  ip="$(curl -s4 --connect-timeout 4 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -s4 --connect-timeout 4 --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -s4 --connect-timeout 4 --max-time 8 https://ip.sb 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(hostname -I | awk '{print $1}')"
  echo "$ip"
}

ensure_base_tools() {
  command -v curl >/dev/null 2>&1 || {
    apt-get update -yq >/dev/null 2>&1 || true
    apt-get install -yq curl >/dev/null 2>&1 || true
  }
  command -v ss >/dev/null 2>&1 || {
    apt-get install -yq iproute2 >/dev/null 2>&1 || true
  }
  command -v crontab >/dev/null 2>&1 || {
    apt-get install -yq cron >/dev/null 2>&1 || true
  }
}

install_by_apt_fast() {
  apt-get install -yq dante-server >/dev/null 2>&1 || true
  detect_sockd_bin >/dev/null 2>&1 && return 0

  log "直接安装失败，刷新索引后重试..."
  apt-get update -yq >/dev/null 2>&1 || true
  apt-get install -yq dante-server >/dev/null 2>&1 || true
  detect_sockd_bin >/dev/null 2>&1
}

get_os_info() {
  OS_ID=""
  OS_CODENAME=""
  [[ -f /etc/os-release ]] || return 1
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  [[ -n "$OS_ID" && -n "$OS_CODENAME" ]]
}

write_debian_source() {
  local mirror="$1" codename="$2"
  cp /etc/apt/sources.list "/etc/apt/sources.list.bak.s5.$(date +%s)" 2>/dev/null || true
  cat > /etc/apt/sources.list <<EOF
deb ${mirror}/debian ${codename} main contrib non-free non-free-firmware
deb ${mirror}/debian ${codename}-updates main contrib non-free non-free-firmware
deb ${mirror}/debian-security ${codename}-security main contrib non-free non-free-firmware
EOF
}

write_ubuntu_source() {
  local mirror="$1" codename="$2"
  cp /etc/apt/sources.list "/etc/apt/sources.list.bak.s5.$(date +%s)" 2>/dev/null || true
  cat > /etc/apt/sources.list <<EOF
deb ${mirror}/ubuntu ${codename} main restricted universe multiverse
deb ${mirror}/ubuntu ${codename}-updates main restricted universe multiverse
deb ${mirror}/ubuntu ${codename}-security main restricted universe multiverse
EOF
}

install_by_multi_source() {
  local os codename mirror
  get_os_info || return 1
  os="$OS_ID"
  codename="$OS_CODENAME"

  if [[ "$os" == "debian" ]]; then
    for mirror in \
      "http://deb.debian.org" \
      "http://mirrors.aliyun.com" \
      "http://mirrors.tencent.com" \
      "https://mirrors.tuna.tsinghua.edu.cn" \
      "https://mirrors.ustc.edu.cn"
    do
      log "切换 Debian 源: $mirror"
      write_debian_source "$mirror" "$codename"
      apt-get clean >/dev/null 2>&1 || true
      apt-get update -yq >/dev/null 2>&1 || true
      apt-get install -yq dante-server >/dev/null 2>&1 || true
      detect_sockd_bin >/dev/null 2>&1 && return 0
    done
  elif [[ "$os" == "ubuntu" ]]; then
    for mirror in \
      "http://archive.ubuntu.com" \
      "http://mirrors.aliyun.com" \
      "http://mirrors.tencent.com" \
      "https://mirrors.tuna.tsinghua.edu.cn" \
      "https://mirrors.ustc.edu.cn"
    do
      log "切换 Ubuntu 源: $mirror"
      write_ubuntu_source "$mirror" "$codename"
      apt-get clean >/dev/null 2>&1 || true
      apt-get update -yq >/dev/null 2>&1 || true
      apt-get install -yq dante-server >/dev/null 2>&1 || true
      detect_sockd_bin >/dev/null 2>&1 && return 0
    done
  fi

  return 1
}

install_by_source() {
  log "最后尝试源码编译，可能需要数分钟..."

  apt-get update -yq >/dev/null 2>&1 || true
  apt-get install -yq wget curl tar make gcc build-essential iproute2 passwd cron >/dev/null 2>&1 || return 1

  cd /root || return 1
  rm -rf "$SRC_DIR" "$SRC_TAR"

  for url in \
    "https://www.inet.no/dante/files/dante-1.4.2.tar.gz" \
    "https://ghproxy.com/https://www.inet.no/dante/files/dante-1.4.2.tar.gz" \
    "https://mirror.ghproxy.com/https://www.inet.no/dante/files/dante-1.4.2.tar.gz"
  do
    log "下载源码包: $url"
    curl -L --connect-timeout 15 --max-time 120 -o "$SRC_TAR" "$url" >/dev/null 2>&1 || true
    [[ -s "$SRC_TAR" ]] && tar -tzf "$SRC_TAR" >/dev/null 2>&1 && break
    rm -f "$SRC_TAR"
  done

  [[ -s "$SRC_TAR" ]] || return 1
  tar -xzf "$SRC_TAR" || return 1
  cd "$SRC_DIR" || return 1

  ./configure CFLAGS="-Wno-error" >/tmp/dante-configure.log 2>&1 || return 1
  make -j"$(nproc)" >/tmp/dante-make.log 2>&1 || return 1
  make install >/tmp/dante-install.log 2>&1 || return 1

  detect_sockd_bin >/dev/null 2>&1
}

ensure_sockd() {
  detect_sockd_bin >/dev/null 2>&1 && return 0
  ensure_base_tools

  log "检测到 sockd 未安装，启动快速安装..."
  install_by_apt_fast && return 0

  log "快速安装失败，尝试多源自动切换..."
  install_by_multi_source && return 0

  log "多源安装失败，进入源码编译兜底..."
  install_by_source && return 0

  return 1
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
  [[ -f "$PORT_FILE" ]] && cat "$PORT_FILE" || rand_port
}

ensure_user() {
  id "$DEFAULT_USER" >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin "$DEFAULT_USER" >/dev/null 2>&1 || true
  echo "${DEFAULT_USER}:${DEFAULT_PASS}" | chpasswd >/dev/null 2>&1 || return 1
}

write_conf() {
  local port="$1" ip
  ip="$(get_ip)"

  cat > "$CONF" <<EOF
logoutput: stderr

internal: 0.0.0.0 port = ${port}
external: ${ip}

socksmethod: username

user.privileged: root
user.unprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
}
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
FLAG="/tmp/s5_manual_stop"

[ -f "$FLAG" ] && exit 0

if ! ss -lnt | grep -q ":$PORT"; then
  systemctl restart s5 >/dev/null 2>&1
fi
EOF
  chmod +x "$CHECK_SCRIPT"
}

install_cron_check() {
  command -v crontab >/dev/null 2>&1 || return 0
  local line="*/2 * * * * /usr/local/bin/s5-check.sh"
  (crontab -l 2>/dev/null | grep -v '/usr/local/bin/s5-check.sh' ; echo "$line") | crontab -
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
  local ip port
  ip="$(get_ip)"
  port="$(get_port)"

  echo
  echo "$ip"
  echo "$port"
  echo "$DEFAULT_USER"
  echo "$DEFAULT_PASS"
  echo
  echo "常用格式: ${ip}:${port}:${DEFAULT_USER}:${DEFAULT_PASS}"
  echo
}

self_check() {
  local port="$1"
  detect_sockd_bin >/dev/null 2>&1 || { echo "sockd 不存在"; return 1; }
  [[ -f "/etc/systemd/system/${SERVICE}.service" ]] || { echo "s5.service 不存在"; return 1; }
  systemctl is-active "$SERVICE" >/dev/null 2>&1 || { echo "s5.service 未运行"; return 1; }
  ss -lnt | grep -q ":$port" || { echo "端口未监听: $port"; return 1; }
  return 0
}

show_error_hint() {
  echo
  echo "[提示] 可执行以下命令排查："
  echo "which sockd"
  echo "apt update -y && apt install -y dante-server"
  echo "systemctl status s5 --no-pager -l"
  echo "journalctl -u s5 -n 50 --no-pager"
  echo "cat /tmp/dante-configure.log"
  echo "cat /tmp/dante-make.log"
  echo
}

generate_s5() {
  local port
  port="$(get_port)"
  [[ "$port" =~ ^[0-9]+$ ]] || port="$(rand_port)"
  echo "$port" > "$PORT_FILE"

  log "检查/安装 sockd..."
  ensure_sockd || { fail "sockd 安装失败"; show_error_hint; return 1; }

  log "写入账号..."
  ensure_user || { fail "账号写入失败"; show_error_hint; return 1; }

  log "写入配置..."
  write_conf "$port" || { fail "配置写入失败"; show_error_hint; return 1; }

  log "写入服务..."
  write_service || { fail "服务文件写入失败"; show_error_hint; return 1; }

  log "安装巡检..."
  write_check_script
  install_cron_check

  open_port "$port"
  rm -f "$MANUAL_STOP_FLAG"

  log "启动服务..."
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE" >/dev/null 2>&1 || {
    fail "s5 启动失败"
    show_error_hint
    return 1
  }

  sleep 1

  self_check "$port" || {
    fail "生成后自检失败"
    show_error_hint
    return 1
  }

  echo "S5 已生成完成"
  print_info
}

show_info() {
  [[ -f "$PORT_FILE" ]] || { echo "S5 未生成"; return 1; }
  print_info
}

change_port() {
  local old_port new_port

  [[ -f "$PORT_FILE" ]] || { generate_s5; return $?; }

  old_port="$(get_port)"
  new_port="$(rand_port)"
  echo "$new_port" > "$PORT_FILE"

  write_conf "$new_port" || { fail "配置写入失败"; return 1; }
  close_port "$old_port"
  open_port "$new_port"
  rm -f "$MANUAL_STOP_FLAG"

  systemctl restart "$SERVICE" >/dev/null 2>&1 || {
    fail "端口修改后服务重启失败"
    show_error_hint
    return 1
  }

  sleep 1

  self_check "$new_port" || {
    fail "修改端口后自检失败"
    show_error_hint
    return 1
  }

  echo "端口已修改，原端口已失效"
  print_info
}

start_s5() {
  [[ -f "/etc/systemd/system/${SERVICE}.service" ]] || { generate_s5; return $?; }

  rm -f "$MANUAL_STOP_FLAG"
  systemctl start "$SERVICE" >/dev/null 2>&1 || {
    fail "S5 启动失败"
    show_error_hint
    return 1
  }

  self_check "$(get_port)" || {
    fail "启动后自检失败"
    show_error_hint
    return 1
  }

  echo "S5 已启动"
  print_info
}

stop_s5() {
  touch "$MANUAL_STOP_FLAG"
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
    1) if ! generate_s5; then echo "[S5] 生成失败"; fi ;;
    2) if ! show_info; then echo "[S5] 查看失败"; fi ;;
    3) if ! change_port; then echo "[S5] 修改端口失败"; fi ;;
    4) if ! start_s5; then echo "[S5] 启动失败"; fi ;;
    5) if ! stop_s5; then echo "[S5] 停止失败"; fi ;;
    0) exit 88 ;;
    *) echo "无效选项" ;;
  esac
  return 0
}

while true; do
  rc=0
  menu_ui || rc=$?
  [[ "$rc" -eq 88 ]] && exit 88
  echo
  read -rp "按回车返回菜单..." _
done
