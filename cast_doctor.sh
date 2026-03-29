#!/usr/bin/env bash
set -euo pipefail

HISTORY_MAX=8
RATE_SAMPLE_SECONDS=5

declare -a UP_HISTORY=()
declare -a DOWN_HISTORY=()
declare -a STATUS_HISTORY=()

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    apt-get update -yq
    apt-get install -yq \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      "$2"
  }
}

install_deps() {
  need_cmd curl curl
  need_cmd ping iputils-ping
  need_cmd ip iproute2
  need_cmd bc bc
  need_cmd awk gawk
  need_cmd ss iproute2
  need_cmd top procps
  need_cmd free procps
  need_cmd dig dnsutils
  return 0
}

get_iface() {
  local iface
  iface="$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)"
  [[ -z "${iface:-}" ]] && iface="$(ip -o -4 route show to default | awk '{print $5}' | head -n1)"
  echo "${iface:-eth0}"
}

bytes_to_mbps() {
  awk -v b="$1" 'BEGIN{printf "%.2f", (b*8)/1000000}'
}

read_net_bytes() {
  local iface="$1"
  local rx tx
  rx="$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)"
  tx="$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)"
  echo "$rx $tx"
}

sample_rates_over_window() {
  local iface="$1"
  local seconds="${2:-5}"
  local rx1 tx1 rx2 tx2
  read -r rx1 tx1 <<< "$(read_net_bytes "$iface")"
  sleep "$seconds"
  read -r rx2 tx2 <<< "$(read_net_bytes "$iface")"

  RX_BPS=$(((rx2-rx1)/seconds))
  TX_BPS=$(((tx2-tx1)/seconds))
  RX_MBPS="$(bytes_to_mbps "$RX_BPS")"
  TX_MBPS="$(bytes_to_mbps "$TX_BPS")"
}

conn_443_count() {
  ss -ant 2>/dev/null | awk '/:443 / || /:443$/ {c++} END{print c+0}'
}

tcp_retrans_count() {
  ss -ti 2>/dev/null | grep -c retrans || true
}

tcp_retrans_lines() {
  ss -ti 2>/dev/null | grep retrans | head -n 5 || true
}

xray_status() {
  systemctl is-active xray 2>/dev/null || echo unknown
}

cpu_usage() {
  top -bn1 | awk -F'id,' '/Cpu\(s\)/ {
    split($1,a,","); gsub(/ /,"",a[length(a)]);
    if (a[length(a)] == "") print "0"; else printf "%.1f", 100-a[length(a)];
  }' | head -n1
}

mem_usage() {
  free | awk '/Mem:/ {printf "%.1f",$3/$2*100}'
}

https_time() {
  curl -o /dev/null -s --connect-timeout 3 --max-time 6 -w "%{time_total}" "$1" || echo 9
}

ping_stats() {
  local host="$1"
  local out avg jit loss
  out="$(ping -c 3 -W 1 "$host" 2>/dev/null || true)"
  avg="$(echo "$out" | awk -F'/' '/^rtt|^round-trip/ {print $5}')"
  jit="$(echo "$out" | awk -F'/' '/^rtt|^round-trip/ {print $7}')"
  loss="$(echo "$out" | awk -F',' '/packet loss/ {gsub(/^ +| +$/, "", $3); sub(/% packet loss/, "", $3); print $3}')"
  [[ -z "${avg:-}" ]] && avg="0"
  [[ -z "${jit:-}" ]] && jit="0"
  [[ -z "${loss:-}" ]] && loss="100"
  echo "$avg $jit $loss"
}

push_hist() {
  local arr_name="$1"
  local value="$2"
  eval "$arr_name+=(\"$value\")"
  eval "local len=\${#$arr_name[@]}"
  if (( len > HISTORY_MAX )); then
    eval "$arr_name=(\"\${$arr_name[@]:1}\")"
  fi
}

