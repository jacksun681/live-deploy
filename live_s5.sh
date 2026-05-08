#!/usr/bin/env bash
set -u

XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_SERVICE="xray"

PORT_FILE="/etc/xray_s5_port"
USER_FILE="/etc/xray_s5_user"
PASS_FILE="/etc/xray_s5_pass"
TAG="s5-in"

DEFAULT_USER="zxwl123"
DEFAULT_PASS="zxwl123"

[[ "$(id -u)" -ne 0 ]] && echo "请用 root 运行" && exit 1

log(){ echo "[S5] $*"; }
fail(){ echo "[S5] 失败: $*"; return 1; }

get_ip() {
  local ip
  ip="$(curl -s4 --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -s4 --connect-timeout 3 --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -s4 --connect-timeout 3 --max-time 5 https://ip.sb 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(hostname -I | awk '{print $1}')"
  echo "$ip"
}

need_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  apt-get update -yq >/dev/null 2>&1 || true
  apt-get install -yq jq curl iproute2 >/dev/null 2>&1 || return 1
}

port_in_use() {
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$1$"
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

get_user() {
  [[ -f "$USER_FILE" ]] && cat "$USER_FILE" || echo "$DEFAULT_USER"
}

get_pass() {
  [[ -f "$PASS_FILE" ]] && cat "$PASS_FILE" || echo "$DEFAULT_PASS"
}

ensure_xray() {
  [[ -f "$XRAY_CONF" ]] || { fail "未找到 Xray 配置: $XRAY_CONF"; return 1; }
  command -v xray >/dev/null 2>&1 || { fail "未找到 xray 命令"; return 1; }
}

test_xray_config() {
  local file="$1"
  xray test -config "$file" >/dev/null 2>&1
}

restart_xray_with_rollback() {
  local bak="$1"

  systemctl restart "$XRAY_SERVICE" >/dev/null 2>&1 && return 0

  cp "$bak" "$XRAY_CONF" 2>/dev/null || true
  systemctl restart "$XRAY_SERVICE" >/dev/null 2>&1 || true
  fail "Xray 重启失败，已回滚配置"
  return 1
}

write_s5_to_xray() {
  local port user pass tmp bak
  port="$1"
  user="$2"
  pass="$3"

  tmp="/tmp/xray_s5_config.json"
  bak="${XRAY_CONF}.bak.s5.$(date +%s)"

  cp "$XRAY_CONF" "$bak" || return 1

  jq \
    --arg tag "$TAG" \
    --argjson port "$port" \
    --arg user "$user" \
    --arg pass "$pass" \
    '
    .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) |
    .inbounds += [{
      "tag": $tag,
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": $user,
            "pass": $pass
          }
        ],
        "udp": true
      }
    }]
    ' "$XRAY_CONF" > "$tmp" || return 1

  test_xray_config "$tmp" || {
    rm -f "$tmp"
    fail "新配置检测失败，未覆盖原配置"
    return 1
  }

  cp "$tmp" "$XRAY_CONF" || return 1
  rm -f "$tmp"

  restart_xray_with_rollback "$bak"
}

remove_s5_from_xray() {
  local tmp bak
  tmp="/tmp/xray_s5_remove.json"
  bak="${XRAY_CONF}.bak.s5.remove.$(date +%s)"

  cp "$XRAY_CONF" "$bak" || return 1

  jq --arg tag "$TAG" '
    .inbounds = ((.inbounds // []) | map(select(.tag != $tag)))
  ' "$XRAY_CONF" > "$tmp" || return 1

  test_xray_config "$tmp" || {
    rm -f "$tmp"
    fail "删除后配置检测失败"
    return 1
  }

  cp "$tmp" "$XRAY_CONF" || return 1
  rm -f "$tmp"

  restart_xray_with_rollback "$bak"
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
  local ip port user pass
  ip="$(get_ip)"
  port="$(get_port)"
  user="$(get_user)"
  pass="$(get_pass)"

  echo
  echo "$ip"
  echo "$port"
  echo "$user"
  echo "$pass"
  echo
  echo "常用格式: ${ip}:${port}:${user}:${pass}"
  echo
}

generate_s5() {
  local port user pass

  ensure_xray || return 1
  need_jq || { fail "jq 安装失败"; return 1; }

  port="$(get_port)"
  [[ "$port" =~ ^[0-9]+$ ]] || port="$(rand_port)"
  user="$(get_user)"
  pass="$(get_pass)"

  echo "$port" > "$PORT_FILE"
  echo "$user" > "$USER_FILE"
  echo "$pass" > "$PASS_FILE"

  log "写入 Xray SOCKS5 入站..."
  write_s5_to_xray "$port" "$user" "$pass" || return 1

  open_port "$port"

  echo "S5 已生成完成"
  print_info
}

show_info() {
  [[ -f "$PORT_FILE" ]] || { echo "S5 未生成"; return 1; }
  print_info
}

change_port() {
  local old_port new_port user pass

  ensure_xray || return 1
  need_jq || { fail "jq 安装失败"; return 1; }

  old_port="$(get_port)"
  new_port="$(rand_port)"
  user="$(get_user)"
  pass="$(get_pass)"

  echo "$new_port" > "$PORT_FILE"

  write_s5_to_xray "$new_port" "$user" "$pass" || return 1

  close_port "$old_port"
  open_port "$new_port"

  echo "端口已修改，原端口已失效"
  print_info
}

start_s5() {
  generate_s5
}

stop_s5() {
  ensure_xray || return 1
  need_jq || { fail "jq 安装失败"; return 1; }

  remove_s5_from_xray || return 1
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
