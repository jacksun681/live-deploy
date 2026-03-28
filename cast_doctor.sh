cat > /root/cast_doctor.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONF="/usr/local/etc/xray/config.json"
PORT="443"

HK_TEST_TARGET="8.8.8.8"
GLOBAL_TEST_TARGET="1.1.1.1"

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
    split($1,a,",");
    gsub(/ /,"",a[length(a)]);
    if (a[length(a)] == "") print "0";
    else printf("%.1f\n", 100-a[length(a)]);
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

dns_check() {
  if dig +short google.com >/dev/null 2>&1; then
    echo "ok"
  else
    echo "fail"
  fi
}

http_check() {
  if curl -I -s --max-time 5 https://www.cloudflare.com >/dev/null 2>&1; then
    echo "ok"
  else
    echo "fail"
  fi
}

ping_probe() {
  local target="$1"
  local count="${2:-3}"
  local label="$3"

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

  printf '%s|%.3f|%s|%.3f\n' "$label" "$avg" "$loss" "$jitter"
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
  echo "连接数      : $(ss -tn state established 2>/dev/null | tail -n +2 | wc -l | awk '{print $1}')"
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

safe_inspect() {
  local logfile="${LOG_DIR}/safe_$(date +%F_%H%M%S).log"
  {
    show_header
    show_basic_info
    show_resources

    say "低干扰网络检测"
    local hk_stats gl_stats dns http
    hk_stats="$(ping_probe "$HK_TEST_TARGET" 3 "香港")"
    gl_stats="$(ping_probe "$GLOBAL_TEST_TARGET" 3 "全球")"
    dns="$(dns_check)"
    http="$(http_check)"

    IFS='|' read -r hk_label hk_avg hk_loss hk_jit <<< "$hk_stats"
    IFS='|' read -r gl_label gl_avg gl_loss gl_jit <<< "$gl_stats"

    echo "${hk_label}延迟 : ${hk_avg} ms"
    echo "${hk_label}丢包 : ${hk_loss}%"
    echo "${hk_label}抖动 : ${hk_jit} ms"
    echo "${gl_label}延迟 : ${gl_avg} ms"
    echo "${gl_label}丢包 : ${gl_loss}%"
    echo "${gl_label}抖动 : ${gl_jit} ms"
    echo "DNS状态    : ${dns}"
    echo "HTTPS出口  : ${http}"
    echo

    say "自动判断"
    local FLAG=0
    local cpu mem disk
    cpu="$(cpu_usage)"
    mem="$(mem_usage)"
    disk="$(disk_usage)"

    awk "BEGIN{exit !($cpu > 85)}" && { err "更像是本机 CPU 压力过高"; FLAG=1; }
    awk "BEGIN{exit !($mem > 90)}" && { err "更像是本机内存压力过高"; FLAG=1; }
    [[ "$disk" -ge 90 ]] 2>/dev/null && { warn "磁盘占用偏高"; FLAG=1; }

    awk "BEGIN{exit !(($hk_avg > 200) || ($gl_avg > 200))}" && { warn "延迟偏高"; FLAG=1; }
    awk "BEGIN{exit !(($hk_jit > 60) || ($gl_jit > 80))}" && { warn "抖动偏高"; FLAG=1; }

    [[ "$dns" != "ok" ]] && { err "更像是 DNS 解析异常"; FLAG=1; }
    [[ "$http" != "ok" ]] && { err "HTTPS 出口访问异常"; FLAG=1; }

    if [[ "$FLAG" -eq 0 ]]; then
      ok "当前基础指标正常，更像是偶发波动、平台侧波动，或直播端编码参数问题"
    fi

    echo
    show_network_base
  } | tee "$logfile"

  ok "安全巡检完成，日志已保存: $logfile"
  echo
}

light_monitor() {
  local duration="${1:-60}"
  local interval="${2:-5}"
  local target="${3:-8.8.8.8}"
  local iface logfile
  iface="$(get_iface)"
  logfile="${LOG_DIR}/monitor_${duration}s_$(date +%F_%H%M%S).csv"

  echo "time,cpu_usage,mem_usage,load1,rx_bytes,tx_bytes,ping_ms,loss_percent,jitter_ms" > "$logfile"

  say "开始轻量监控 ${duration} 秒，每 ${interval} 秒采样一次"
  say "这是低干扰模式，不会改网络，也不会断网"
  say "日志文件: $logfile"

  local count=$((duration / interval))
  [[ "$count" -lt 1 ]] && count=1

  local high_ping=0
  local high_jitter=0
  local high_cpu=0
  local high_mem=0
  local ping_sum=0
  local loss_sum=0
  local jitter_sum=0
  local samples=0

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

    [[ -z "${avg:-}" ]] && avg=0
    [[ -z "${loss:-}" ]] && loss=100
    [[ -z "${jit:-}" ]] && jit=0

    echo "${now},${cpu},${mem},${load},${rx},${tx},${avg},${loss},${jit}" | tee -a "$logfile"

    ping_sum="$(awk -v a="$ping_sum" -v b="$avg" 'BEGIN{print a+b}')"
    loss_sum="$(awk -v a="$loss_sum" -v b="$loss" 'BEGIN{print a+b}')"
    jitter_sum="$(awk -v a="$jitter_sum" -v b="$jit" 'BEGIN{print a+b}')"
    samples=$((samples+1))

    awk "BEGIN{exit !($avg > 200)}" && { warn "告警：延迟 ${avg} ms"; high_ping=$((high_ping+1)); }
    awk "BEGIN{exit !($jit > 80)}" && { warn "告警：抖动 ${jit} ms"; high_jitter=$((high_jitter+1)); }
    awk "BEGIN{exit !($cpu > 85)}" && { warn "告警：CPU ${cpu}%"; high_cpu=$((high_cpu+1)); }
    awk "BEGIN{exit !($mem > 90)}" && { warn "告警：内存 ${mem}%"; high_mem=$((high_mem+1)); }

    sleep "$interval"
  done

  local avg_ping avg_loss avg_jitter
  avg_ping="$(awk -v a="$ping_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}')"
  avg_loss="$(awk -v a="$loss_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}')"
  avg_jitter="$(awk -v a="$jitter_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}')"

  echo
  say "监控总结"
  echo "平均延迟      : ${avg_ping} ms"
  echo "平均丢包      : ${avg_loss}%"
  echo "平均抖动      : ${avg_jitter} ms"
  echo "高延迟次数    : ${high_ping}"
  echo "高抖动次数    : ${high_jitter}"
  echo "高CPU次数     : ${high_cpu}"
  echo "高内存次数    : ${high_mem}"
  echo

  local FLAG=0
  [[ "$high_ping" -ge 2 ]] && { warn "更像是链路存在明显延迟波动"; FLAG=1; }
  [[ "$high_jitter" -ge 2 ]] && { warn "更像是链路存在明显抖动"; FLAG=1; }
  [[ "$high_cpu" -ge 2 ]] && { err "更像是 VPS CPU 性能瓶颈"; FLAG=1; }
  [[ "$high_mem" -ge 2 ]] && { err "更像是 VPS 内存瓶颈"; FLAG=1; }

  if [[ "$FLAG" -eq 0 ]]; then
    ok "监控期间整体平稳，未发现明显机器或线路异常"
  fi

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
    local hk_stats gl_stats dns http
    hk_stats="$(ping_probe "$HK_TEST_TARGET" 5 "香港")"
    gl_stats="$(ping_probe "$GLOBAL_TEST_TARGET" 5 "全球")"
    dns="$(dns_check)"
    http="$(http_check)"

    IFS='|' read -r hk_label hk_avg hk_loss hk_jit <<< "$hk_stats"
    IFS='|' read -r gl_label gl_avg gl_loss gl_jit <<< "$gl_stats"

    echo "${hk_label} -> 延迟 ${hk_avg} ms / 丢包 ${hk_loss}% / 抖动 ${hk_jit} ms"
    echo "${gl_label} -> 延迟 ${gl_avg} ms / 丢包 ${gl_loss}% / 抖动 ${gl_jit} ms"
    echo "DNS       -> ${dns}"
    echo "HTTPS出口 -> ${http}"
    echo

    say "路由跟踪（轻度）"
    traceroute -m 8 8.8.8.8 || warn "traceroute 执行失败"
    echo

    show_network_base

    say "自动判断"
    local FLAG=0
    local cpu mem disk
    cpu="$(cpu_usage)"
    mem="$(mem_usage)"
    disk="$(disk_usage)"

    awk "BEGIN{exit !($cpu > 85)}" && { err "更像是本机 CPU 压力过高"; FLAG=1; }
    awk "BEGIN{exit !($mem > 90)}" && { err "更像是本机内存压力过高"; FLAG=1; }
    [[ "$disk" -ge 90 ]] 2>/dev/null && { warn "磁盘占用偏高"; FLAG=1; }

    awk "BEGIN{exit !(($hk_avg > 200) || ($gl_avg > 200))}" && { warn "更像是线路延迟过高"; FLAG=1; }
    awk "BEGIN{exit !(($hk_jit > 60) || ($gl_jit > 80))}" && { warn "更像是线路抖动偏高"; FLAG=1; }

    [[ "$dns" != "ok" ]] && { err "更像是 DNS 解析异常"; FLAG=1; }
    [[ "$http" != "ok" ]] && { err "更像是 HTTPS 出口异常"; FLAG=1; }

    if [[ "$FLAG" -eq 0 ]]; then
      ok "深度诊断未发现明显异常，更像是直播推流参数、平台侧波动或上游链路偶发问题"
    fi
  } | tee "$logfile"

  ok "深度诊断完成，日志已保存: $logfile"
  echo
}

