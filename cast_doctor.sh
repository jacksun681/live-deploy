cat > /root/cast_doctor.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONF="/usr/local/etc/xray/config.json"
PORT="443"
PROBE_A_TARGET="8.8.8.8"
PROBE_B_TARGET="1.1.1.1"

BASE_DIR="/root/cast_data"
LOG_DIR="${BASE_DIR}/logs"
mkdir -p "$LOG_DIR"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
NC="\033[0m"

say()  { echo -e "${BLUE}[$(date '+%F %T')]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; }

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
  need_cmd traceroute traceroute
}

check_runtime_ready() {
  [[ -f "$CONF" ]] || { err "配置文件不存在"; return 1; }
  command -v xray >/dev/null 2>&1 || { err "xray 未安装"; return 1; }
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

disk_usage() {
  df / | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

load1() {
  awk '{print $1}' /proc/loadavg
}

conn_443_count() {
  ss -ant 2>/dev/null | awk '/:443 / || /:443$/ {c++} END{print c+0}'
}

dns_check() {
  dig +short google.com >/dev/null 2>&1 && echo "ok" || echo "fail"
}

http_check() {
  curl -I -s --max-time 5 https://www.cloudflare.com >/dev/null 2>&1 && echo "ok" || echo "fail"
}

ping_probe() {
  local target="$1" count="${2:-3}" label="$3"
  local out loss avg jitter
  out="$(ping -c "$count" -W 1 "$target" 2>/dev/null || true)"

  loss="$(echo "$out" | awk -F',' '/packet loss/ {
    gsub(/^ +| +$/, "", $3); sub(/% packet loss/, "", $3); print $3
  }')"
  avg="$(echo "$out" | awk -F'/' '/^rtt|^round-trip/ {print $5}')"
  jitter="$(echo "$out" | awk -F'/' '/^rtt|^round-trip/ {print $7}')"

  [[ -z "${loss:-}" ]] && loss="100"
  [[ -z "${avg:-}" ]] && avg="0"
  [[ -z "${jitter:-}" ]] && jitter="0"

  printf '%s|%.3f|%s|%.3f\n' "$label" "$avg" "$loss" "$jitter"
}

probe_pair() {
  local a b
  a="$(ping_probe "$PROBE_A_TARGET" "${1:-3}" "探针A")"
  b="$(ping_probe "$PROBE_B_TARGET" "${1:-3}" "探针B")"
  echo "$a"$'\n'"$b"
}

traffic_delta() {
  local iface="$1" rx1 tx1 rx2 tx2
  rx1="$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)"
  tx1="$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)"
  sleep 1
  rx2="$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)"
  tx2="$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)"
  echo "$((rx2-rx1))|$((tx2-tx1))"
}

stream_activity_text() {
  local conn="$1" rx="$2" tx="$3"
  if [[ "$conn" -le 0 ]]; then
    echo "空闲"
  elif [[ "$rx" -gt 4096 || "$tx" -gt 4096 ]]; then
    echo "持续活跃"
  else
    echo "已连接"
  fi
}

show_header() {
  echo
  echo "======================================"
  echo "          CAST 专业诊断工具"
  echo "======================================"
}

show_basic_info() {
  say "基础信息"
  echo "主机名      : $(hostname)"
  echo "系统时间    : $(date)"
  echo "内核版本    : $(uname -r)"
  echo "出口网卡    : $(get_iface)"
  echo "Xray状态    : $(systemctl is-active xray 2>/dev/null || true)"
  echo "443监听     : $(ss -lntp 2>/dev/null | grep -q ":${PORT} " && echo yes || echo no)"
  echo
}

show_resources() {
  say "系统资源"
  echo "CPU占用     : $(cpu_usage)%"
  echo "内存占用    : $(mem_usage)%"
  echo "磁盘占用    : $(disk_usage)%"
  echo "1分钟负载   : $(load1)"
  echo "443连接数   : $(conn_443_count)"
  echo
}

show_network_base() {
  say "网络基础状态"
  echo "默认路由:"
  ip route | sed 's/^/  /'
  echo
  echo "监听端口:"
  ss -tuln | sed 's/^/  /'
  echo
}

runtime_snapshot() {
  local iface conn rx tx activity
  iface="$(get_iface)"
  conn="$(conn_443_count)"
  IFS='|' read -r rx tx <<< "$(traffic_delta "$iface")"
  activity="$(stream_activity_text "$conn" "$rx" "$tx")"
  echo "$(systemctl is-active xray 2>/dev/null || true)|$(cpu_usage)|$(mem_usage)|$conn|$activity|$(http_check)"
}

print_probe_lines() {
  local a_line b_line
  a_line="$(echo "$1" | sed -n '1p')"
  b_line="$(echo "$1" | sed -n '2p')"

  IFS='|' read -r a_name a_avg a_loss a_jit <<< "$a_line"
  IFS='|' read -r b_name b_avg b_loss b_jit <<< "$b_line"

  echo "$a_name: ${a_avg}ms / jitter ${a_jit}ms / loss ${a_loss}%"
  echo "$b_name: ${b_avg}ms / jitter ${b_jit}ms / loss ${b_loss}%"
}

judge_watch_status() {
  local xray="$1" cpu="$2" mem="$3" activity="$4" https="$5" a_avg="$6" a_jit="$7" b_avg="$8" b_jit="$9"

  local level="稳定" verdict="直播正常" detail="链路活跃"

  if [[ "$xray" != "active" ]]; then
    level="异常"; verdict="服务异常"; detail="Xray 未运行"
  elif [[ "$https" != "ok" && "$https" != "OK" ]]; then
    level="异常"; verdict="出口异常"; detail="HTTPS 不通"
  elif (( $(echo "$cpu >= 90 || $mem >= 90" | bc -l) )); then
    level="风险"; verdict="资源异常"; detail="CPU 或内存过高"
  elif [[ "$activity" == "空闲" ]]; then
    if (( $(echo "$a_avg > 0 && $a_avg < 80 && $b_avg > 0 && $b_avg < 150 && $a_jit < 30 && $b_jit < 40" | bc -l) )); then
      level="稳定"; verdict="空闲"; detail="未检测到明显推流连接"
    else
      level="轻微波动"; verdict="空闲"; detail="当前无推流，链路参考值有波动"
    fi
  else
    if (( $(echo "$a_avg > 150 || $b_avg > 220 || $a_jit > 50 || $b_jit > 70" | bc -l) )); then
      level="风险"; verdict="直播正常"; detail="链路活跃，但延迟或抖动偏高"
    elif (( $(echo "$a_avg > 80 || $b_avg > 150 || $a_jit > 25 || $b_jit > 35" | bc -l) )); then
      level="轻微波动"; verdict="直播正常"; detail="链路活跃，存在轻微波动"
    fi
  fi

  echo "$level|$verdict|$detail"
}

safe_inspect() {
  local logfile="${LOG_DIR}/safe_$(date +%F_%H%M%S).log"
  {
    show_header
    show_basic_info
    show_resources

    say "低干扰网络检测"
    local probes dns http cpu mem disk
    probes="$(probe_pair 3)"
    dns="$(dns_check)"
    http="$(http_check)"
    print_probe_lines "$probes"
    echo "DNS状态    : ${dns}"
    echo "HTTPS出口  : ${http}"
    echo

    say "自动判断"
    cpu="$(cpu_usage)"
    mem="$(mem_usage)"
    disk="$(disk_usage)"

    [[ "$disk" -ge 90 ]] 2>/dev/null && warn "磁盘占用偏高"
    awk "BEGIN{exit !($cpu > 85)}" && err "更像是本机 CPU 压力过高"
    awk "BEGIN{exit !($mem > 90)}" && err "更像是本机内存压力过高"
    [[ "$dns" != "ok" ]] && err "更像是 DNS 解析异常"
    [[ "$http" != "ok" ]] && err "HTTPS 出口访问异常"

    echo
    show_network_base
  } | tee "$logfile"

  ok "安全巡检完成，日志已保存: $logfile"
  echo
}

light_monitor() {
  local duration="${1:-60}" interval="${2:-5}" target="${3:-8.8.8.8}"
  local iface logfile
  iface="$(get_iface)"
  logfile="${LOG_DIR}/monitor_${duration}s_$(date +%F_%H%M%S).csv"

  echo "time,cpu_usage,mem_usage,load1,rx_bytes,tx_bytes,ping_ms,loss_percent,jitter_ms" > "$logfile"

  say "开始轻量监控 ${duration} 秒，每 ${interval} 秒采样一次"
  say "这是低干扰模式，不会改网络，也不会断网"
  say "日志文件: $logfile"

  local count=$((duration / interval))
  [[ "$count" -lt 1 ]] && count=1

  local high_ping=0 high_jitter=0 high_cpu=0 high_mem=0
  local ping_sum=0 loss_sum=0 jitter_sum=0 samples=0

  for ((i=1; i<=count; i++)); do
    local now cpu mem load rx tx stats avg loss jit label
    now="$(date '+%F %T')"
    cpu="$(cpu_usage)"
    mem="$(mem_usage)"
    load="$(load1)"
    rx="$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)"
    tx="$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)"
    stats="$(ping_probe "$target" 3 "监控")"
    IFS='|' read -r label avg loss jit <<< "$stats"

    echo "${now},${cpu},${mem},${load},${rx},${tx},${avg},${loss},${jit}" | tee -a "$logfile"

    ping_sum="$(awk -v a="$ping_sum" -v b="$avg" 'BEGIN{print a+b}')"
    loss_sum="$(awk -v a="$loss_sum" -v b="$loss" 'BEGIN{print a+b}')"
    jitter_sum="$(awk -v a="$jitter_sum" -v b="$jit" 'BEGIN{print a+b}')"
    samples=$((samples+1))

    awk "BEGIN{exit !($avg > 200)}" && high_ping=$((high_ping+1))
    awk "BEGIN{exit !($jit > 80)}" && high_jitter=$((high_jitter+1))
    awk "BEGIN{exit !($cpu > 85)}" && high_cpu=$((high_cpu+1))
    awk "BEGIN{exit !($mem > 90)}" && high_mem=$((high_mem+1))

    sleep "$interval"
  done

  echo
  say "监控总结"
  echo "平均延迟      : $(awk -v a="$ping_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}') ms"
  echo "平均丢包      : $(awk -v a="$loss_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}')%"
  echo "平均抖动      : $(awk -v a="$jitter_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}') ms"
  echo "高延迟次数    : ${high_ping}"
  echo "高抖动次数    : ${high_jitter}"
  echo "高CPU次数     : ${high_cpu}"
  echo "高内存次数    : ${high_mem}"
  echo

  [[ "$high_ping" -ge 2 ]] && warn "更像是链路存在明显延迟波动"
  [[ "$high_jitter" -ge 2 ]] && warn "更像是链路存在明显抖动"
  [[ "$high_cpu" -ge 2 ]] && err "更像是 VPS CPU 性能瓶颈"
  [[ "$high_mem" -ge 2 ]] && err "更像是 VPS 内存瓶颈"

  ok "轻量监控完成，日志已保存: $logfile"
  echo
}