avg_hist() {
  local arr_name="$1"
  eval "local vals=(\"\${$arr_name[@]}\")"
  local joined="${vals[*]:-}"
  awk -v s="$joined" 'BEGIN{
    n=split(s,a," ");
    if(n==0 || s==""){print "0.00"; exit}
    sum=0;
    for(i=1;i<=n;i++) sum+=a[i];
    printf "%.2f", sum/n;
  }'
}

stddev_hist() {
  local arr_name="$1"
  eval "local vals=(\"\${$arr_name[@]}\")"
  local joined="${vals[*]:-}"
  awk -v s="$joined" 'BEGIN{
    n=split(s,a," ");
    if(n<=1 || s==""){print "0.00"; exit}
    sum=0
    for(i=1;i<=n;i++) sum+=a[i]
    mean=sum/n
    var=0
    for(i=1;i<=n;i++) var+=(a[i]-mean)^2
    printf "%.2f", sqrt(var/n)
  }'
}

ratio_safe() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    if (b <= 0.01) {
      if (a <= 0.01) printf "1.00";
      else printf "999.00";
    } else {
      printf "%.2f", a/b;
    }
  }'
}

dns_resolve_tiktok_ips() {
  dig +short www.tiktok.com A 2>/dev/null | grep -E '^[0-9.]+' | head -n 3
}

probe_tiktok_ips() {
  local ips
  ips="$(dns_resolve_tiktok_ips || true)"
  TT_IP_COUNT="$(echo "$ips" | sed '/^$/d' | wc -l | awk '{print $1}')"
  TT_IP_SUMMARY=""

  local cnt=0 total_avg=0 total_jit=0 total_loss=0
  while read -r ip; do
    [[ -z "${ip:-}" ]] && continue
    local avg jit loss
    read -r avg jit loss <<< "$(ping_stats "$ip")"
    TT_IP_SUMMARY+="${ip}:${avg}ms/${jit}ms/${loss}%  "
    total_avg="$(awk -v a="$total_avg" -v b="$avg" 'BEGIN{printf "%.2f", a+b}')"
    total_jit="$(awk -v a="$total_jit" -v b="$jit" 'BEGIN{printf "%.2f", a+b}')"
    total_loss="$(awk -v a="$total_loss" -v b="$loss" 'BEGIN{printf "%.2f", a+b}')"
    cnt=$((cnt+1))
  done <<< "$ips"

  if (( cnt > 0 )); then
    TT_IP_AVG="$(awk -v s="$total_avg" -v n="$cnt" 'BEGIN{printf "%.2f", s/n}')"
    TT_IP_JIT="$(awk -v s="$total_jit" -v n="$cnt" 'BEGIN{printf "%.2f", s/n}')"
    TT_IP_LOSS="$(awk -v s="$total_loss" -v n="$cnt" 'BEGIN{printf "%.2f", s/n}')"
  else
    TT_IP_AVG="0.00"
    TT_IP_JIT="0.00"
    TT_IP_LOSS="100.00"
    TT_IP_SUMMARY="未解析到TikTok A记录"
  fi
}