live_sim_diag() {
  local duration=120
  local interval=5
  local iface logfile
  iface="$(get_iface)"
  logfile="${LOG_DIR}/sim_${duration}s_$(date +%F_%H%M%S).csv"

  echo "time,cpu_usage,mem_usage,load1,rx_bytes,tx_bytes,hk_ping_ms,hk_loss,hk_jitter,gl_ping_ms,gl_loss,gl_jitter,dns,http" > "$logfile"

  say "开始综合诊断（直播仿真）"
  say "说明：低干扰连续采样，尽量接近直播时的持续状态"
  say "持续时间: ${duration} 秒，每 ${interval} 秒采样一次"
  say "不会改网络，不会断网，不会跑重压测速"
  echo

  local count=$((duration / interval))
  [[ "$count" -lt 1 ]] && count=1

  local cpu_sum=0 mem_sum=0 hk_sum=0 gl_sum=0 hk_loss_sum=0 gl_loss_sum=0
  local cpu_max=0 mem_max=0 hk_max=0 gl_max=0
  local high_cpu=0 high_mem=0 high_hk=0 high_gl=0
  local hk_jitter_sum=0 gl_jitter_sum=0
  local dns_fail=0 http_fail=0
  local samples=0

  for ((i=1; i<=count; i++)); do
    local now cpu mem load rx tx dns http
    local hk_stats gl_stats hk_avg hk_loss hk_jitter gl_avg gl_loss gl_jitter

    now="$(date '+%F %T')"
    cpu="$(cpu_usage)"
    mem="$(mem_usage)"
    load="$(load1)"
    rx="$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)"
    tx="$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)"
    dns="$(dns_check)"
    http="$(http_check)"

    hk_stats="$(ping_probe "$HK_TEST_TARGET" 3 "香港")"
    gl_stats="$(ping_probe "$GLOBAL_TEST_TARGET" 3 "全球")"

    IFS='|' read -r _ hk_avg hk_loss hk_jitter <<< "$hk_stats"
    IFS='|' read -r _ gl_avg gl_loss gl_jitter <<< "$gl_stats"

    echo "${now},${cpu},${mem},${load},${rx},${tx},${hk_avg},${hk_loss},${hk_jitter},${gl_avg},${gl_loss},${gl_jitter},${dns},${http}" | tee -a "$logfile"

    cpu_sum="$(awk -v a="$cpu_sum" -v b="$cpu" 'BEGIN{print a+b}')"
    mem_sum="$(awk -v a="$mem_sum" -v b="$mem" 'BEGIN{print a+b}')"
    hk_sum="$(awk -v a="$hk_sum" -v b="$hk_avg" 'BEGIN{print a+b}')"
    gl_sum="$(awk -v a="$gl_sum" -v b="$gl_avg" 'BEGIN{print a+b}')"
    hk_loss_sum="$(awk -v a="$hk_loss_sum" -v b="$hk_loss" 'BEGIN{print a+b}')"
    gl_loss_sum="$(awk -v a="$gl_loss_sum" -v b="$gl_loss" 'BEGIN{print a+b}')"
    hk_jitter_sum="$(awk -v a="$hk_jitter_sum" -v b="$hk_jitter" 'BEGIN{print a+b}')"
    gl_jitter_sum="$(awk -v a="$gl_jitter_sum" -v b="$gl_jitter" 'BEGIN{print a+b}')"
    samples=$((samples+1))

    awk "BEGIN{exit !($cpu > $cpu_max)}" && cpu_max="$cpu"
    awk "BEGIN{exit !($mem > $mem_max)}" && mem_max="$mem"
    awk "BEGIN{exit !($hk_avg > $hk_max)}" && hk_max="$hk_avg"
    awk "BEGIN{exit !($gl_avg > $gl_max)}" && gl_max="$gl_avg"

    awk "BEGIN{exit !($cpu > 85)}" && high_cpu=$((high_cpu+1))
    awk "BEGIN{exit !($mem > 90)}" && high_mem=$((high_mem+1))
    awk "BEGIN{exit !($hk_avg > 200)}" && high_hk=$((high_hk+1))
    awk "BEGIN{exit !($gl_avg > 250)}" && high_gl=$((high_gl+1))

    [[ "$dns" != "ok" ]] && dns_fail=$((dns_fail+1))
    [[ "$http" != "ok" ]] && http_fail=$((http_fail+1))

    sleep "$interval"
  done

  local avg_cpu avg_mem avg_hk avg_gl avg_hk_loss avg_gl_loss avg_hk_jitter avg_gl_jitter
  avg_cpu="$(awk -v a="$cpu_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}')"
  avg_mem="$(awk -v a="$mem_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}')"
  avg_hk="$(awk -v a="$hk_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}')"
  avg_gl="$(awk -v a="$gl_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}')"
  avg_hk_loss="$(awk -v a="$hk_loss_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}')"
  avg_gl_loss="$(awk -v a="$gl_loss_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}')"
  avg_hk_jitter="$(awk -v a="$hk_jitter_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}')"
  avg_gl_jitter="$(awk -v a="$gl_jitter_sum" -v c="$samples" 'BEGIN{if(c>0) printf("%.1f",a/c); else print "0"}')"

  echo
  say "直播仿真统计结果"
  echo "平均CPU         : ${avg_cpu}%"
  echo "峰值CPU         : ${cpu_max}%"
  echo "平均内存        : ${avg_mem}%"
  echo "峰值内存        : ${mem_max}%"
  echo "香港平均延迟    : ${avg_hk} ms"
  echo "香港平均丢包    : ${avg_hk_loss}%"
  echo "香港平均抖动    : ${avg_hk_jitter} ms"
  echo "全球平均延迟    : ${avg_gl} ms"
  echo "全球平均丢包    : ${avg_gl_loss}%"
  echo "全球平均抖动    : ${avg_gl_jitter} ms"
  echo "高CPU次数       : ${high_cpu}"
  echo "高内存次数      : ${high_mem}"
  echo "香港高延迟次数  : ${high_hk}"
  echo "全球高延迟次数  : ${high_gl}"
  echo "DNS异常次数     : ${dns_fail}"
  echo "HTTPS异常次数   : ${http_fail}"
  echo

  local perf_score=0
  local line_score=0
  local exit_score=0
  local platform_score=0

  awk "BEGIN{exit !($avg_cpu > 70)}" && perf_score=$((perf_score+2))
  awk "BEGIN{exit !($cpu_max > 85)}" && perf_score=$((perf_score+3))
  [[ "$high_cpu" -ge 2 ]] && perf_score=$((perf_score+3))

  awk "BEGIN{exit !($avg_mem > 80)}" && perf_score=$((perf_score+2))
  awk "BEGIN{exit !($mem_max > 90)}" && perf_score=$((perf_score+3))
  [[ "$high_mem" -ge 2 ]] && perf_score=$((perf_score+3))

  awk "BEGIN{exit !($avg_hk > 120)}" && line_score=$((line_score+2))
  awk "BEGIN{exit !($avg_hk_jitter > 40)}" && line_score=$((line_score+3))
  [[ "$high_hk" -ge 2 ]] && line_score=$((line_score+2))

  awk "BEGIN{exit !($avg_gl > 180)}" && exit_score=$((exit_score+2))
  awk "BEGIN{exit !($avg_gl_jitter > 50)}" && exit_score=$((exit_score+3))
  [[ "$high_gl" -ge 2 ]] && exit_score=$((exit_score+2))

  [[ "$dns_fail" -ge 1 ]] && exit_score=$((exit_score+2))
  [[ "$http_fail" -ge 1 ]] && exit_score=$((exit_score+3))

  if [[ "$perf_score" -eq 0 && "$line_score" -eq 0 && "$exit_score" -eq 0 ]]; then
    platform_score=$((platform_score+5))
  fi

  echo "--------------------------------------"
  say "综合评分"
  echo "性能问题分数     : ${perf_score}"
  echo "链路问题分数     : ${line_score}"
  echo "出口问题分数     : ${exit_score}"
  echo "平台/编码分数    : ${platform_score}"
  echo "--------------------------------------"

  local max_score=0
  local top_reason=""
  local second_score=0
  local second_reason=""

  for item in "性能问题:${perf_score}" "链路问题:${line_score}" "出口问题:${exit_score}" "平台/编码问题:${platform_score}"; do
    local name score
    name="${item%%:*}"
    score="${item##*:}"

    if [[ "$score" -gt "$max_score" ]]; then
      second_score="$max_score"
      second_reason="$top_reason"
      max_score="$score"
      top_reason="$name"
    elif [[ "$score" -gt "$second_score" ]]; then
      second_score="$score"
      second_reason="$name"
    fi
  done

  say "综合结论"
  echo "最可能原因      : ${top_reason:-未识别}"
  [[ -n "${second_reason:-}" ]] && echo "次可能原因      : ${second_reason}"
  echo

  say "判断依据"
  case "$top_reason" in
    "性能问题")
      echo "- CPU 或内存平均值、峰值偏高"
      echo "- 更像是推流编码、进程负载或机器资源不足"
      ;;
    "链路问题")
      echo "- 香港方向延迟或抖动偏高"
      echo "- 更像是前段链路质量波动"
      ;;
    "出口问题")
      echo "- 全球方向延迟、抖动或 HTTPS 出口异常"
      echo "- 更像是节点到目标平台方向不稳"
      ;;
    "平台/编码问题")
      echo "- 机器、链路、出口整体正常"
      echo "- 更像是平台侧波动、码率、分辨率或编码参数问题"
      ;;
    *)
      echo "- 当前未形成明确主因，建议结合日志继续观察"
      ;;
  esac
  echo

  say "建议"
  case "$top_reason" in
    "性能问题")
      echo "- 优先检查推流进程、编码参数、分辨率、帧率"
      echo "- 优先排查 VPS 规格是否偏低"
      ;;
    "链路问题")
      echo "- 优先排查接入链路质量、机房线路、跨区波动"
      ;;
    "出口问题")
      echo "- 优先排查节点到目标平台方向的出口质量"
      ;;
    "平台/编码问题")
      echo "- 优先检查直播分辨率、码率、帧率、编码模式"
      echo "- 若平台侧波动明显，可换时段复测"
      ;;
    *)
      echo "- 建议继续做轻量监控或下播后跑深度诊断"
      ;;
  esac
  echo

  ok "综合诊断（直播仿真）完成，日志已保存: $logfile"
  echo
}