deep_diag() {
  local logfile="${LOG_DIR}/deep_$(date +%F_%H%M%S).log"
  {
    show_header
    say "深度诊断建议在下播后运行"
    echo
    show_basic_info
    show_resources

    say "详细网络检测"
    local probes dns http
    probes="$(probe_pair 5)"
    dns="$(dns_check)"
    http="$(http_check)"
    print_probe_lines "$probes"
    echo "DNS       -> ${dns}"
    echo "HTTPS出口 -> ${http}"
    echo

    say "路由跟踪（轻度）"
    traceroute -m 8 8.8.8.8 || warn "traceroute 执行失败"
    echo

    show_network_base
  } | tee "$logfile"

  ok "深度诊断完成，日志已保存: $logfile"
  echo
}

live_sim_diag() {
  local duration=120 interval=5 iface logfile
  iface="$(get_iface)"
  logfile="${LOG_DIR}/sim_${duration}s_$(date +%F_%H%M%S).csv"

  echo "time,cpu,mem,load1,rx,tx,a_ping,a_loss,a_jitter,b_ping,b_loss,b_jitter,dns,http" > "$logfile"

  say "开始综合诊断（直播仿真）"
  say "说明：低干扰连续采样，尽量接近直播时的持续状态"
  say "持续时间: ${duration} 秒，每 ${interval} 秒采样一次"
  say "不会改网络，不会断网，不会跑重压测速"
  echo

  local count=$((duration / interval))
  [[ "$count" -lt 1 ]] && count=1

  local cpu_sum=0 mem_sum=0 a_sum=0 b_sum=0 a_jit_sum=0 b_jit_sum=0
  local cpu_max=0 mem_max=0 high_cpu=0 high_mem=0 high_a=0 high_b=0 dns_fail=0 http_fail=0 samples=0

  for ((i=1; i<=count; i++)); do
    local now cpu mem load rx tx dns http probes a_line b_line a_avg a_loss a_jit b_avg b_loss b_jit
    now="$(date '+%F %T')"
    cpu="$(cpu_usage)"
    mem="$(mem_usage)"
    load="$(load1)"
    rx="$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)"
    tx="$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)"
    dns="$(dns_check)"
    http="$(http_check)"
    probes="$(probe_pair 3)"
    a_line="$(echo "$probes" | sed -n '1p')"
    b_line="$(echo "$probes" | sed -n '2p')"
    IFS='|' read -r _ a_avg a_loss a_jit <<< "$a_line"
    IFS='|' read -r _ b_avg b_loss b_jit <<< "$b_line"

    echo "${now},${cpu},${mem},${load},${rx},${tx},${a_avg},${a_loss},${a_jit},${b_avg},${b_loss},${b_jit},${dns},${http}" | tee -a "$logfile"

    cpu_sum="$(awk -v a="$cpu_sum" -v b="$cpu" 'BEGIN{print a+b}')"
    mem_sum="$(awk -v a="$mem_sum" -v b="$mem" 'BEGIN{print a+b}')"
    a_sum="$(awk -v a="$a_sum" -v b="$a_avg" 'BEGIN{print a+b}')"
    b_sum="$(awk -v a="$b_sum" -v b="$b_avg" 'BEGIN{print a+b}')"
    a_jit_sum="$(awk -v a="$a_jit_sum" -v b="$a_jit" 'BEGIN{print a+b}')"
    b_jit_sum="$(awk -v a="$b_jit_sum" -v b="$b_jit" 'BEGIN{print a+b}')"
    samples=$((samples+1))

    awk "BEGIN{exit !($cpu > $cpu_max)}" && cpu_max="$cpu"
    awk "BEGIN{exit !($mem > $mem_max)}" && mem_max="$mem"
    awk "BEGIN{exit !($cpu > 85)}" && high_cpu=$((high_cpu+1))
    awk "BEGIN{exit !($mem > 90)}" && high_mem=$((high_mem+1))
    awk "BEGIN{exit !($a_avg > 200)}" && high_a=$((high_a+1))
    awk "BEGIN{exit !($b_avg > 250)}" && high_b=$((high_b+1))
    [[ "$dns" != "ok" ]] && dns_fail=$((dns_fail+1))
    [[ "$http" != "ok" ]] && http_fail=$((http_fail+1))

    sleep "$interval"
  done

  echo
  say "直播仿真统计结果"
  echo "平均CPU         : $(awk -v a="$cpu_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}')%"
  echo "峰值CPU         : ${cpu_max}%"
  echo "平均内存        : $(awk -v a="$mem_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}')%"
  echo "峰值内存        : ${mem_max}%"
  echo "探针A平均延迟   : $(awk -v a="$a_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}') ms"
  echo "探针A平均抖动   : $(awk -v a="$a_jit_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}') ms"
  echo "探针B平均延迟   : $(awk -v a="$b_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}') ms"
  echo "探针B平均抖动   : $(awk -v a="$b_jit_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}') ms"
  echo "高CPU次数       : ${high_cpu}"
  echo "高内存次数      : ${high_mem}"
  echo "探针A高延迟次数 : ${high_a}"
  echo "探针B高延迟次数 : ${high_b}"
  echo "DNS异常次数     : ${dns_fail}"
  echo "HTTPS异常次数   : ${http_fail}"
  echo

  local perf_score=0 line_score=0 exit_score=0 platform_score=0
  [[ "$high_cpu" -ge 2 ]] && perf_score=$((perf_score+3))
  [[ "$high_mem" -ge 2 ]] && perf_score=$((perf_score+3))
  [[ "$high_a" -ge 2 ]] && line_score=$((line_score+3))
  [[ "$high_b" -ge 2 ]] && exit_score=$((exit_score+3))
  [[ "$dns_fail" -ge 1 ]] && exit_score=$((exit_score+2))
  [[ "$http_fail" -ge 1 ]] && exit_score=$((exit_score+3))
  [[ "$perf_score" -eq 0 && "$line_score" -eq 0 && "$exit_score" -eq 0 ]] && platform_score=5

  echo "性能问题分数     : ${perf_score}"
  echo "链路问题分数     : ${line_score}"
  echo "出口问题分数     : ${exit_score}"
  echo "平台/编码分数    : ${platform_score}"
  echo
  ok "综合诊断（直播仿真）完成，日志已保存: $logfile"
  echo
}

