#!/usr/bin/env bash
set -euo pipefail

HISTORY_MAX=5
RATE_SAMPLE_SECONDS=2

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

sample_rates() {
  local iface="$1"
  local sec="${2:-2}"
  local rx1 tx1 rx2 tx2
  read -r rx1 tx1 <<< "$(read_net_bytes "$iface")"
  sleep "$sec"
  read -r rx2 tx2 <<< "$(read_net_bytes "$iface")"

  RX_BPS=$(((rx2-rx1)/sec))
  TX_BPS=$(((tx2-tx1)/sec))
  RX_MBPS="$(bytes_to_mbps "$RX_BPS")"
  TX_MBPS="$(bytes_to_mbps "$TX_BPS")"
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
    sum=0;
    for(i=1;i<=n;i++) sum+=a[i];
    mean=sum/n;
    var=0;
    for(i=1;i<=n;i++) var+=(a[i]-mean)^2;
    printf "%.2f", sqrt(var/n);
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

conn_443_count() {
  ss -ant 2>/dev/null | awk '/:443 / || /:443$/ {c++} END{print c+0}'
}

tcp_retrans_count() {
  ss -ti 2>/dev/null | grep -c retrans || true
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
  curl -o /dev/null -s --connect-timeout 3 --max-time 5 -w "%{time_total}" "$1" || echo 9
}

ping_stats() {
  local host="$1"
  local out avg jit loss
  out="$(ping -c 2 -W 1 "$host" 2>/dev/null || true)"
  avg="$(echo "$out" | awk -F'/' '/^rtt|^round-trip/ {print $5}')"
  jit="$(echo "$out" | awk -F'/' '/^rtt|^round-trip/ {print $7}')"
  loss="$(echo "$out" | awk -F',' '/packet loss/ {gsub(/^ +| +$/, "", $3); sub(/% packet loss/, "", $3); print $3}')"
  [[ -z "${avg:-}" ]] && avg="0"
  [[ -z "${jit:-}" ]] && jit="0"
  [[ -z "${loss:-}" ]] && loss="100"
  echo "$avg $jit $loss"
}

dns_resolve_tiktok_ips() {
  dig +short www.tiktok.com A 2>/dev/null | grep -E '^[0-9.]+' | head -n 2
}

probe_tiktok_ips() {
  local ips
  ips="$(dns_resolve_tiktok_ips || true)"
  TT_IP_COUNT="$(echo "$ips" | sed '/^$/d' | wc -l | awk '{print $1}')"

  local cnt=0 total_avg=0 total_jit=0 total_loss=0
  while read -r ip; do
    [[ -z "${ip:-}" ]] && continue
    local avg jit loss
    read -r avg jit loss <<< "$(ping_stats "$ip")"
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
  fi
}

detect_live_state() {
  AVG_TX="$(avg_hist UP_HISTORY)"
  AVG_RX="$(avg_hist DOWN_HISTORY)"
  STD_TX="$(stddev_hist UP_HISTORY)"
  STD_RX="$(stddev_hist DOWN_HISTORY)"
  UP_DOWN_RATIO="$(ratio_safe "$AVG_TX" "$AVG_RX")"

  local recent_push_count
  recent_push_count="$(awk -v s="${UP_HISTORY[*]:-}" 'BEGIN{
    n=split(s,a," ");
    c=0;
    for(i=1;i<=n;i++) if (a[i] > 0.50) c++;
    print c;
  }')"

  LIVE_STATE="空闲联网"
  LIVE_REASON="仅检测到少量联网活动"

  if (( CONN <= 0 )) && awk -v tx="$AVG_TX" 'BEGIN{exit !(tx<0.10)}'; then
    LIVE_STATE="未检测到直播"
    LIVE_REASON="无明显连接，且上行极低"
    return
  fi

  if awk -v tx="$AVG_TX" -v rx="$AVG_RX" 'BEGIN{exit !(tx<0.05 && rx<0.20)}'; then
    LIVE_STATE="未检测到直播"
    LIVE_REASON="上下行都很低，没有推流特征"
    return
  fi

  if awk -v rx="$AVG_RX" -v tx="$AVG_TX" 'BEGIN{exit !(rx>1.00 && tx<0.30)}'; then
    LIVE_STATE="下行为主"
    LIVE_REASON="下载明显高于上传，更像观看/浏览"
    return
  fi

  if awk -v tx="$AVG_TX" -v c="$CONN" 'BEGIN{exit !(tx>0.25 && c>0)}'; then
    LIVE_STATE="疑似推流中"
    LIVE_REASON="上行已达到推流级别，但连续性还在确认"
  fi

  if awk -v tx="$AVG_TX" -v c="$CONN" -v rp="$recent_push_count" 'BEGIN{exit !(tx>0.60 && c>0 && rp>=3)}'; then
    LIVE_STATE="持续推流中"
    LIVE_REASON="上行连续达标，符合直播推流特征"
    return
  fi
}