watch_once() {
  local xray_state cpu mem conn_count https_ok
  local hk_stats gl_stats hk_avg hk_loss hk_jit gl_avg gl_loss gl_jit
  local verdict detail level

  xray_state="$(systemctl is-active xray 2>/dev/null || true)"
  cpu="$(cpu_usage)"
  mem="$(mem_usage)"
  conn_count="$(ss -ant 2>/dev/null | awk '/:443 / || /:443$/ {c++} END{print c+0}')"

  if curl -I -s --max-time 5 https://www.cloudflare.com >/dev/null 2>&1; then
    https_ok="OK"
  else
    https_ok="FAIL"
  fi

  hk_stats="$(ping_probe "$HK_TEST_TARGET" 2 "香港")"
  gl_stats="$(ping_probe "$GLOBAL_TEST_TARGET" 2 "全球")"

  IFS='|' read -r _ hk_avg hk_loss hk_jit <<< "$hk_stats"
  IFS='|' read -r _ gl_avg gl_loss gl_jit <<< "$gl_stats"

  level="稳定"
  verdict="直播正常"
  detail="链路活跃"

  if [[ "$xray_state" != "active" ]]; then
    level="异常"
    verdict="服务异常"
    detail="Xray 未运行"
  elif [[ "$https_ok" != "OK" ]]; then
    level="异常"
    verdict="出口异常"
    detail="HTTPS 不通"
  elif (( $(echo "$cpu >= 90 || $mem >= 90" | bc -l) )); then
    level="风险"
    verdict="资源异常"
    detail="CPU 或内存过高"
  elif (( conn_count < 1 )); then
    if (( $(echo "$hk_avg > 0 && $hk_avg < 80 && $gl_avg > 0 && $gl_avg < 150 && $hk_jit < 30 && $gl_jit < 40" | bc -l) )); then
      level="稳定"
      verdict="空闲"
      detail="未检测到明显推流连接"
    else
      level="轻微波动"
      verdict="空闲"
      detail="当前无推流，链路参考值有波动"
    fi
  else
    if (( $(echo "$hk_avg > 150 || $gl_avg > 220 || $hk_jit > 50 || $gl_jit > 70" | bc -l) )); then
      level="风险"
      verdict="直播正常"
      detail="链路活跃，但延迟或抖动偏高"
    elif (( $(echo "$hk_avg > 80 || $gl_avg > 150 || $hk_jit > 25 || $gl_jit > 35" | bc -l) )); then
      level="轻微波动"
      verdict="直播正常"
      detail="链路活跃，存在轻微波动"
    fi
  fi

  clear
  echo "=============================="
  echo "         CAST WATCH"
  echo "=============================="
  echo
  echo "时间: $(date '+%F %T')"
  echo
  echo "Xray: $xray_state"
  echo "CPU: ${cpu}%"
  echo "内存: ${mem}%"
  echo "443连接数: $conn_count"
  echo "HTTPS出口: $https_ok"
  echo
  echo "香港: ${hk_avg}ms / loss ${hk_loss}% / jitter ${hk_jit}ms"
  echo "全球: ${gl_avg}ms / loss ${gl_loss}% / jitter ${gl_jit}ms"
  echo
  echo "等级: $level"
  echo "状态: $verdict"
  echo "说明: $detail"
  echo
  echo "Ctrl+C 返回菜单，输入 q 后回车退出到命令行"
}