detect_live_state() {
  local conn="$1"

  AVG_TX="$(avg_hist UP_HISTORY)"
  AVG_RX="$(avg_hist DOWN_HISTORY)"
  STD_TX="$(stddev_hist UP_HISTORY)"
  STD_RX="$(stddev_hist DOWN_HISTORY)"
  UP_DOWN_RATIO="$(ratio_safe "$AVG_TX" "$AVG_RX")"

  LIVE_STATE="空闲联网"
  LIVE_REASON="当前未见持续上传特征"

  if (( conn <= 0 )) && awk -v x="$AVG_TX" 'BEGIN{exit !(x<0.10)}'; then
    LIVE_STATE="未检测到直播"
    LIVE_REASON="无明显连接，且上行很低"
    return
  fi

  if awk -v tx="$AVG_TX" -v rx="$AVG_RX" 'BEGIN{exit !(tx<0.10 && rx<0.30)}'; then
    LIVE_STATE="空闲联网"
    LIVE_REASON="有联网活动，但没有持续流量特征"
    return
  fi

  if awk -v tx="$AVG_TX" -v rx="$AVG_RX" -v r="$UP_DOWN_RATIO" 'BEGIN{exit !(rx>1.0 && r<0.35)}'; then
    LIVE_STATE="下行为主"
    LIVE_REASON="下载明显高于上传，更像观看/浏览"
    return
  fi

  if awk -v tx="$AVG_TX" -v r="$UP_DOWN_RATIO" 'BEGIN{exit !(tx>0.50 && r>1.30)}'; then
    LIVE_STATE="疑似推流中"
    LIVE_REASON="上行已明显增强，但连续性或稳定性还不够"
  fi

  if awk -v tx="$AVG_TX" -v r="$UP_DOWN_RATIO" -v s="$STD_TX" 'BEGIN{exit !(tx>1.00 && r>1.80 && s<tx*0.9)}'; then
    LIVE_STATE="持续推流中"
    LIVE_REASON="上行连续且主导，符合直播推流特征"
  fi
}

status_label() {
  if [[ "$XRAY" != "active" ]]; then
    echo "异常"
    return
  fi

  if [[ "$TT_OK" != "ok" && "$PUB_OK" == "ok" ]]; then
    echo "异常"
    return
  fi

  if awk -v c="$CPU" -v m="$MEM" 'BEGIN{exit !(c>=90 || m>=90)}'; then
    echo "异常"
    return
  fi

  if awk -v j1="$PUB_JIT" -v j2="$TT_JIT" -v j3="$TT_IP_JIT" -v l1="$PUB_LOSS" -v l2="$TT_LOSS" -v l3="$TT_IP_LOSS" \
    'BEGIN{exit !((j1>25 || j2>25 || j3>25 || l1>3 || l2>3 || l3>3))}'; then
    echo "波动"
    return
  fi

  echo "正常"
}

trend_label() {
  local normal=0 wave=0 bad=0 item
  for item in "${STATUS_HISTORY[@]}"; do
    case "$item" in
      正常) normal=$((normal+1)) ;;
      波动) wave=$((wave+1)) ;;
      异常) bad=$((bad+1)) ;;
    esac
  done

  if (( bad >= 4 )); then
    echo "持续异常"
  elif (( bad + wave >= 3 )); then
    echo "偶发波动"
  else
    echo "整体稳定"
  fi
}

confidence_calc() {
  local main_score="$1"
  local sub_score="$2"
  local gap=$((main_score-sub_score))

  if (( main_score >= 85 || gap >= 35 )); then
    echo "高"
  elif (( main_score >= 55 || gap >= 15 )); then
    echo "中"
  else
    echo "低"
  fi
}

score_reset() {
  SCORE_SERVICE=0
  SCORE_RESOURCE=0
  SCORE_TIKTOK_PATH=0
  SCORE_EXIT=0
  SCORE_LINK=0
  SCORE_ACCESS=0
  SCORE_DEVICE=0
  SCORE_PLATFORM=0
}

