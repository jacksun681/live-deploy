#!/usr/bin/env bash

set -e

command -v curl >/dev/null 2>&1 || \
(apt update -y && apt install -y curl ca-certificates)

curl -fsSL \
https://raw.githubusercontent.com/jacksun681/live-deploy/main/live_menu.sh \
-o /usr/local/bin/live_menu.real

sed -i 's/\r$//' /usr/local/bin/live_menu.real

chmod +x /usr/local/bin/live_menu.real

cat > /usr/local/bin/menu << 'EOF'
#!/usr/bin/env bash
bash /usr/local/bin/live_menu.real
EOF

chmod +x /usr/local/bin/menu

bash /usr/local/bin/live_menu.real --bootstrap
