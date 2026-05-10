#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

REAL_PATH="/usr/local/bin/live_menu.real"
MENU_PATH="/usr/local/bin/menu"
URL="https://raw.githubusercontent.com/jacksun681/live-deploy/main/live_menu.sh"

[[ "$(id -u)" -ne 0 ]] && echo "请用 root 运行" && exit 1

command -v curl >/dev/null 2>&1 || {
  apt update -y
  apt install -y curl ca-certificates
}

curl -fsSL "$URL" -o "$REAL_PATH"
sed -i 's/\r$//' "$REAL_PATH"
chmod +x "$REAL_PATH"

cat > "$MENU_PATH" <<'EOF'
#!/usr/bin/env bash
bash /usr/local/bin/live_menu.real "$@"
EOF

chmod +x "$MENU_PATH"

bash "$REAL_PATH" --bootstrap
