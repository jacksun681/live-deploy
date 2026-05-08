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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 && return 0
  apt-get update -yq >/dev/null 2>&1 || true
  apt-get install -yq "$2" >/dev/null 2>&1 || return 1
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
  [[ -f "$PORT_FILE" ]] && cat "$PORT_FILE" || rand_port
}

ensure_deps() {
  need_cmd wget wget || return 1
  need_cmd curl curl || return 1
  need_cmd tar tar || return 1
  need_cmd make build-essential || return 1
  need_cmd gcc build-essential || return 1
  need_cmd ss iproute2 || return 1
  need_cmd useradd passwd || return 1
  need_cmd chpasswd passwd || return 1
  need_cmd crontab cron || true
  return 0
}

download_with_retry() {
  local out="$1"
  shift
  local urls=("$@")
  local url
  local tries

  rm -f "$out"

  for url in "${urls[@]}"; do
    for tries in 1 2 3; do
      log "下载: $url (第 ${tries} 次)"
      if command -v curl >/dev/null 2>&1; then
        curl -L --connect-timeout 15 --max-time 120 -o "$out" "$url" >/dev/null 2>&1 || true
      else
        wget -O "$out" "$url" >/dev/null 2>&1 || true
      fi

      if [[ -s "$out" ]] && tar -tzf "$out" >/dev/null 2>&1; then
        return 0
      fi

      rm -f "$out"
      sleep 2
    done
  done

  return 1
}

install_sockd_by_apt() {
  apt-get update -yq >/dev/null 2>&1 || true
  apt-get install -yq dante-server >/dev/null 2>&1 || return 1
  detect_sockd_bin >/dev/null 2>&1
}

install_sockd_by_source() {
  ensure_deps || return 1

  cd /root || return 1
  rm -rf "$SRC_DIR" "$SRC_TAR"

  download_with_retry "$SRC_TAR" \
    "https://www.inet.no/dante/files/dante-1.4.2.tar.gz" \
    "https://ghproxy.com/https://www.inet.no/dante/files/dante-1.4.2.tar.gz" \
    "https://mirror.ghproxy.com/https://www.inet.no/dante/files/dante-1.4.2.tar.gz" \
    || return 1

  tar -xzf "$SRC_TAR" || return 1
  cd "$SRC_DIR" || return 1

  ./configure CFLAGS="-Wno-error" >/tmp/dante-configure.log 2>&1 || return 1
  make -j"$(nproc)" >/tmp/dante-make.log 2>&1 || return 1
  make install >/tmp/dante-install.log 2>&1 || return 1

  detect_sockd_bin >/dev/null 2>&1
}

ensure_sockd() {
  detect_sockd_bin >/dev/null 2>&1 && return 0

  log "尝试通过 apt 安装 dante-server..."
  if install_sockd_by_apt; then
    return 0
  fi

  log "apt 安装失败，尝试源码编译..."
  if install_sockd_by_source; then
    return 0
  fi

  return 1
}

ensure_user() {
  useradd -M -s /usr/sbin/nologin "$DEFAULT_USER" >/dev/null 2>&1 || true
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
  echo
  echo "$(get_ip)"
  echo "$(get_port)"
  echo "$DEFAULT_USER"
  echo "$DEFAULT_PASS"
  echo
}

self_check() {
  local port="$1"
  local sockd_bin

  sockd_bin="$(detect_sockd_bin || true)"
  [[ -n "${sockd_bin:-}" ]] || { echo "sockd 不存在"; return 1; }
  [[ -f "/etc/systemd/system/${SERVICE}.service" ]] || { echo "s5.service 不存在"; return 1; }
  systemctl is-active "$SERVICE" >/dev/null 2>&1 || { echo "s5.service 未运行"; return 1; }
  ss -lnt | grep -q ":$port" || { echo "端口未监听: $port"; return 1; }
  return 0
}

show_error_hint() {
  echo
  echo "[提示] 可执行以下命令排查："
  echo "which sockd"
  echo "systemctl status s5 --no-pager -l"
  echo "journalctl -u s5 -n 50 --no-pager"
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