score_ai() {
  score_reset

  [[ "$XRAY" != "active" ]] && SCORE_SERVICE=100

  awk -v c="$CPU" 'BEGIN{exit !(c>=90)}' && SCORE_RESOURCE=$((SCORE_RESOURCE+45))
  awk -v m="$MEM" 'BEGIN{exit !(m>=90)}' && SCORE_RESOURCE=$((SCORE_RESOURCE+30))
  awk -v c="$CPU" 'BEGIN{exit !(c>=80 && c<90)}' && SCORE_RESOURCE=$((SCORE_RESOURCE+15))
  awk -v m="$MEM" 'BEGIN{exit !(m>=80 && m<90)}' && SCORE_RESOURCE=$((SCORE_RESOURCE+10))

  [[ "$PUB_OK" != "ok" ]] && SCORE_EXIT=$((SCORE_EXIT+55))
  awk -v t="$PUB_TIME" 'BEGIN{exit !(t>=1.5 && t<3.0)}' && SCORE_EXIT=$((SCORE_EXIT+15))

  if [[ "$TT_OK" != "ok" && "$PUB_OK" == "ok" ]]; then
    SCORE_TIKTOK_PATH=$((SCORE_TIKTOK_PATH+60))
  fi
  awk -v t="$TT_TIME" -v p="$PUB_TIME" 'BEGIN{exit !(t>p*2 && t>1.0)}' && SCORE_TIKTOK_PATH=$((SCORE_TIKTOK_PATH+20))
  awk -v t="$TT_IP_JIT" 'BEGIN{exit !(t>25)}' && SCORE_TIKTOK_PATH=$((SCORE_TIKTOK_PATH+10))
  awk -v t="$TT_IP_LOSS" 'BEGIN{exit !(t>3)}' && SCORE_TIKTOK_PATH=$((SCORE_TIKTOK_PATH+10))

  awk -v j1="$PUB_JIT" -v j2="$TT_JIT" -v j3="$TT_IP_JIT" 'BEGIN{exit !((j1>25)||(j2>25)||(j3>25))}' && SCORE_LINK=$((SCORE_LINK+25))
  awk -v l1="$PUB_LOSS" -v l2="$TT_LOSS" -v l3="$TT_IP_LOSS" 'BEGIN{exit !((l1>3)||(l2>3)||(l3>3))}' && SCORE_LINK=$((SCORE_LINK+25))
  awk -v p="$PUB_LAT" -v t="$TT_LAT" 'BEGIN{exit !((p>120)||(t>150))}' && SCORE_LINK=$((SCORE_LINK+15))

  awk -v r="$RETRANS" 'BEGIN{exit !(r>5)}' && SCORE_ACCESS=$((SCORE_ACCESS+35))
  awk -v tx="$AVG_TX" -v rx="$AVG_RX" -v ratio="$UP_DOWN_RATIO" 'BEGIN{exit !((tx>0.5)&&(ratio>1.3)&&(tx<1.0))}' && SCORE_ACCESS=$((SCORE_ACCESS+10))
  awk -v tx="$AVG_TX" -v s="$STD_TX" 'BEGIN{exit !((tx>0.3)&&(s>tx))}' && SCORE_ACCESS=$((SCORE_ACCESS+15))

  if [[ "$LIVE_STATE" == "持续推流中" || "$LIVE_STATE" == "疑似推流中" ]]; then
    if [[ "$TT_OK" == "ok" && "$PUB_OK" == "ok" ]] && awk -v tx="$AVG_TX" -v ratio="$UP_DOWN_RATIO" 'BEGIN{exit !((tx<0.50)||(ratio<1.20))}'; then
      SCORE_DEVICE=$((SCORE_DEVICE+35))
    fi
  fi

  if [[ "$LIVE_STATE" == "未检测到直播" || "$LIVE_STATE" == "空闲联网" || "$LIVE_STATE" == "下行为主" ]]; then
    SCORE_DEVICE=0
  fi

  if (( SCORE_SERVICE < 30 && SCORE_RESOURCE < 30 && SCORE_TIKTOK_PATH < 30 && SCORE_EXIT < 30 && SCORE_LINK < 30 && SCORE_ACCESS < 30 && SCORE_DEVICE < 30 )); then
    SCORE_PLATFORM=25
  fi
}

