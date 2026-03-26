#!/usr/bin/env bash
set -euo pipefail

APP_NAME="live_menu"
SCRIPT_NAME="live_menu.sh"

REAL_PATH="/usr/local/bin/${APP_NAME}.real"
WRAPPER_PATH="/usr/local/bin/${APP_NAME}"
BACKUP_DIR="/usr/local/lib/${APP_NAME}"
LOCAL_INSTALLER="/root/install_live_menu.sh"

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

normalize_file() {
  local f="$1"
  sed -i 's/\r$//' "$f" 2>/dev/null || true
}

download_main() {
  local url tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  for url in "${URLS[@]}"; do
    echo "[尝试下载] $url"

    if ! curl -fsSL --max-time 15 "$url" -o "$tmp" 2>/dev/null; then
      echo "[失败] 下载失败"
      continue
    fi

    normalize_file "$tmp"

    grep -q '^#!/usr/bin/env bash' "$tmp" || {
      echo "[跳过] 不是 bash 脚本"
      continue
    }

    if grep -qi '<!DOCTYPE html>\|<html' "$tmp"; then
      echo "[跳过] 返回的是 HTML 页面"
      continue
    fi

    if ! bash -n "$tmp" 2>/dev/null; then
      echo "[跳过] 语法检查失败"
      continue
    fi

    mkdir -p "$BACKUP_DIR"
    if [[ -f "$REAL_PATH" ]]; then
      cp "$REAL_PATH" "$BACKUP_DIR/live_menu.last"
      cp "$REAL_PATH" "$BACKUP_DIR/live_menu.$(date +%F-%H%M%S).bak"
    fi

    install -m 755 "$tmp" "$REAL_PATH"
    normalize_file "$REAL_PATH"

    echo "[成功] 已安装到 $REAL_PATH"
    return 0
  done

  echo "所有下载源都失败了"
  return 1
}

create_wrapper() {
  cat > "$WRAPPER_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REAL_PATH="/usr/local/bin/live_menu.real"
INSTALLER="/root/install_live_menu.sh"

case "${1:-run}" in
  update)
    exec bash "$INSTALLER" install
    ;;
  rollback)
    exec bash "$INSTALLER" rollback
    ;;
  path)
    echo "$REAL_PATH"
    ;;
  help|-h|--help)
    cat <<EOT
用法:
  live_menu           运行菜单
  live_menu update    从远端更新本地版本
  live_menu rollback  回滚到上一个版本
  live_menu path      查看本地路径
EOT
    ;;
  *)
    [[ -f "$REAL_PATH" ]] || { echo "主程序不存在，请先执行安装"; exit 1; }
    exec bash "$REAL_PATH"
    ;;
esac
EOF

  chmod +x "$WRAPPER_PATH"
  normalize_file "$WRAPPER_PATH"
}

rollback_main() {
  local last="${BACKUP_DIR}/live_menu.last"
  [[ -f "$last" ]] || { echo "没有可回滚版本"; exit 1; }
  cp "$last" "$REAL_PATH"
  chmod +x "$REAL_PATH"
  echo "[回滚完成]"
}

show_path() {
  echo "$REAL_PATH"
}

show_help() {
  cat <<EOF
用法:
  bash /root/install_live_menu.sh install   安装/更新到本地
  bash /root/install_live_menu.sh rollback  回滚到上一个版本
  bash /root/install_live_menu.sh path      查看安装路径

安装完成后可直接使用:
  live_menu
  live_menu update
  live_menu rollback
  live_menu path
EOF
}

self_fix() {
  if [[ -f "$LOCAL_INSTALLER" ]]; then
    normalize_file "$LOCAL_INSTALLER"
  fi
}

main() {
  self_fix
  need_cmd curl curl

  case "${1:-help}" in
    install)
      download_main
      create_wrapper
      echo "[完成] 现在可直接运行: live_menu"
      ;;
    rollback)
      rollback_main
      ;;
    path)
      show_path
      ;;
    *)
      show_help
      ;;
  esac
}

main "${1:-help}"
