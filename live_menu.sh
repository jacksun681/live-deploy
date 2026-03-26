#!/usr/bin/env bash
set -euo pipefail

APP_NAME="live_menu"
INSTALL_PATH="/usr/local/bin/${APP_NAME}"
BACKUP_DIR="/usr/local/lib/${APP_NAME}"
TMP_FILE="/tmp/${APP_NAME}.$$"
SCRIPT_NAME="live_menu.sh"

URLS=(
  "https://raw.githubusercontent.com/jacksun681/live-deploy/main/${SCRIPT_NAME}"
  "https://cdn.jsdelivr.net/gh/jacksun681/live-deploy@main/${SCRIPT_NAME}"
)

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    apt update -y
    apt install -y "$2"
  }
}

download_script() {
  local url content
  for url in "${URLS[@]}"; do
    echo "[尝试下载] $url"
    content="$(curl -fsSL --max-time 12 "$url" 2>/dev/null || true)"
    [ -z "$content" ] && continue

    # 必须是 bash 脚本，不接受 HTML 错误页
    echo "$content" | grep -q '^#!/usr/bin/env bash' || {
      echo "[跳过] 非 bash 脚本"
      continue
    }

    printf '%s\n' "$content" > "$TMP_FILE"

    # 语法检查
    if bash -n "$TMP_FILE" 2>/dev/null; then
      echo "[成功] 下载并校验通过"
      return 0
    else
      echo "[跳过] 语法校验失败"
    fi
  done

  return 1
}

backup_current() {
  mkdir -p "$BACKUP_DIR"
  if [ -f "$INSTALL_PATH" ]; then
    cp "$INSTALL_PATH" "$BACKUP_DIR/${APP_NAME}.$(date +%F-%H%M%S).bak"
    cp "$INSTALL_PATH" "$BACKUP_DIR/${APP_NAME}.last"
    echo "[备份] 当前版本已备份"
  fi
}

install_script() {
  install -m 755 "$TMP_FILE" "$INSTALL_PATH"
  rm -f "$TMP_FILE"
  echo "[安装完成] $INSTALL_PATH"
}

run_local() {
  if [ -f "$INSTALL_PATH" ]; then
    exec bash "$INSTALL_PATH"
  else
    echo "未安装 ${APP_NAME}，请先执行: bash /root/install_live_menu.sh install"
    exit 1
  fi
}

rollback_script() {
  if [ -f "$BACKUP_DIR/${APP_NAME}.last" ]; then
    cp "$BACKUP_DIR/${APP_NAME}.last" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    echo "[回滚完成] 已恢复到上一个版本"
  else
    echo "没有可回滚的版本"
    exit 1
  fi
}

show_path() {
  echo "$INSTALL_PATH"
}

show_help() {
  cat <<EOF
用法:
  bash /root/install_live_menu.sh install   安装/更新到本地
  bash /root/install_live_menu.sh run       运行本地版本
  bash /root/install_live_menu.sh rollback  回滚到上一个版本
  bash /root/install_live_menu.sh path      查看安装路径

安装完成后可直接使用:
  live_menu          运行菜单
  live_menu update   从远端更新本地版本
  live_menu rollback 回滚到上一个版本
  live_menu path     查看本地路径
EOF
}

create_wrapper() {
  cat > /usr/local/bin/live_menu <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

INSTALLER="/root/install_live_menu.sh"
APP_PATH="/usr/local/bin/live_menu.real"

if [ ! -f "$APP_PATH" ] && [ -f "/usr/local/bin/live_menu" ]; then
  :
fi

case "${1:-run}" in
  update)
    exec bash "$INSTALLER" install
    ;;
  rollback)
    exec bash "$INSTALLER" rollback
    ;;
  path)
    exec bash "$INSTALLER" path
    ;;
  help|-h|--help)
    exec bash "$INSTALLER"
    ;;
  *)
    if [ -f "$APP_PATH" ]; then
      exec bash "$APP_PATH"
    elif [ -f "/usr/local/bin/live_menu.real" ]; then
      exec bash "/usr/local/bin/live_menu.real"
    else
      echo "本地主程序不存在，请先执行: bash /root/install_live_menu.sh install"
      exit 1
    fi
    ;;
esac
EOF
  chmod +x /usr/local/bin/live_menu
}

install_main_as_real() {
  install -m 755 "$TMP_FILE" /usr/local/bin/live_menu.real
  rm -f "$TMP_FILE"
  echo "[安装完成] /usr/local/bin/live_menu.real"
}

backup_real() {
  mkdir -p "$BACKUP_DIR"
  if [ -f /usr/local/bin/live_menu.real ]; then
    cp /usr/local/bin/live_menu.real "$BACKUP_DIR/${APP_NAME}.last"
    cp /usr/local/bin/live_menu.real "$BACKUP_DIR/${APP_NAME}.$(date +%F-%H%M%S).bak"
    echo "[备份] 当前主程序已备份"
  fi
}

action="${1:-help}"

need_cmd curl curl

case "$action" in
  install)
    if download_script; then
      backup_real
      install_main_as_real
      create_wrapper
      echo "[完成] 现在可直接使用: live_menu"
    else
      echo "下载失败：所有源都不可用或返回内容非法"
      exit 1
    fi
    ;;
  run)
    if [ -f /usr/local/bin/live_menu.real ]; then
      exec bash /usr/local/bin/live_menu.real
    else
      echo "未安装主程序，请先执行: bash /root/install_live_menu.sh install"
      exit 1
    fi
    ;;
  rollback)
    if [ -f "$BACKUP_DIR/${APP_NAME}.last" ]; then
      cp "$BACKUP_DIR/${APP_NAME}.last" /usr/local/bin/live_menu.real
      chmod +x /usr/local/bin/live_menu.real
      echo "[回滚完成] 已恢复到上一个版本"
    else
      echo "没有可回滚版本"
      exit 1
    fi
    ;;
  path)
    echo "/usr/local/bin/live_menu.real"
    ;;
  help|*)
    show_help
    ;;
esac