pick_top_causes() {
  local scores
  scores="$(printf "%s\n" \
    "service $SCORE_SERVICE" \
    "resource $SCORE_RESOURCE" \
    "tiktok_path $SCORE_TIKTOK_PATH" \
    "exit $SCORE_EXIT" \
    "link $SCORE_LINK" \
    "access $SCORE_ACCESS" \
    "device $SCORE_DEVICE" \
    "platform $SCORE_PLATFORM" | sort -k2 -nr)"

  TOP1_NAME="$(echo "$scores" | sed -n '1p' | awk '{print $1}')"
  TOP1_SCORE="$(echo "$scores" | sed -n '1p' | awk '{print $2}')"
  TOP2_NAME="$(echo "$scores" | sed -n '2p' | awk '{print $1}')"
  TOP2_SCORE="$(echo "$scores" | sed -n '2p' | awk '{print $2}')"
}

reason_text() {
  case "$1" in
    service) echo "节点服务异常" ;;
    resource) echo "节点资源不足" ;;
    tiktok_path) echo "TikTok入口路径异常" ;;
    exit) echo "节点出口异常" ;;
    link) echo "链路层波动" ;;
    access) echo "本地网络不稳定（Wi-Fi/蜂窝）" ;;
    device) echo "设备性能或编码问题" ;;
    platform) echo "平台侧波动" ;;
    *) echo "未发现明显异常" ;;
  esac
}

ai_judge() {
  score_ai
  pick_top_causes
  CONF="$(confidence_calc "$TOP1_SCORE" "$TOP2_SCORE")"

  MAIN_CAUSE="$(reason_text "$TOP1_NAME")"
  SUB_CAUSE="$(reason_text "$TOP2_NAME")"
  CONCLUSION="当前直播链路整体正常。"
  SUGGESTION="继续观察。"

  case "$TOP1_NAME" in
    service)
      CONCLUSION="当前异常更像节点服务层故障。"
      SUGGESTION="优先修复 Xray/端口监听。"
      ;;
    resource)
      CONCLUSION="当前更像节点资源层问题。"
      SUGGESTION="降低负载，或升级节点配置。"
      ;;
    tiktok_path)
      CONCLUSION="当前异常更集中在 TikTok 方向，不像整个公网链路故障。"
      SUGGESTION="优先切换节点或更换更适合 TikTok 的线路。"
      ;;
    exit)
      CONCLUSION="当前更像节点出口层不稳。"
      SUGGESTION="优先观察出口质量，必要时切节点。"
      ;;
    link)
      CONCLUSION="当前更像链路层波动。"
      SUGGESTION="继续观察 1~2 分钟；若持续，建议切节点。"
      ;;
    access)
      CONCLUSION="当前更像接入层不稳，而不是节点本身故障。"
      SUGGESTION="优先检查 Wi-Fi/蜂窝、信号、干扰和本地网络环境。"
      ;;
    device)
      CONCLUSION="当前未发现明显节点异常，更像设备侧性能或编码问题。"
      SUGGESTION="关注手机发热、后台、码率和分辨率。"
      ;;
    platform)
      CONCLUSION="当前未发现足以解释异常的节点侧证据，平台侧波动概率上升。"
      SUGGESTION="继续观察；如多个节点都同样异常，更偏向平台问题。"
      ;;
  esac

  if [[ "$LIVE_STATE" == "下行为主" ]]; then
    MAIN_CAUSE="非推流状态（更像观看/浏览）"
    SUB_CAUSE="无"
    CONF="高"
    CONCLUSION="当前流量形态以下行为主，不像开直播。"
    SUGGESTION="若你在看视频，这是正常现象；无需按直播异常处理。"
  fi
}

