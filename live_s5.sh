#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/danted.conf"
PASSFILE="/etc/danted_passwd"
PORT_FILE="/etc/danted_port"
SYSCTL_CONF="/etc/sysctl.d/99-live-s5.conf"
SERVICE="danted"
DEFAULT_USER="zxwl123"
DEFAULT_PASS="zxwl123"

[[ "$(id -u)" -ne 0 ]] && echo "请用 root 运行" && exit 1

need_pkg() {
  dpkg -s "$1" >/dev/null 2>&1 || {
    apt-get update -yq
    apt-get install -yq \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      "$1"
  }
}

install_deps() {
  need_pkg dante-server
  need_pkg apache2-utils
  need_pkg iproute2
  need_pkg curl
}

get_iface() {
  ip route | awk '/default/ {print $5; exit}'
}

get_ip() {
  curl -4 -s https://api.ipify.org || hostname -I | awk '{print $1}'
}

get_port() {
  [[ -f "$PORT_FILE" ]] && { cat "$PORT_FILE"; return; }

  local port
  while true; do
    port=$((RANDOM % 50000 + 10000))
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$port$" || break
  done

  echo "$port" > "$PORT_FILE"
  chmod 600 "$PORT_FILE"
  echo "$port"
}

write_sysctl() {
  cat >"$SYSCTL_CONF" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_no_metrics_save=1
net.core.somaxconn=4096
net.core.netdev_max_backlog=16384
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
  sysctl --system >/dev/null 2>&1 || true
}

write_conf() {
  local iface port
  iface="$(get_iface)"
  port="$(get_port)"

  cat >"$CONF" <<EOF
logoutput: syslog
internal: 0.0.0.0 port = ${port}
external: ${iface}

user.privileged: root
user.unprivileged: nobody
user.libwrap: nobody

socksmethod: username
clientmethod: none

timeout.negotiate: 30
timeout.io: 300

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: error connect disconnect
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp udp
  socksmethod: username
  log: error connect disconnect
}
EOF
}

ensure_passfile() {
  touch "$PASSFILE"
  chmod 600 "$PASSFILE"

  if ! grep -q "^${DEFAULT_USER}:" "$PASSFILE" 2>/dev/null; then
    htpasswd -bB "$PASSFILE" "$DEFAULT_USER" "$DEFAULT_PASS" >/dev/null 2>&1
    echo "已创建默认账号: ${DEFAULT_USER} / ${DEFAULT_PASS}"
  fi
}

write_service_override() {
  mkdir -p /etc/systemd/system/${SERVICE}.service.d
  cat >/etc/systemd/system/${SERVICE}.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=3

[Unit]
StartLimitIntervalSec=0
EOF
  systemctl daemon-reload
}

ensure_s5() {
  install_deps
  write_sysctl
  write_conf
  ensure_passfile
  write_service_override
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE"
  echo "S5 已完成初始化/修复"
}

list_users() {
  [[ -s "$PASSFILE" ]] || { echo "暂无用户"; return; }
  nl -w2 -s'. ' <(cut -d: -f1 "$PASSFILE")
}

user_by_index() {
  cut -d: -f1 "$PASSFILE" | sed -n "${1}p"
}

next_user_name() {
  local n
  n="$(cut -d: -f1 "$PASSFILE" 2>/dev/null | grep -E '^s5user[0-9]+$' | sed 's/s5user//' | sort -n | tail -n1)"
  [[ -z "${n:-}" ]] && n=0
  echo "s5user$((n+1))"
}

rand_pass() {
  tr -dc A-Za-z0-9 </dev/urandom | head -c 10
}

show_info() {
  ensure_s5 >/dev/null 2>&1 || true
  echo
  echo "地址: $(get_ip)"
  echo "端口: $(get_port)"
  echo "账号: ${DEFAULT_USER}"
  echo "密码: ${DEFAULT_PASS}"
  echo
  echo "当前用户:"
  list_users
  echo
}

add_user() {
  ensure_s5 >/dev/null 2>&1 || true
  local user pass
  user="$(next_user_name)"
  pass="$(rand_pass)"

  htpasswd -bB "$PASSFILE" "$user" "$pass" >/dev/null 2>&1
  systemctl restart "$SERVICE"

  echo
  echo "已新增用户"
  echo "地址: $(get_ip)"
  echo "端口: $(get_port)"
  echo "账号: $user"
  echo "密码: $pass"
  echo
}

delete_user() {
  ensure_s5 >/dev/null 2>&1 || true
  echo "当前用户:"
  list_users
  echo

  local idx user
  read -rp "请输入要删除的序号: " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || { echo "请输入数字序号"; return 1; }

  user="$(user_by_index "$idx")"
  [[ -n "${user:-}" ]] || { echo "序号无效"; return 1; }
  [[ "$user" == "$DEFAULT_USER" ]] && { echo "默认账号不建议删除"; return 1; }

  htpasswd -D "$PASSFILE" "$user" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE"
  echo "已删除用户: $user"
}

reset_user_pass() {
  ensure_s5 >/dev/null 2>&1 || true
  echo "当前用户:"
  list_users
  echo

  local idx user pass
  read -rp "请输入要重置密码的序号: " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || { echo "请输入数字序号"; return 1; }

  user="$(user_by_index "$idx")"
  [[ -n "${user:-}" ]] || { echo "序号无效"; return 1; }

  if [[ "$user" == "$DEFAULT_USER" ]]; then
    pass="$DEFAULT_PASS"
  else
    pass="$(rand_pass)"
  fi

  htpasswd -bB "$PASSFILE" "$user" "$pass" >/dev/null 2>&1
  systemctl restart "$SERVICE"

  echo
  echo "已重置密码"
  echo "地址: $(get_ip)"
  echo "端口: $(get_port)"
  echo "账号: $user"
  echo "密码: $pass"
  echo
}

regen_port() {
  rm -f "$PORT_FILE"
  write_conf
  systemctl restart "$SERVICE"
  echo "已重新生成随机端口: $(get_port)"
}

start_s5() {
  systemctl start "$SERVICE"
  echo "S5 已启动"
}

stop_s5() {
  systemctl stop "$SERVICE"
  echo "S5 已停止"
}

menu_ui() {
  clear
  cat <<EOF
==============================
         S5 管理菜单
==============================
1. 初始化 / 修复 S5
2. 查看 S5 信息
3. 新增用户
4. 删除用户
5. 重置密码
6. 重新生成随机端口
7. 启动 S5
8. 停止 S5
0. 返回上级菜单
==============================
EOF

  read -rp "请选择: " choice
  case "$choice" in
    1) ensure_s5 ;;
    2) show_info ;;
    3) add_user ;;
    4) delete_user ;;
    5) reset_user_pass ;;
    6) regen_port ;;
    7) start_s5 ;;
    8) stop_s5 ;;
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