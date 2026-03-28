#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

MENU_REAL="/usr/local/bin/cast_menu.real"
DOCTOR_REAL="/usr/local/bin/cast_doctor.real"
CMD_PATH="/usr/local/bin/cast"
BACKUP_DIR="/usr/local/lib/cast"
LOCAL_INSTALLER="/root/install_cast.sh"

MENU_SCRIPT="cast_menu.sh"
DOCTOR_SCRIPT="cast_doctor.sh"

MENU_URLS=(
  "https://raw.githubusercontent.com/jacksun681/live-deploy/main/${MENU_SCRIPT}"
  "https://cdn.jsdelivr.net/gh/jacksun681/live-deploy@main/${MENU_SCRIPT}"
)

DOCTOR_URLS=(
  "https://raw.githubusercontent.com/jacksun681/live-deploy/main/${DOCTOR_SCRIPT}"
  "https://cdn.jsdelivr.net/gh/jacksun681/live-deploy@main/${DOCTOR_SCRIPT}"
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
    *)
      echo "暂不支持此架构: $(uname -m)"
      exit 1
      ;;
  esac

  return 0
}

install_deps() {
  need_cmd curl curl
  need_cmd jq jq
  return 0
}

download_one() {
  local dest="$1"
  shift

  local tmp=""
  tmp="$(mktemp)"
  trap '[ -n "${tmp:-}" ] && rm -f "$tmp"' RETURN

  local url
  for url in "$@"; do
    echo "[尝试下载] $url"

    if ! curl -fsSL --max-time 20 "$url" -o "$tmp" 2>/dev/null; then
      echo "[失败] 下载失败"
      continue
    fi

    normalize_file "$tmp"

    if ! grep -q '^#!/usr/bin/env bash' "$tmp"; then
      echo "[跳过] 不是 bash 脚本"
      continue
    fi

    if grep -qi '<!DOCTYPE html>\|<html' "$tmp"; then
      echo "[跳过] 返回的是 HTML 页面"
      continue
    fi

    if ! bash -n "$tmp" 2>/dev/null; then
      echo "[跳过] 语法检查失败"
      continue
    fi

    install -m 755 "$tmp" "$dest"
    normalize_file "$dest"

    echo "[成功] 已安装到 $dest"
    return 0
  done

  echo "[失败] 所有下载源都不可用"
  return 1
}

backup_old() {
  mkdir -p "$BACKUP_DIR"

  if [[ -f "$MENU_REAL" ]]; then
    cp "$MENU_REAL" "$BACKUP_DIR/cast_menu.last"
  fi

  if [[ -f "$DOCTOR_REAL" ]]; then
    cp "$DOCTOR_REAL" "$BACKUP_DIR/cast_doctor.last"
  fi

  return 0
}

create_wrapper() {
  cat > "$CMD_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MENU_REAL="/usr/local/bin/cast_menu.real"
DOCTOR_REAL="/usr/local/bin/cast_doctor.real"
INSTALLER="/root/install_cast.sh"

case "${1:-menu}" in
  doctor)
    shift
    exec bash "$DOCTOR_REAL" doctor "$@"
    ;;
  watch)
    shift
    exec bash "$DOCTOR_REAL" watch "$@"
    ;;
  update)
    exec bash "$INSTALLER" install
    ;;
  rollback)
    exec bash "$INSTALLER" rollback
    ;;
  path)
    echo "$MENU_REAL"
    ;;
  help|-h|--help)
    cat <<EOT
用法:
  cast            打开菜单
  cast doctor     打开诊断菜单
  cast watch      实时监控
  cast update     更新本地版本
  cast rollback   回滚到上一个版本
  cast path       查看主程序路径
EOT
    ;;
  *)
    exec bash "$MENU_REAL" "$@"
    ;;
esac
EOF

  chmod +x "$CMD_PATH"
  normalize_file "$CMD_PATH"
  return 0
}

rollback_main() {
  [[ -f "$BACKUP_DIR/cast_menu.last" ]] || { echo "没有可回滚的 cast_menu 版本"; exit 1; }
  [[ -f "$BACKUP_DIR/cast_doctor.last" ]] || { echo "没有可回滚的 cast_doctor 版本"; exit 1; }

  cp "$BACKUP_DIR/cast_menu.last" "$MENU_REAL"
  cp "$BACKUP_DIR/cast_doctor.last" "$DOCTOR_REAL"
  chmod +x "$MENU_REAL" "$DOCTOR_REAL"

  create_wrapper

  echo "[回滚完成]"
  return 0
}

show_help() {
  cat <<EOF
用法:
  bash /root/install_cast.sh install   安装/更新
  bash /root/install_cast.sh rollback  回滚
  bash /root/install_cast.sh path      查看路径

安装后可直接使用:
  cast
  cast doctor
  cast watch
  cast update
EOF
}

self_fix() {
  [[ -f "$LOCAL_INSTALLER" ]] && normalize_file "$LOCAL_INSTALLER"
  return 0
}

first_bootstrap() {
  if [[ -x "$MENU_REAL" ]]; then
    echo
    echo "[初始化] 正在自动初始化并输出主链接..."
    bash "$MENU_REAL" --bootstrap || true
  fi
  return 0
}

main() {
  self_fix
  precheck
  install_deps

  case "${1:-help}" in
    install)
      backup_old
      download_one "$MENU_REAL" "${MENU_URLS[@]}" || { echo "下载 cast_menu.sh 失败"; exit 1; }
      download_one "$DOCTOR_REAL" "${DOCTOR_URLS[@]}" || { echo "下载 cast_doctor.sh 失败"; exit 1; }
      create_wrapper
      echo "[完成] 已安装命令: cast"
      first_bootstrap
      ;;
    rollback)
      rollback_main
      ;;
    path)
      echo "$MENU_REAL"
      ;;
    *)
      show_help
      ;;
  esac

  return 0
}

main "${1:-help}"
