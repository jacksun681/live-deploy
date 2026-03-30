#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

REAL_PATH="/usr/local/bin/live_menu.real"
S5_REAL="/usr/local/bin/live_s5.real"
MENU_PATH="/usr/local/bin/menu"
COMPAT_PATH="/usr/local/bin/live_menu"
BACKUP_DIR="/usr/local/lib/live_menu"
LOCAL_INSTALLER="/root/install_live_menu.sh"
SCRIPT_NAME="live_menu.sh"
SCRIPT_S5="live_s5.sh"

URLS=(
  "https://raw.githubusercontent.com/jacksun681/live-deploy/main/${SCRIPT_NAME}"
  "https://cdn.jsdelivr.net/gh/jacksun681/live-deploy@main/${SCRIPT_NAME}"
)

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    apt-get update -yq
    apt-get install -yq \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      "$2"
  }
}

normalize_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  sed -i 's/\r$//' "$f" 2>/dev/null || true
}

precheck() {
  [[ "$(id -u)" -eq 0 ]] || { echo "请用 root 运行"; exit 1; }
  command -v systemctl >/dev/null 2>&1 || { echo "系统缺少 systemd"; exit 1; }
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) echo "暂不支持此架构: $(uname -m)"; exit 1 ;;
  esac
  return 0
}

install_deps() {
  need_cmd curl curl
  need_cmd jq jq
  return 0
}

download_main() {
  local url tmp=""
  tmp="$(mktemp)"
  trap '[ -n "${tmp:-}" ] && rm -f "$tmp"' RETURN

  for url in "${URLS[@]}"; do
    echo "[尝试下载] $url"

    if ! curl -fsSL --max-time 20 "$url" -o "$tmp" 2>/dev/null; then
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

# ===== 新增：下载 S5 模块 =====
download_s5() {
  local base_url s5_url tmp=""
  tmp="$(mktemp)"
  trap '[ -n "${tmp:-}" ] && rm -f "$tmp"' RETURN

  for base_url in "${URLS[@]}"; do
    s5_url="${base_url%/*}/${SCRIPT_S5}"
    echo "[尝试下载] $s5_url"

    if ! curl -fsSL --max-time 20 "$s5_url" -o "$tmp" 2>/dev/null; then
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

    install -m 755 "$tmp" "$S5_REAL"
    normalize_file "$S5_REAL"

    echo "[成功] 已安装到 $S5_REAL"
    return 0
  done

  echo "[提示] S5 模块下载失败，主菜单仍可正常使用"
  return 0
}
# ===== 新增结束 =====

create_wrapper() {
  cat > "$MENU_PATH" <<'EOF'
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
  menu            运行菜单
  menu update     更新本地版本
  menu rollback   回滚到上一个版本
  menu path       查看主程序路径

兼容旧命令:
  live_menu
EOT
    ;;
  *)
    [[ -f "$REAL_PATH" ]] || { echo "主程序不存在，请先执行安装"; exit 1; }
    exec bash "$REAL_PATH" "$@"
    ;;
esac
EOF

  chmod +x "$MENU_PATH"
  normalize_file "$MENU_PATH"
  ln -sf "$MENU_PATH" "$COMPAT_PATH"
  return 0
}

rollback_main() {
  local last="${BACKUP_DIR}/live_menu.last"
  [[ -f "$last" ]] || { echo "没有可回滚版本"; exit 1; }
  cp "$last" "$REAL_PATH"
  chmod +x "$REAL_PATH"
  create_wrapper
  echo "[回滚完成]"
  return 0
}

show_help() {
  cat <<EOF
用法:
  bash /root/install_live_menu.sh install   安装/更新
  bash /root/install_live_menu.sh rollback  回滚
  bash /root/install_live_menu.sh path      查看路径
EOF
  return 0
}

self_fix() {
  [[ -f "$LOCAL_INSTALLER" ]] && normalize_file "$LOCAL_INSTALLER"
  return 0
}

first_bootstrap() {
  if [[ -x "$REAL_PATH" ]]; then
    echo
    echo "[初始化] 正在自动初始化并输出主链接..."
    bash "$REAL_PATH" --bootstrap || true
  fi
  return 0
}

main() {
  self_fix
  precheck
  install_deps

  case "${1:-help}" in
    install)
      download_main
      download_s5
      create_wrapper
      echo "[完成] 已安装菜单命令: menu"
      first_bootstrap
      ;;
    rollback)
      rollback_main
      ;;
    path)
      echo "$REAL_PATH"
      ;;
    *)
      show_help
      ;;
  esac

  return 0
}

main "${1:-help}"
