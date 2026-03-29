#!/usr/bin/env bash
set -euo pipefail

CONF="/usr/local/etc/xray/config.json"
PORT="443"

PROBE_A_TARGET="8.8.8.8"
PROBE_B_TARGET="1.1.1.1"
PROBE_C_TARGET="223.5.5.5"

HISTORY_MAX=6
declare -a HISTORY_LABELS=()

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
  need_cmd jq jq
  need_cmd ping iputils-ping
  need_cmd ip iproute2
  need_cmd bc bc
  need_cmd awk gawk
  need_cmd free procps
  need_cmd top procps
  need_cmd dig dnsutils
  need_cmd ss iproute2
  return 0
}

check_runtime_ready() {
  [[ -f "$CONF" ]] || { echo "配置文件不存在"; return 1; }
  command -v xray >/dev/null 2>&1 || { echo "xray 未安装"; return 1; }
  return 0
}

get_iface() {
  local iface
  iface="$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)"
  [[ -z "${iface:-}" ]] && iface="$(ip -o -4 route show to default | awk '{print $5}' | head -n1)"
  echo "${iface:-eth0}"
}

cpu_usage() {
  top -bn1 | awk -F'id,' '/Cpu\(s\)/ {
    split($1,a,","); gsub(/ /,"",a[length(a)]);
    if (a[length(a)] == "") print "0"; else printf("%.1f\n", 100-a[length(a)]);
  }' | head -n1
}

mem_usage() {
  free | awk '/Mem:/ {printf("%.1f\n",$3/$2*100)}'
}

conn_443_count() {
  ss -ant 2>/dev/null | awk '/:443 / || /:443$/ {c++} END{print c+0}'
}

dns_check() {
  dig +short google.com >/dev/null 2>&1 && echo "ok" || echo "fail"
}

https_time() {
  curl -o /dev/null -s --connect-timeout 3 --max-time 6 -w "%{time_total}" https://www.cloudflare.com || echo 9
}

https_ok() {
  local t="$1"
  awk -v x="$t" 'BEGIN{exit !(x<3.0)}' && echo "ok" || echo "fail"
}

ping_probe() {
  local target="$1"
  local count="${2:-3}"
  local out loss avg jitter

  out="$(ping -c "$count" -W 1 "$target" 2>/dev/null || true)"

  loss="$(echo "$out" | awk -F',' '/packet loss/ {
    gsub(/^ +| +$/, "", $3)
    sub(/% packet loss/, "", $3)
    print $3
  }')"
  avg="$(echo "$out" | awk -F'/' '/^rtt|^round-trip/ {print $5}')"
  jitter="$(echo "$out" | awk -F'/' '/^rtt|^round-trip/ {print $7}')"

  [[ -z "${loss:-}" ]] && loss="100"
  [[ -z "${avg:-}" ]] && avg="0"
  [[ -z "${jitter:-}" ]] && jitter="0"

  echo "${avg} ${jitter} ${loss}"
}

tx_delta() {
  local iface="$1" tx1 tx2
  tx1="$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)"
  sleep 1
  tx2="$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)"
  echo "$((tx2-tx1))"
}

tcp_retrans_count() {
  ss -ti 2>/dev/null | grep -c retrans || true
}

top_two_causes() {
  printf "%s\n" \
    "service ${SCORE_SERVICE}" \
    "resource ${SCORE_RESOURCE}" \
    "exit ${SCORE_EXIT}" \
    "link ${SCORE_LINK}" \
    "access ${SCORE_ACCESS}" \
    "device ${SCORE_DEVICE}" \
    "platform ${SCORE_PLATFORM}" \
    | sort -k2 -nr
}

reason_text() {
  case "$1" in
    service) echo "节点服务异常" ;;
    resource) echo "节点资源不足" ;;
    exit) echo "节点出口异常" ;;
    link) echo "节点链路波动" ;;
    access) echo "本地网络不稳定（Wi-Fi/蜂窝）" ;;
    device) echo "设备性能或编码问题" ;;
    platform) echo "平台侧波动" ;;
    *) echo "未识别" ;;
  esac
}

severity_text() {
  case "$1" in
    0|1) echo "正常" ;;
    2) echo "轻微" ;;
    3) echo "中等" ;;
    *) echo "严重" ;;
  esac
}

confidence_text() {
  local top="$1"
  local second="$2"
  local gap=$((top-second))
  if (( top >= 80 || gap >= 40 )); then
    echo "高"
  elif (( top >= 40 || gap >= 15 )); then
    echo "中"
  else
    echo "低"
  fi
}

status_label() {
  if (( SCORE_SERVICE >= 100 )); then
    echo "异常"
  elif (( SCORE_EXIT >= 60 || SCORE_RESOURCE >= 60 || SCORE_LINK >= 60 )); then
    echo "异常"
  elif (( SCORE_ACCESS >= 30 || SCORE_DEVICE >= 25 || SCORE_LINK >= 30 )); then
    echo "波动"
  else
    echo "正常"
  fi
}