watch_loop() {
  install_deps
  check_runtime_ready || true

  local stop_flag=0
  local quit_flag=0
  local key=""

  trap 'stop_flag=1' INT

  while true; do
    [[ "$stop_flag" -eq 1 ]] && break

    watch_once

    key=""
    if read -r -t 5 key 2>/dev/null; then
      case "$key" in
        q|Q)
          quit_flag=1
          break
          ;;
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

main_menu() {
  show_header
  echo "1. 综合诊断（直播仿真，最推荐）"
  echo "2. 安全巡检（直播中可用）"
  echo "3. 轻量监控 60 秒"
  echo "4. 轻量监控 180 秒"
  echo "5. 深度诊断（建议下播后）"
  echo "6. 查看最近日志"
  echo "7. 实时监控"
  echo "0. 退出"
  echo "--------------------------------------"
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
    0) exit 0 ;;
    *) warn "无效选择" ;;
  esac
}

main() {
  install_deps
  check_runtime_ready || true

  case "${1:-menu}" in
    doctor|menu)
      while true; do
        main_menu
      done
      ;;
    safe)
      safe_inspect
      ;;
    sim)
      live_sim_diag
      ;;
    deep)
      deep_diag
      ;;
    monitor)
      light_monitor "${2:-60}" 5 8.8.8.8
      ;;
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
