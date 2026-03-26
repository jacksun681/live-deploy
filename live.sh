#!/usr/bin/env bash
set -e

[ "$(id -u)" != 0 ] && echo "请用 root 运行" && exit 1

for i in "curl curl" "qrencode qrencode" "bc bc" "ping iputils-ping" "ip iproute2"; do
  c=${i% *}; p=${i#* }
  command -v "$c" >/dev/null 2>&1 || { apt update -y && apt install -y "$p"; }
done

command -v xray >/dev/null 2>&1 || bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install

test_tcp() {
  sysctl -w net.ipv4.tcp_congestion_control="$1" >/dev/null 2>&1 || true
  sleep 2
  ping -c 10 -W 2 8.8.8.8 2>/dev/null | awk -F'/' '/rtt|round-trip/ {print $5 "|" $7}'
}

USE="cubic"
AVAIL="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
if echo "$AVAIL" | grep -qw bbr; then
  B="$(test_tcp bbr)"; C="$(test_tcp cubic)"
  BJ="${B#*|}"; CJ="${C#*|}"
  (( $(echo "$BJ <= $CJ" | bc -l) )) && USE="bbr"
fi

cat >/etc/sysctl.d/99-live.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$USE
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_no_metrics_save=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.core.netdev_max_backlog=250000
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF

sysctl --system >/dev/null

IFACE="$(ip route | awk '/default/ {print $5; exit}')"
[ -n "$IFACE" ] && tc qdisc replace dev "$IFACE" root fq >/dev/null 2>&1 || true

read -rp "节点备注名（默认 Live）: " NAME
NAME="${NAME:-Live}"

UUID="$(cat /proc/sys/kernel/random/uuid)"
KEYS="$(xray x25519)"
PRI="$(echo "$KEYS" | awk '/Private key:/ {print $3}')"
PUB="$(echo "$KEYS" | awk '/Public key:/ {print $3}')"

IP="$(curl -4 -s https://api.ipify.org || true)"
[ -z "$IP" ] && IP="$(curl -4 -s https://ifconfig.me || true)"
[ -z "$IP" ] && read -rp "请输入公网 IP: " IP

mkdir -p /usr/local/etc/xray
cat >/usr/local/etc/xray/config.json <<EOF
{
  "inbounds":[
    {
      "port":443,
      "protocol":"vless",
      "settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},
      "streamSettings":{
        "network":"tcp",
        "security":"reality",
        "realitySettings":{
          "dest":"www.cloudflare.com:443",
          "serverNames":["www.cloudflare.com"],
          "privateKey":"$PRI",
          "shortIds":[""]
        }
      }
    }
  ],
  "outbounds":[{"protocol":"freedom"}]
}
EOF

systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray

ENC_NAME="$(printf '%s' "$NAME" | sed 's/ /%20/g')"
LINK="vless://${UUID}@${IP}:443?encryption=none&security=reality&sni=www.cloudflare.com&fp=chrome&pbk=${PUB}&type=tcp&headerType=none#${ENC_NAME}"

echo
echo "完成，当前算法: $USE"
echo "$LINK"
echo
qrencode -t ANSIUTF8 "$LINK"