trend_label() {
  local normal=0 wave=0 bad=0 item
  for item in "${HISTORY_LABELS[@]}"; do
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

push_history() {
  HISTORY_LABELS+=("$1")
  if ((${#HISTORY_LABELS[@]} > HISTORY_MAX)); then
    HISTORY_LABELS=("${HISTORY_LABELS[@]:1}")
  fi
}

collect_data() {
  XRAY_STATUS="$(systemctl is-active xray 2>/dev/null || echo unknown)"
  IFACE="$(get_iface)"
  CPU="$(cpu_usage)"
  MEM="$(mem_usage)"
  CONN="$(conn_443_count)"
  TX_DELTA="$(tx_delta "$IFACE")"
  RETRANS="$(tcp_retrans_count)"
  DNS_STATE="$(dns_check)"
  HTTPS_TIME="$(https_time)"
  HTTPS_STATE="$(https_ok "$HTTPS_TIME")"

  read A_AVG A_JIT A_LOSS <<< "$(ping_probe "$PROBE_A_TARGET" 3)"
  read B_AVG B_JIT B_LOSS <<< "$(ping_probe "$PROBE_B_TARGET" 3)"
  read C_AVG C_JIT C_LOSS <<< "$(ping_probe "$PROBE_C_TARGET" 3)"
}

analyze() {
  SCORE_SERVICE=0
  SCORE_RESOURCE=0
  SCORE_EXIT=0
  SCORE_LINK=0
  SCORE_ACCESS=0
  SCORE_DEVICE=0
  SCORE_PLATFORM=0

  if [[ "$XRAY_STATUS" != "active" ]]; then
    SCORE_SERVICE=100
  fi

  awk -v x="$CPU" 'BEGIN{exit !(x>=90)}' && SCORE_RESOURCE=$((SCORE_RESOURCE+45))
  awk -v x="$MEM" 'BEGIN{exit !(x>=90)}' && SCORE_RESOURCE=$((SCORE_RESOURCE+30))
  awk -v x="$CPU" 'BEGIN{exit !(x>=80 && x<90)}' && SCORE_RESOURCE=$((SCORE_RESOURCE+15))
  awk -v x="$MEM" 'BEGIN{exit !(x>=80 && x<90)}' && SCORE_RESOURCE=$((SCORE_RESOURCE+10))

  [[ "$DNS_STATE" != "ok" ]] && SCORE_EXIT=$((SCORE_EXIT+35))
  [[ "$HTTPS_STATE" != "ok" ]] && SCORE_EXIT=$((SCORE_EXIT+60))
  awk -v x="$HTTPS_TIME" 'BEGIN{exit !(x>=1.5 && x<3.0)}' && SCORE_EXIT=$((SCORE_EXIT+20))

  awk -v x="$A_JIT" 'BEGIN{exit !(x>40)}' && SCORE_LINK=$((SCORE_LINK+20))
  awk -v x="$B_JIT" 'BEGIN{exit !(x>40)}' && SCORE_LINK=$((SCORE_LINK+20))
  awk -v x="$C_JIT" 'BEGIN{exit !(x>40)}' && SCORE_LINK=$((SCORE_LINK+15))
  awk -v x="$A_LOSS" 'BEGIN{exit !(x>5)}' && SCORE_LINK=$((SCORE_LINK+20))
  awk -v x="$B_LOSS" 'BEGIN{exit !(x>5)}' && SCORE_LINK=$((SCORE_LINK+20))
  awk -v x="$C_LOSS" 'BEGIN{exit !(x>5)}' && SCORE_LINK=$((SCORE_LINK+15))
  awk -v x="$A_AVG" 'BEGIN{exit !(x>150)}' && SCORE_LINK=$((SCORE_LINK+10))
  awk -v x="$B_AVG" 'BEGIN{exit !(x>150)}' && SCORE_LINK=$((SCORE_LINK+10))
  awk -v x="$C_AVG" 'BEGIN{exit !(x>120)}' && SCORE_LINK=$((SCORE_LINK+8))

  awk -v x="$RETRANS" 'BEGIN{exit !(x>5)}' && SCORE_ACCESS=$((SCORE_ACCESS+35))
  awk -v x="$TX_DELTA" -v c="$CONN" 'BEGIN{exit !(c>0 && x<2000)}' && SCORE_ACCESS=$((SCORE_ACCESS+25))
  awk -v aj="$A_JIT" -v bj="$B_JIT" -v cj="$C_JIT" 'BEGIN{exit !((aj>50||bj>50||cj>50) && (aj<120 && bj<120 && cj<120))}' \
    && SCORE_ACCESS=$((SCORE_ACCESS+15))

  if (( SCORE_SERVICE == 0 && SCORE_RESOURCE < 20 && SCORE_EXIT < 20 && SCORE_LINK < 20 )); then
    awk -v x="$TX_DELTA" -v c="$CONN" 'BEGIN{exit !(c>0 && x<1500)}' && SCORE_DEVICE=$((SCORE_DEVICE+30))
  fi

  if (( SCORE_SERVICE == 0 && SCORE_RESOURCE < 20 && SCORE_EXIT < 20 && SCORE_LINK < 20 && SCORE_ACCESS < 20 && SCORE_DEVICE < 20 )); then
    SCORE_PLATFORM=25
  fi

  local sorted
  sorted="$(top_two_causes)"
  TOP1_NAME="$(echo "$sorted" | sed -n '1p' | awk '{print $1}')"
  TOP1_SCORE="$(echo "$sorted" | sed -n '1p' | awk '{print $2}')"
  TOP2_NAME="$(echo "$sorted" | sed -n '2p' | awk '{print $1}')"
  TOP2_SCORE="$(echo "$sorted" | sed -n '2p' | awk '{print $2}')"

  CURRENT_STATUS="$(status_label)"
  push_history "$CURRENT_STATUS"
  TREND_STATUS="$(trend_label)"
  CONFIDENCE="$(confidence_text "$TOP1_SCORE" "$TOP2_SCORE")"

  SEVERITY_NUM=1
  if [[ "$CURRENT_STATUS" == "波动" ]]; then
    SEVERITY_NUM=2
  fi
  if [[ "$CURRENT_STATUS" == "异常" ]]; then
    SEVERITY_NUM=3
  fi
  if (( TOP1_SCORE >= 80 )); then
    SEVERITY_NUM=4
  fi
  SEVERITY_TEXT="$(severity_text "$SEVERITY_NUM")"

  CONCLUSION="当前直播链路整体正常。"
  SUGGESTION="继续观察。"

  case "$TOP1_NAME" in
    service)
      CONCLUSION="当前异常更像节点服务层故障。"
      SUGGESTION="优先修复 Xray/端口监听，不建议继续直播。"
      ;;
    resource)
      CONCLUSION="当前异常更像节点资源不足。"
      SUGGESTION="降低负载或升级节点配置。"
      ;;
    exit)
      CONCLUSION="当前异常更像节点出口层不稳。"
      SUGGESTION="优先观察 HTTPS 出口，必要时切节点。"
      ;;
    link)
      CONCLUSION="当前异常更像链路层波动。"
      SUGGESTION="继续观察 1~2 分钟；若持续，建议切节点。"
      ;;
    access)
      CONCLUSION="当前异常更像本地接入层不稳。"
      SUGGESTION="优先排查 Wi-Fi/蜂窝信号与本地网络环境。"
      ;;
    device)
      CONCLUSION="当前未见明显节点异常，更像设备侧性能或编码问题。"
      SUGGESTION="关注手机发热、后台、码率和分辨率。"
      ;;
    platform)
      CONCLUSION="当前未见明显节点或链路异常，可能为平台侧波动。"
      SUGGESTION="继续观察；如多节点同样异常，再偏向平台问题。"
      ;;
  esac
}