render() {
  clear
  echo "=============================="
  echo "   TikTok 直播诊断（AI增强）"
  echo "=============================="
  echo
  echo "时间：$(date '+%F %T')"
  echo
  echo "直播状态：$LIVE_STATE"
  echo "判断依据：$LIVE_REASON"
  echo "当前状态：$CURRENT_STATUS"
  echo "趋势判断：$TREND_STATUS"
  echo
  echo "最可能原因：$MAIN_CAUSE"
  echo "备选原因：$SUB_CAUSE"
  echo "置信度：$CONF"
  echo
  echo "------------------------------"
  echo "TikTok专项"
  echo "------------------------------"
  echo "TikTok域名延迟：$TT_LAT ms"
  echo "TikTok域名抖动：$TT_JIT ms"
  echo "TikTok域名丢包：$TT_LOSS %"
  echo "TikTok HTTPS：$TT_TIME s"
  echo "TikTok IP探测数：$TT_IP_COUNT"
  echo "TikTok IP均值：$TT_IP_AVG ms / $TT_IP_JIT ms / $TT_IP_LOSS %"
  echo
  echo "------------------------------"
  echo "公共链路"
  echo "------------------------------"
  echo "公共延迟：$PUB_LAT ms"
  echo "公共抖动：$PUB_JIT ms"
  echo "公共丢包：$PUB_LOSS %"
  echo "公共 HTTPS：$PUB_TIME s"
  echo
  echo "------------------------------"
  echo "流量形态"
  echo "------------------------------"
  echo "上行速率：$TX_MBPS Mbps"
  echo "下行速率：$RX_MBPS Mbps"
  echo "平均上行：$AVG_TX Mbps"
  echo "平均下行：$AVG_RX Mbps"
  echo "上/下比：$UP_DOWN_RATIO"
  echo "上行波动：$STD_TX"
  echo "下行波动：$STD_RX"
  echo "443连接：$CONN"
  echo "TCP重传：$RETRANS"
  echo
  echo "------------------------------"
  echo "结论"
  echo "------------------------------"
  echo "$CONCLUSION"
  echo
  echo "建议：$SUGGESTION"
  echo
  echo "q 回车返回菜单，Ctrl+C退出"
}

diagnose_loop() {
  install_deps

  local stop_flag=0
  trap 'stop_flag=1' INT

  while true; do
    [[ "$stop_flag" -eq 1 ]] && break

    local iface
    iface="$(get_iface)"

    XRAY="$(xray_status)"
    CPU="$(cpu_usage)"
    MEM="$(mem_usage)"
    CONN="$(conn_443_count)"
    RETRANS="$(tcp_retrans_count)"

    sample_rates_over_window "$iface" "$RATE_SAMPLE_SECONDS"
    push_hist UP_HISTORY "$TX_MBPS"
    push_hist DOWN_HISTORY "$RX_MBPS"

    detect_live_state "$CONN"

    read PUB_LAT PUB_JIT PUB_LOSS <<< "$(ping_stats 1.1.1.1)"
    PUB_TIME="$(https_time https://www.cloudflare.com)"
    PUB_OK="fail"
    awk -v x="$PUB_TIME" 'BEGIN{exit !(x<3.0)}' && PUB_OK="ok"

    read TT_LAT TT_JIT TT_LOSS <<< "$(ping_stats www.tiktok.com)"
    TT_TIME="$(https_time https://www.tiktok.com)"
    TT_OK="fail"
    awk -v x="$TT_TIME" 'BEGIN{exit !(x<3.0)}' && TT_OK="ok"

    probe_tiktok_ips

    CURRENT_STATUS="$(status_label)"
    push_hist STATUS_HISTORY "$CURRENT_STATUS"
    TREND_STATUS="$(trend_label)"

    ai_judge
    render

    echo
    read -r -t 2 -p "输入 q 回车返回管理菜单，或等待自动刷新: " key || key=""
    case "$key" in
      q|Q)
        trap - INT
        echo
        echo "已结束直播诊断，返回管理菜单。"
        return 0
        ;;
    esac
  done

  trap - INT
  echo
  echo "已结束直播诊断，退出到命令行。"
  return 99
}

main() {
  case "${1:-diagnose}" in
    diagnose|watch|menu)
      diagnose_loop
      ;;
    *)
      echo "用法:"
      echo "  bash cast_doctor.sh diagnose"
      exit 1
      ;;
  esac
}

main "$@"
EOF

chmod +x /usr/local/bin/cast_doctor.real
