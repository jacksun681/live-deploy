#!/usr/bin/env bash
set -e

CONF="/usr/local/etc/xray/config.json"
SYSCTL_CONF="/etc/sysctl.d/99-live.conf"
DOMAIN="www.cloudflare.com"

[[ "$(id -u)" -ne 0 ]] && echo "请用 root 运行" && exit 1

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    apt update -y
    apt install -y "$2"
  }
}

install_deps() {
  need_cmd curl curl
  need_cmd qrencode qrencode
  need_cmd bc bc
  need_cmd ping iputils-ping
  need_cmd ip iproute2
  need_cmd python3 python3
}

install_xray() {
  command -v xray >/dev/null 2>&1 || \
    bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install
}

get_ip() {
  curl -4 -s https://api.ipify.org || curl -4 -s https://ifconfig.me || curl -4 -s https://ip.sb
}

make_keys() {
  raw="$(xray x25519 2>/dev/null || true)"
  pri="$(echo "$raw" | awk -F': ' '/Private key|PrivateKey/ {print $2}' | head -n1)"
  pub="$(xray x25519 -i "$pri" 2>/dev/null | awk -F': ' '/Public key|PublicKey|Password/ {print $2}' | head -n1)"
  echo "$pri|$pub"
}

cfg_get() {
  grep -oP "$1" "$CONF" 2>/dev/null | head -n1
}

write_config() {
  mkdir -p /usr/local/etc/xray
  cat >"$CONF" <<EOF
{
  "inbounds":[{
    "port":$3,
    "protocol":"vless",
    "settings":{"clients":[{"id":"$1"}],"decryption":"none"},
    "streamSettings":{
      "network":"tcp",
      "security":"reality",
      "realitySettings":{
        "dest":"$DOMAIN:443",
        "serverNames":["$DOMAIN"],
        "privateKey":"$2",
        "shortIds":[""]
      }
    }
  }],
  "outbounds":[{"protocol":"freedom"}]
}
EOF
  systemctl restart xray
}

build_link() {
  uuid="$1"; port="$2"; pri="$3"
  pub="$(xray x25519 -i "$pri" 2>/dev/null | awk -F': ' '/Public key|Password/ {print $2}' | head -n1)"
  ip="$(get_ip)"
  echo "vless://${uuid}@${ip}:${port}?encryption=none&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${pub}&type=tcp#Live"
}

copy_link() {
  link="$1"
  echo "$link"

  if command -v pbcopy >/dev/null; then echo "$link" | pbcopy && echo "✔ 已复制"
  elif command -v xclip >/dev/null; then echo "$link" | xclip -selection clipboard && echo "✔ 已复制"
  elif command -v clip >/dev/null; then echo "$link" | clip && echo "✔ 已复制"
  fi
}

start_api() {
cat > /root/link_api.py <<EOF
from http.server import BaseHTTPRequestHandler, HTTPServer
import subprocess
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/link":
            self.send_response(404); self.end_headers(); return
        out = subprocess.getoutput("bash /root/get_link.sh")
        self.send_response(200)
        self.send_header("Content-type","text/plain")
        self.end_headers()
        self.wfile.write(out.encode())
HTTPServer(("0.0.0.0",8080),H).serve_forever()
EOF

nohup python3 /root/link_api.py >/dev/null 2>&1 &
echo "✔ 接口已启动：http://$(get_ip):8080/link"
}

create_get_link() {
cat > /root/get_link.sh <<EOF
#!/usr/bin/env bash
UUID=\$(grep -oP '"id"\s*:\s*"\K[^"]+' $CONF)
PRI=\$(grep -oP '"privateKey"\s*:\s*"\K[^"]+' $CONF)
PORT=\$(grep -oP '"port"\s*:\s*\K\d+' $CONF)
PBK=\$(xray x25519 -i "\$PRI" 2>/dev/null | awk -F': ' '/Public key|Password/ {print \$2}' | head -n1)
IP=\$(curl -4 -s https://api.ipify.org)
echo "vless://\$UUID@\${IP}:\${PORT}?encryption=none&security=reality&sni=$DOMAIN&fp=chrome&pbk=\${PBK}&type=tcp#Live"
EOF
chmod +x /root/get_link.sh
}

install_init() {
  install_deps
  install_xray

  keys="$(make_keys)"
  pri="${keys%%|*}"; pub="${keys##*|}"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  port=443

  write_config "$uuid" "$pri" "$port"
  create_get_link
  start_api

  link="$(build_link "$uuid" "$port" "$pri)"
  echo "安装完成"
  copy_link "$link"
}

show_link() {
  uuid="$(cfg_get '"id"\s*:\s*"\K[^"]+')"
  pri="$(cfg_get '"privateKey"\s*:\s*"\K[^"]+')"
  port="$(cfg_get '"port"\s*:\s*\K\d+')"
  link="$(build_link "$uuid" "$port" "$pri")"
  copy_link "$link"
}

reset_node() {
  keys="$(make_keys)"
  pri="${keys%%|*}"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  port="$(cfg_get '"port"\s*:\s*\K\d+')"
  write_config "$uuid" "$pri" "$port"
  link="$(build_link "$uuid" "$port" "$pri")"
  echo "已重置"
  copy_link "$link"
}

menu() {
clear
echo "1. 查看链接"
echo "2. 重置节点"
echo "3. 启动接口"
echo "0. 退出"
read -p "选择: " n
case $n in
1) show_link ;;
2) reset_node ;;
3) start_api ;;
0) exit ;;
esac
}

if [[ ! -f "$CONF" ]]; then
  install_init
  exit
fi

while true; do
menu
read -p "回车继续"
done