watch_once() {
  local xray cpu mem conn activity http probes a_line b_line a_avg a_loss a_jit b_avg b_loss b_jit status
  IFS='|' read -r xray cpu mem conn activity http <<< "$(runtime_snapshot)"
  probes="$(probe_pair 2)"
  a_line="$(echo "$probes" | sed -n '1p')"
  b_line="$(echo "$probes" | sed -n '2p')"
  IFS='|' read -r _ a_avg a_loss a_jit <<< "$a_line"
  IFS='|' read -r _ b_avg b_loss b_jit <<< "$b_line"
  status="$(judge_watch_status "$xray" "$cpu" "$mem" "$activity" "$http" "$a_avg" "$a_jit" "$b_avg" "$b_jit")"

  local level verdict detail
  IFS='|' read -r level verdict detail <<< "$status"

  clear
  echo "=============================="
  echo "         CAST WATCH"
  echo "=============================="
  echo
  echo "时间: $(date '+%F %T')"
  echo
  echo "Xray: $xray"
  echo "资源: CPU ${cpu}% / 内存 ${mem}%"
  echo "推流: ${activity}（443连接 ${conn}）"
  echo "出口: ${http^^}"
  echo
  echo "探针A: ${a_avg}ms / jitter ${a_jit}ms / loss ${a_loss}%"
  echo "探针B: ${b_avg}ms / jitter ${b_jit}ms / loss ${b_loss}%"
  echo
  echo "等级: $level"
  echo "结论: $verdict"
  echo "说明: $detail"
  echo
  echo "Ctrl+C 返回菜单，输入 q 后回车退出到命令行"
}