status_label() {
  if [[ "$XRAY" != "active" ]]; then
    echo "异常"
    return
  fi

  if [[ "$LIVE_STATE" == "未检测到直播" || "$LIVE_STATE" == "空闲联网" || "$LIVE_STATE" == "下行为主" ]]; then
    echo "非直播状态"
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

  if (( bad >= 3 )); then
    echo "持续异常"
  elif (( bad + wave >= 2 )); then
    echo "偶发波动"
  else
    echo "整体稳定"
  fi
}

confidence_calc() {
  local a="$1"
  local b="$2"
  local gap=$((a-b))
  if (( a >= 80 || gap >= 30 )); then
    echo "高"
  elif (( a >= 50 || gap >= 15 )); then
    echo "中"
  else
    echo "低"
  fi
}

score_reset() {
  SCORE_SERVICE=0
  SCORE_RESOURCE=0
  SCORE_TIKTOK=0
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

  [[ "$PUB_OK" != "ok" ]] && SCORE_EXIT=$((SCORE_EXIT+50))
  awk -v t="$PUB_TIME" 'BEGIN{exit !(t>=1.5 && t<3.0)}' && SCORE_EXIT=$((SCORE_EXIT+15))

  if [[ "$TT_OK" != "ok" && "$PUB_OK" == "ok" ]]; then
    SCORE_TIKTOK=$((SCORE_TIKTOK+60))
  fi
  awk -v t="$TT_TIME" -v p="$PUB_TIME" 'BEGIN{exit !(t>p*2 && t>1.0)}' && SCORE_TIKTOK=$((SCORE_TIKTOK+20))
  awk -v j="$TT_IP_JIT" 'BEGIN{exit !(j>25)}' && SCORE_TIKTOK=$((SCORE_TIKTOK+10))
  awk -v l="$TT_IP_LOSS" 'BEGIN{exit !(l>3)}' && SCORE_TIKTOK=$((SCORE_TIKTOK+10))

  awk -v j1="$PUB_JIT" -v j2="$TT_JIT" 'BEGIN{exit !((j1>25)||(j2>25))}' && SCORE_LINK=$((SCORE_LINK+25))
  awk -v l1="$PUB_LOSS" -v l2="$TT_LOSS" 'BEGIN{exit !((l1>3)||(l2>3))}' && SCORE_LINK=$((SCORE_LINK+25))

  awk -v r="$RETRANS" 'BEGIN{exit !(r>5)}' && SCORE_ACCESS=$((SCORE_ACCESS+35))
  awk -v tx="$AVG_TX" -v s="$STD_TX" 'BEGIN{exit !((tx>0.25)&&(s>tx))}' && SCORE_ACCESS=$((SCORE_ACCESS+10))

  if [[ "$LIVE_STATE" == "持续推流中" || "$LIVE_STATE" == "疑似推流中" ]]; then
    if [[ "$TT_OK" == "ok" && "$PUB_OK" == "ok" ]] && awk -v tx="$AVG_TX" 'BEGIN{exit !(tx<0.50)}'; then
      SCORE_DEVICE=$((SCORE_DEVICE+30))
    fi
  fi

  if (( SCORE_SERVICE < 30 && SCORE_RESOURCE < 30 && SCORE_TIKTOK < 30 && SCORE_EXIT < 30 && SCORE_LINK < 30 && SCORE_ACCESS < 30 && SCORE_DEVICE < 30 )); then
    SCORE_PLATFORM=20
  fi
}