render() {
  clear
  echo "=============================="
  echo "      直播诊断（实时）"
  echo "=============================="
  echo
  echo "时间: $(date '+%F %T')"
  echo
  echo "当前状态: ${CURRENT_STATUS}"
  echo "趋势判断: ${TREND_STATUS}"
  echo "严重程度: ${SEVERITY_TEXT}"
  echo
  echo "最可能原因: $(reason_text "$TOP1_NAME")"
  echo "备选原因:   $(reason_text "$TOP2_NAME")"
  echo "置信度:     ${CONFIDENCE}"
  echo
  echo "------------------------------"
  echo "关键数据"
  echo "------------------------------"
  echo "Xray:   ${XRAY_STATUS}"
  echo "CPU:    ${CPU}%"
  echo "内存:   ${MEM}%"
  echo "连接:   ${CONN}"
  echo "发送:   ${TX_DELTA} B/s"
  echo "重传:   ${RETRANS}"
  echo "DNS:    ${DNS_STATE}"
  echo "HTTPS:  ${HTTPS_STATE} (${HTTPS_TIME}s)"
  echo
  echo "探针A:  ${A_AVG}ms / jitter ${A_JIT}ms / loss ${A_LOSS}%"
  echo "探针B:  ${B_AVG}ms / jitter ${B_JIT}ms / loss ${B_LOSS}%"
  echo "探针C:  ${C_AVG}ms / jitter ${C_JIT}ms / loss ${C_LOSS}%"
  echo
  echo "------------------------------"
  echo "结论"
  echo "------------------------------"
  echo "${CONCLUSION}"
  echo
  echo "建议: ${SUGGESTION}"
  echo
  echo "q 回车返回管理菜单，Ctrl+C 退出到命令行"
}

diagnose_loop() {
  install_deps
  check_runtime_ready || true

  local stop_flag=0
  trap 'stop_flag=1' INT

  while true; do
    [[ "$stop_flag" -eq 1 ]] && break

    collect_data
    analyze
    render

    echo
    read -r -t 3 -p "输入 q 回车返回管理菜单，或等待自动刷新: " key || key=""
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