watch_loop() {
  install_deps
  check_runtime_ready || true

  local stop_flag=0 quit_flag=0 key=""
  trap 'stop_flag=1' INT

  while true; do
    [[ "$stop_flag" -eq 1 ]] && break
    watch_once
    key=""
    if read -r -t 5 key 2>/dev/null; then
      case "$key" in
        q|Q) quit_flag=1; break ;;
      esac
    fi
  done

  trap - INT
  echo
  if [[ "$quit_flag" -eq 1 ]]; then
    echo "已结束监控，退出到命令行。"
    return 99
  else
    echo "已结束监控，返回菜单..."
    sleep 1
    return 0
  fi
}

show_recent_logs() {
  echo
  say "最近日志"
  ls -lh "$LOG_DIR" 2>/dev/null || true
  echo
}

doctor_menu() {
  while true; do
    clear
    cat <<EOF2
==============================
        CAST 诊断菜单
==============================
1. 综合诊断（直播仿真，最推荐）
2. 安全巡检（直播中可用）
3. 轻量监控 60 秒
4. 轻量监控 180 秒
5. 深度诊断（建议下播后）
6. 查看最近日志
7. 实时监控
0. 返回上级菜单
==============================
EOF2

    read -rp "请选择: " num
    case "$num" in
      1) live_sim_diag ;;
      2) safe_inspect ;;
      3) light_monitor 60 5 8.8.8.8 ;;
      4) light_monitor 180 5 8.8.8.8 ;;
      5) deep_diag ;;
      6) show_recent_logs ;;
      7)
        watch_loop
        rc=$?
        [[ "$rc" -eq 99 ]] && exit 0
        ;;
      0) return 0 ;;
      *) warn "无效选择" ;;
    esac
    echo
    read -rp "按回车返回诊断菜单..." _
  done
}

main() {
  install_deps
  check_runtime_ready || true

  case "${1:-menu}" in
    doctor|menu) doctor_menu ;;
    safe) safe_inspect ;;
    sim) live_sim_diag ;;
    deep) deep_diag ;;
    monitor) light_monitor "${2:-60}" 5 8.8.8.8 ;;
    watch)
      watch_loop
      rc=$?
      [[ "$rc" -eq 99 ]] && exit 0
      ;;
    *)
      echo "用法:"
      echo "  bash cast_doctor.sh doctor"
      echo "  bash cast_doctor.sh safe"
      echo "  bash cast_doctor.sh sim"
      echo "  bash cast_doctor.sh deep"
      echo "  bash cast_doctor.sh monitor 60"
      echo "  bash cast_doctor.sh watch"
      exit 1
      ;;
  esac
}

main "$@"
EOF