pick_top_causes() {
  local scores
  scores="$(printf "%s\n" \
    "service $SCORE_SERVICE" \
    "resource $SCORE_RESOURCE" \
    "tiktok $SCORE_TIKTOK" \
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
    tiktok) echo "TikTok入口路径异常" ;;
    exit) echo "节点出口异常" ;;
    link) echo "链路层波动" ;;
    access) echo "本地网络不稳定（Wi-Fi/蜂窝）" ;;
    device) echo "设备性能或编码问题" ;;
    platform) echo "平台侧波动" ;;
    *) echo "未发现明显异常" ;;
  esac
}

ai_judge() {
  if [[ "$LIVE_STATE" == "未检测到直播" || "$LIVE_STATE" == "空闲联网" ]]; then
    MAIN_CAUSE="当前未在直播"
    SUB_CAUSE="无"
    CONF="高"
    CONCLUSION="当前没有明显直播推流特征。"
    SUGGESTION="若你刚开播，等几秒再看。"
    return
  fi

  if [[ "$LIVE_STATE" == "下行为主" ]]; then
    MAIN_CAUSE="非推流状态（更像观看/浏览）"
    SUB_CAUSE="无"
    CONF="高"
    CONCLUSION="当前流量以下行为主，不像开直播。"
    SUGGESTION="若你在看视频，这是正常现象。"
    return
  fi

  score_ai
  pick_top_causes
  MAIN_CAUSE="$(reason_text "$TOP1_NAME")"
  SUB_CAUSE="$(reason_text "$TOP2_NAME")"
  CONF="$(confidence_calc "$TOP1_SCORE" "$TOP2_SCORE")"
  CONCLUSION="当前链路整体正常。"
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
    tiktok)
      CONCLUSION="当前异常更集中在 TikTok 方向。"
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
      SUGGESTION="优先检查 Wi-Fi/蜂窝、信号、干扰和手机状态。"
      ;;
    device)
      CONCLUSION="当前未发现明显节点异常，更像设备侧问题。"
      SUGGESTION="关注手机发热、后台、码率和分辨率。"
      ;;
    platform)
      CONCLUSION="当前未发现足以解释异常的节点侧证据。"
      SUGGESTION="继续观察；如多个节点同样异常，更偏向平台问题。"
      ;;
  esac
}

render() {
  clear
  echo "====== TikTok直播诊断 ======"
  echo
  echo "直播状态：$LIVE_STATE"
  echo "当前状态：$CURRENT_STATUS   趋势：$TREND_STATUS"
  echo "主因：$MAIN_CAUSE"
  echo "结论：$CONCLUSION"
  echo "建议：$SUGGESTION"
  echo
  echo "----------- 流量 -----------"
  printf "上行：%6s Mbps\n" "$TX_MBPS"
  printf "下行：%6s Mbps\n" "$RX_MBPS"
  printf "均上：%6s Mbps\n" "$AVG_TX"
  printf "均下：%6s Mbps\n" "$AVG_RX"
  echo "连接：$CONN"
  echo "重传：$RETRANS"
  echo
  echo "-------- 网络质量 --------"
  echo "TikTok：$TT_LAT ms / $TT_JIT ms / $TT_LOSS% / $TT_TIME s"
  echo "公共：  $PUB_LAT ms / $PUB_JIT ms / $PUB_LOSS% / $PUB_TIME s"
  echo
  echo "置信度：$CONF"
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

    sample_rates "$iface" "$RATE_SAMPLE_SECONDS"
    push_hist UP_HISTORY "$TX_MBPS"
    push_hist DOWN_HISTORY "$RX_MBPS"

    detect_live_state

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
    [[ "$CURRENT_STATUS" == "正常" || "$CURRENT_STATUS" == "波动" || "$CURRENT_STATUS" == "异常" ]] && push_hist STATUS_HISTORY "$CURRENT_STATUS"
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
        exit 88
        ;;
    esac
  done

  trap - INT
  echo
  echo "已结束直播诊断，退出到命令行。"
  exit 99
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
