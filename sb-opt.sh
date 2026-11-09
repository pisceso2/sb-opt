#!/usr/bin/env bash
# ============================================================================
# VERSION 1.0.0
#  sb-opt.sh  ——  sing-box / Xray 一体机 性能优化 · 体检 · 排障 工具
#
#  适用：Debian 11/12、Ubuntu 20.04+（内核 >= 4.9），root 运行
#  场景：香港 2C2G 小机 + sing-box 四合一（Reality / Hysteria2 / TUIC / Argo）
#
#  安全原则：
#    1) 改动配置前自动备份到 /root/sb-opt/backups/
#    2) 改动后执行 sing-box check 校验
#    3) 校验或重启失败 -> 自动回滚到上一份可用配置
#    4) 幂等：反复执行不会重复叠加
#
#  用法：bash sb-opt.sh                 交互菜单
#        bash sb-opt.sh audit           只体检（只读，不改任何东西）
#        bash sb-opt.sh sys             系统层优化（BBR/sysctl/swap/句柄）
#        bash sb-opt.sh tune            配置层调参（逐项确认）
#        bash sb-opt.sh dest            REALITY 伪装站选优
#        bash sb-opt.sh links           生成客户端链接
#        bash sb-opt.sh port <tag> <n>  改某个入站端口
#        bash sb-opt.sh disable <tag>   停用某个入站
#        bash sb-opt.sh enable <tag>    恢复某个入站
#        bash sb-opt.sh traffic         流量统计 + 每日配额提醒
#        bash sb-opt.sh rollback        回滚到最近一次备份
# ============================================================================

set -uo pipefail

BASE="/root/sb-opt"
BK="$BASE/backups"
DIS="$BASE/disabled"
LOGF="$BASE/sb-opt.log"
SYSCTL_FILE="/etc/sysctl.d/99-sb-opt.conf"
REPO_RAW="https://raw.githubusercontent.com/pisceso2/sb-opt/main"
CFG=""
SVC=""

c_0=$'\e[0m'; c_r=$'\e[31m'; c_g=$'\e[32m'; c_y=$'\e[33m'; c_b=$'\e[36m'; c_d=$'\e[90m'

say()  { printf '%s>>>%s %s\n' "$c_b" "$c_0" "$*"; }
ok()   { printf '  %s OK %s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '  %s !! %s %s\n' "$c_y" "$c_0" "$*"; }
err()  { printf '  %s XX %s %s\n' "$c_r" "$c_0" "$*"; }
dim()  { printf '       %s%s%s\n' "$c_d" "$*" "$c_0"; }
hr()   { printf '%s\n' "------------------------------------------------------------------"; }
log()  { mkdir -p "$BASE"; printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOGF"; }

need_root() {
  [ "$(id -u)" = 0 ] || { err "必须用 root 运行：sudo bash $0"; exit 1; }
}

ask() {
  local a
  read -rp "  ?  $1 [y/N] " a </dev/tty || return 1
  [[ $a =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------- 环境探测 --
detect_cfg() {
  local p
  for p in /etc/sing-box/config.json /usr/local/etc/sing-box/config.json \
           /opt/sing-box/config.json /root/sing-box/config.json \
           /etc/xray/config.json /usr/local/etc/xray/config.json; do
    [ -f "$p" ] && { CFG="$p"; return 0; }
  done
  if command -v systemctl >/dev/null 2>&1; then
    p=$(systemctl cat sing-box 2>/dev/null | grep -oE '/[^ "]+config\.json' | head -1)
    [ -n "${p:-}" ] && [ -f "$p" ] && { CFG="$p"; return 0; }
  fi
  return 1
}

detect_svc() {
  local s
  for s in sing-box singbox sing-box-server xray; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${s}\.service"; then
      SVC="$s"; return 0
    fi
  done
  return 1
}

req_pkg() {
  local miss=()
  for b in "$@"; do command -v "$b" >/dev/null 2>&1 || miss+=("$b"); done
  [ ${#miss[@]} -eq 0 ] && return 0
  say "安装依赖：${miss[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq "${miss[@]}" >/dev/null 2>&1
  for b in "${miss[@]}"; do
    command -v "$b" >/dev/null 2>&1 && ok "$b 已安装" || err "$b 安装失败"
  done
}

kernel_ok() {
  local cur
  cur=$(uname -r | grep -oE '^[0-9]+\.[0-9]+')
  [ "$(printf '%s\n4.9\n' "$cur" | sort -V | head -1)" = "4.9" ]
}

# ------------------------------------------------------- 备份 / 校验 / 回滚 --
backup_cfg() {
  [ -f "$CFG" ] || return 0
  mkdir -p "$BK"
  local f="$BK/$(date +%Y%m%d-%H%M%S)-${1// /_}.json"
  cp -a "$CFG" "$f"
  dim "已备份 -> $f"
  # 只保留最近 15 份
  ls -1t "$BK"/*.json 2>/dev/null | tail -n +16 | xargs -r rm -f
}

check_cfg_file() {   # $1=配置文件路径；返回 0=通过
  local f="$1" out
  command -v sing-box >/dev/null 2>&1 || return 0     # 没装 sing-box 就跳过
  out=$(sing-box check -c "$f" 2>&1) && return 0
  grep -qi 'unknown command\|unknown flag' <<<"$out" && return 0   # 老版本无 check
  printf '%s\n' "$out" | sed 's/^/       /' >&2
  return 1
}

restart_svc() {
  [ -n "$SVC" ] || return 1
  systemctl restart "$SVC" >/dev/null 2>&1
  sleep 2
  systemctl is-active --quiet "$SVC"
}

rollback_latest() {
  local f
  f=$(ls -1t "$BK"/*.json 2>/dev/null | head -1)
  [ -n "${f:-}" ] || { err "没有可用备份"; return 1; }
  cp -a "$f" "$CFG"
  restart_svc && ok "已回滚到 $(basename "$f")" || err "回滚后服务仍无法启动，请手工检查"
  log "rollback to $f"
}

# 用法：apply_cfg "说明" [jq选项 ...] "jq表达式"
#   注意：jq 要求选项写在表达式之前，否则会被当成文件名
apply_cfg() {
  local desc="$1"; shift
  local tmp rc
  tmp=$(mktemp "/tmp/sbcfg.XXXXXX.json")
  if ! jq "$@" "$CFG" >"$tmp" 2>"$BASE/jq.err"; then
    err "$desc：jq 处理失败"; sed 's/^/       /' "$BASE/jq.err" >&2; rm -f "$tmp"; return 1
  fi
  if ! check_cfg_file "$tmp"; then
    err "$desc：新配置未通过校验，已放弃本次修改"
    cp "$tmp" "$BASE/last-failed.json" 2>/dev/null
    rm -f "$tmp"; return 1
  fi
  backup_cfg "$desc"
  install -m 600 "$tmp" "$CFG"
  rm -f "$tmp"
  if restart_svc; then
    ok "$desc —— 已生效"
    log "applied: $desc"
    return 0
  fi
  err "$desc：重启失败，正在回滚"
  rollback_latest
  return 1
}

inbound_count() { jq '.inbounds | length' "$CFG" 2>/dev/null || echo 0; }

# ------------------------------------------------------------ 1. 体检 ------
cmd_audit() {
  hr; say "环境体检"; hr

  printf '  系统    : %s\n' "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  printf '  内核    : %s' "$(uname -r)"
  if kernel_ok; then printf '  %s(>=4.9 可开 BBR)%s\n' "$c_g" "$c_0"
  else printf '  %s(<4.9，BBR 不可用，建议重装 Debian 12)%s\n' "$c_r" "$c_0"; fi
  printf '  架构    : %s\n' "$(uname -m)"

  local mem_total mem_used
  mem_total=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo)
  mem_used=$(awk '/MemAvailable/{printf "%.0f", ('"$mem_total"'*1024-$2)/1024}' /proc/meminfo)
  printf '  内存    : %sMB 总 / 约 %sMB 已用\n' "$mem_total" "$mem_used"
  printf '  Swap    : %s\n' "$(swapon --show --noheadings 2>/dev/null | awk '{print $3}' | head -1)"

  printf '  拥塞控制: %s' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] \
    && printf '  %s✓%s\n' "$c_g" "$c_0" || printf '  %s✗ 未开启（跑 sys 修复）%s\n' "$c_y" "$c_0"
  printf '  qdisc   : %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  printf '  文件句柄: %s\n' "$(ulimit -n)"

  hr
  if ! detect_cfg; then
    err "未找到 sing-box / xray 配置文件"
    dim "常见路径：/etc/sing-box/config.json  /usr/local/etc/sing-box/config.json"
    return 0
  fi
  detect_svc
  ok "配置文件: $CFG"
  printf '  服务    : %s  %s\n' "${SVC:-未找到}" "$(systemctl is-active "$SVC" 2>/dev/null)"
  printf '  版本    : %s\n' "$(sing-box version 2>/dev/null | head -1)"

  command -v jq >/dev/null 2>&1 || { warn "缺少 jq，无法解析配置（跑 sys 会自动安装）"; return 0; }

  if ! jq -e '.inbounds' "$CFG" >/dev/null 2>&1; then
    warn "配置结构不是标准 .inbounds 数组，跳过深层分析"
    return 0
  fi

  hr; say "入站清单"; hr
  printf '  %-14s %-12s %-7s %-6s %s\n' "TAG" "类型" "端口" "监听" "备注"
  printf '  %s\n' "$(printf '%.0s-' {1..62})"
  local n i type tag port listen note
  n=$(inbound_count)
  for ((i=0; i<n; i++)); do
    tag=$(jq -r ".inbounds[$i].tag // \"-\"" "$CFG")
    type=$(jq -r ".inbounds[$i].type // \"-\"" "$CFG")
    port=$(jq -r ".inbounds[$i].listen_port // \"-\"" "$CFG")
    listen=$(jq -r ".inbounds[$i].listen // \"-\"" "$CFG")
    case "$type" in
      vless)     note="REALITY/Vision，TCP 主力" ;;
      hysteria2) note="QUIC 抗丢包，最费流量" ;;
      tuic)      note="QUIC，与 hy2 二选一" ;;
      vmess|trojan) note="常规代理" ;;
      *)         note="" ;;
    esac
    printf '  %-14s %-12s %-7s %-6s %s\n' "$tag" "$type" "$port" "$listen" "$note"
  done

  [ "$n" -gt 2 ] && { hr; warn "当前有 $n 个入站，建议只保留 2 个（REALITY + Hysteria2）"; \
                      dim "多开不提升速度，只增加暴露面、CPU 与排查难度"; }

  hr; say "端口监听"; hr
  ss -lntup 2>/dev/null | grep -E 'sing-box|xray' | awk '{print "  "$1"  "$5"  "$7}' || echo "  （无）"

  hr; say "防火墙"; hr
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw status numbered 2>/dev/null | sed 's/^/  /'
  else
    dim "ufw 未启用 —— 请确认云控制台安全组已放行对应端口"
  fi

  if command -v vnstat >/dev/null 2>&1; then
    hr; say "本月流量"; hr
    vnstat -m 2>/dev/null | tail -6 | sed 's/^/  /'
  fi

  hr; say "初步结论"; hr
  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  [ "$cc" != "bbr" ] && dim "· 拥塞控制不是 BBR，晚高峰吞吐会明显吃亏 -> 执行 sys"
  [ "$n" -gt 2 ] && dim "· 入站过多 -> 执行 disable <tag> 精简"
  jq -e '[.inbounds[]|select(.type=="vless" and .tls.reality.enabled==true and (.tls.utls.fingerprint//"")!="chrome")]|length>0' \
    "$CFG" >/dev/null 2>&1 && dim "· REALITY 未设 utls=chrome -> 执行 tune"
  jq -e '[.inbounds[]|select(.type=="hysteria2")]|length>0' "$CFG" >/dev/null 2>&1 \
    && jq -e '[.inbounds[]|select(.type=="hysteria2" and (.obfs.type//"")=="")]|length>0' "$CFG" >/dev/null 2>&1 \
    && dim "· Hysteria2 未加 obfs，UDP 易被 QoS -> 执行 tune"
  echo
}

# ------------------------------------------------------- 2. 系统层优化 ------
cmd_sys() {
  hr; say "系统层优化（BBR / sysctl / swap / 句柄）"; hr

  if ! kernel_ok; then
    err "内核 $(uname -r) 低于 4.9，无法启用 BBR"
    dim "建议在商家中控台重装 Debian 12 后重跑本脚本"
    return 1
  fi

  modprobe tcp_bbr 2>/dev/null || true
  printf 'tcp_bbr\n' > /etc/modules-load.d/sb-bbr.conf

  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    err "内核未提供 tcp_bbr 模块"; return 1
  fi

  say "写入 $SYSCTL_FILE"
  cat >"$SYSCTL_FILE" <<'EOF'
# ---- sb-opt.sh : 200Mbps / 50ms 档位调优 ----
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608
net.ipv4.tcp_mem = 786432 1048576 1572864

net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1

fs.file-max = 1048576
fs.inotify.max_user_instances = 8192
EOF

  sysctl --system >/dev/null 2>&1
  local cc qd
  cc=$(sysctl -n net.ipv4.tcp_congestion_control)
  qd=$(sysctl -n net.core.default_qdisc)
  [ "$cc" = "bbr" ] && ok "拥塞控制 = bbr" || err "拥塞控制 = $cc（未生效）"
  [ "$qd" = "fq" ]  && ok "队列算法 = fq"   || warn "队列算法 = $qd"

  # ---- swap（2G 小机防 OOM，不拖慢吞吐） ----
  if ! swapon --show 2>/dev/null | grep -q .; then
    say "创建 1G swap"
    if fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none; then
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null 2>&1
      swapon /swapfile 2>/dev/null
      grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
      printf 'vm.swappiness = 10\n' >/etc/sysctl.d/99-sb-swap.conf
      sysctl --system >/dev/null 2>&1
      ok "swap 1G 已启用（swappiness=10）"
    else
      warn "swap 创建失败，可忽略"
    fi
  else
    ok "swap 已存在，跳过"
  fi

  # ---- 时间同步（TLS/REALITY 握手依赖） ----
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true 2>/dev/null || true
    if timedatectl status 2>/dev/null | grep -qi 'synchronized: yes'; then
      ok "系统时间已同步"
    else
      warn "时间未同步 —— 建议 apt install -y systemd-timesyncd && systemctl enable --now systemd-timesyncd"
    fi
  fi

  # ---- 提升 sing-box 文件句柄上限 ----
  if detect_svc; then
    mkdir -p "/etc/systemd/system/${SVC}.service.d"
    cat >"/etc/systemd/system/${SVC}.service.d/limits.conf" <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
    systemctl daemon-reload
    systemctl restart "$SVC" >/dev/null 2>&1 || true
    ok "${SVC} 句柄上限 -> 1048576（已重启服务）"
  fi

  hr; ok "系统层优化完成"; dim "日志：$LOGF"
  echo
}

# ------------------------------------------------------- 3. 配置层调参 ------
cmd_tune() {
  hr; say "配置层调参"; hr
  detect_cfg || { err "未找到配置文件"; return 1; }
  detect_svc
  req_pkg jq
  jq -e '.inbounds' "$CFG" >/dev/null 2>&1 || { err "配置不是标准 .inbounds 结构，跳过"; return 1; }

  local n i type tag changed=0
  n=$(inbound_count)

  # ---------- REALITY: 补 utls chrome ----------
  for ((i=0; i<n; i++)); do
    type=$(jq -r ".inbounds[$i].type // empty" "$CFG")
    [ "$type" = "vless" ] || continue
    jq -e ".inbounds[$i].tls.reality.enabled == true" "$CFG" >/dev/null 2>&1 || continue

    tag=$(jq -r ".inbounds[$i].tag // \"inbound-$i\"" "$CFG")
    local fp hs
    fp=$(jq -r ".inbounds[$i].tls.utls.fingerprint // \"\"" "$CFG")
    hs=$(jq -r ".inbounds[$i].tls.reality.handshake.server // .inbounds[$i].tls.server_name // \"-\"" "$CFG")

    hr; printf '  REALITY 入站 [%s]\n' "$tag"
    printf '    伪装站 : %s\n' "$hs"
    printf '    指纹   : %s\n' "${fp:-（未设置）}"

    if [ "$fp" != "chrome" ]; then
      if ask "把 utls 指纹设为 chrome？（更像真实浏览器，抗识别）"; then
        apply_cfg "REALITY[$tag] utls=chrome" \
          ".inbounds[$i].tls.utls = {\"enabled\": true, \"fingerprint\": \"chrome\"}" && changed=1
      fi
    else
      ok "指纹已是 chrome"
    fi
  done

  # ---------- Hysteria2: obfs + 带宽 ----------
  for ((i=0; i<n; i++)); do
    type=$(jq -r ".inbounds[$i].type // empty" "$CFG")
    [ "$type" = "hysteria2" ] || continue
    tag=$(jq -r ".inbounds[$i].tag // \"inbound-$i\"" "$CFG")
    local port obfs up down
    port=$(jq -r ".inbounds[$i].listen_port // \"-\"" "$CFG")
    obfs=$(jq -r ".inbounds[$i].obfs.type // \"\"" "$CFG")
    up=$(jq -r ".inbounds[$i].up_mbps // \"未设\"" "$CFG")
    down=$(jq -r ".inbounds[$i].down_mbps // \"未设\"" "$CFG")

    hr; printf '  Hysteria2 入站 [%s]\n' "$tag"
    printf '    端口   : %s' "$port"
    [ "$port" = "443" ] && printf '  %s(建议挪走：UDP/443 最易被 QoS)%s' "$c_y" "$c_0"
    printf '\n    混淆   : %s\n' "${obfs:-（未设置）}"
    printf '    带宽   : 上行 %s / 下行 %s Mbps（Brutal 上限）\n' "$up" "$down"
    printf '    流量   : 按此速率满跑约 %s GB/小时\n' \
      "$(awk -v d="${down/未设/160}" 'BEGIN{printf "%.0f", (d>0?d:160)*3600/8/1024}')"

    if [ -z "$obfs" ]; then
      if ask "为 Hysteria2 启用 salamander 混淆？（打散 UDP 特征，绕 QoS）"; then
        local pw
        pw=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
        apply_cfg "HY2[$tag] 启用 obfs" \
          ".inbounds[$i].obfs = {\"type\":\"salamander\",\"password\":\"$pw\"}" \
          && { ok "混淆密码：$pw"; dim "客户端需同步填写 obfs-password"; changed=1; }
      fi
    fi

    if [ "$port" = "443" ]; then
      if ask "把 Hysteria2 端口从 443 改到 24443？"; then
        apply_cfg "HY2[$tag] 端口 443->24443" ".inbounds[$i].listen_port = 24443" \
          && { command -v ufw >/dev/null 2>&1 && ufw allow 24443/udp >/dev/null 2>&1
               ok "别忘了云控制台安全组也放行 24443/udp"
               changed=1; }
      fi
    fi
  done

  # ---------- 多入站提示 ----------
  if [ "$(inbound_count)" -gt 2 ]; then
    hr; warn "建议精简入站（当前 $(inbound_count) 个）"
    jq -r '.inbounds[] | "       \(.tag // "-")  (\(.type)  \(.listen_port // "-"))"' "$CFG"
    dim "用法：bash $0 disable <tag>"
  fi

  [ "$changed" = 0 ] && dim "本次未做任何修改"
  echo
}

# ------------------------------------------- 4. REALITY 伪装站测速选优 ------
cmd_dest() {
  hr; say "REALITY 伪装站候选测速"; hr
  req_pkg curl
  local hosts=(www.microsoft.com www.apple.com swcdn.apple.com
               www.cloudflare.com www.bing.com www.tesla.com
               one.one.one.one dl.google.com)
  printf '  %-24s %-10s %-10s %s\n' "站点" "TCP连接" "TLS握手" "HTTP版本"
  printf '  %s\n' "$(printf '%.0s-' {1..58})"
  local h t c a hv
  for h in "${hosts[@]}"; do
    read -r c a hv < <(
      curl -sI -o /dev/null --max-time 6 --tlsv1.3 \
           -w '%{time_connect} %{time_appconnect} %{http_version}' "https://$h" 2>/dev/null
      echo
    )
    [ -z "${c:-}" ] && { printf '  %-24s %s\n' "$h" "不可用"; continue; }
    printf '  %-24s %-10s %-10s %s\n' "$h" "${c}s" "${a}s" "${hv:-?}"
  done
  hr
  dim "选 TCP 连接最低、HTTP 为 2、且不在 GFW 名单的站点填入 reality.handshake.server"
  echo
}

# ------------------------------------------------- 5. 生成客户端链接 --------
pubkey_from_priv() {   # $1=base64url 私钥 -> 输出 base64url 公钥
  local p="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$p" <<'PY' 2>/dev/null
import sys, base64
try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from cryptography.hazmat.primitives import serialization as s
except Exception:
    sys.exit(1)
k = sys.argv[1]
raw = base64.urlsafe_b64decode(k + "=" * (-len(k) % 4))
p = X25519PrivateKey.from_private_bytes(raw).public_key()
print(base64.urlsafe_b64encode(
    p.public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)).decode().rstrip("="))
PY
}

cmd_links() {
  hr; say "生成客户端链接"; hr
  detect_cfg || { err "未找到配置文件"; return 1; }
  req_pkg jq

  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  [ -n "${ip:-}" ] || ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null)
  [ -n "${ip:-}" ] || { err "无法获取公网 IP"; return 1; }
  ok "服务器 IP：$ip"

  local n i type tag port
  n=$(inbound_count)
  for ((i=0; i<n; i++)); do
    type=$(jq -r ".inbounds[$i].type // empty" "$CFG")
    tag=$(jq -r ".inbounds[$i].tag // \"node-$i\"" "$CFG")
    port=$(jq -r ".inbounds[$i].listen_port // empty" "$CFG")
    [ -n "$port" ] || continue

    case "$type" in
      vless)
        jq -e ".inbounds[$i].tls.reality.enabled == true" "$CFG" >/dev/null 2>&1 || continue
        local uuid sni sid priv pub flow
        uuid=$(jq -r ".inbounds[$i].users[0].uuid // empty" "$CFG")
        sni=$(jq -r ".inbounds[$i].tls.server_name // empty" "$CFG")
        sid=$(jq -r ".inbounds[$i].tls.reality.short_id[0] // empty" "$CFG")
        priv=$(jq -r ".inbounds[$i].tls.reality.private_key // empty" "$CFG")
        flow=$(jq -r ".inbounds[$i].users[0].flow // \"xtls-rprx-vision\"" "$CFG")
        pub=$(pubkey_from_priv "$priv" 2>/dev/null || true)
        if [ -z "${pub:-}" ]; then
          warn "无法自动推导 REALITY 公钥，请手动填入 pbk（或用 sing-box generate reality-keypair 重新配对）"
          pub="<公钥>"
        fi
        hr; printf '  [%s] VLESS-REALITY\n' "$tag"
        printf '  vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s-REALITY\n' \
          "$uuid" "$ip" "$port" "$flow" "$sni" "$pub" "$sid" "$tag"
        ;;
      hysteria2)
        local pw sni2 obfst obfsp
        pw=$(jq -r ".inbounds[$i].users[0].password // empty" "$CFG")
        sni2=$(jq -r ".inbounds[$i].tls.server_name // empty" "$CFG")
        obfst=$(jq -r ".inbounds[$i].obfs.type // empty" "$CFG")
        obfsp=$(jq -r ".inbounds[$i].obfs.password // empty" "$CFG")
        local extra=""
        [ -n "$obfst" ] && extra="&obfs=${obfst}&obfs-password=${obfsp}"
        hr; printf '  [%s] Hysteria2\n' "$tag"
        printf '  hysteria2://%s@%s:%s?sni=%s&insecure=1%s#%s-HY2\n' \
          "$pw" "$ip" "$port" "$sni2" "$extra" "$tag"
        dim "自签证书用 insecure=1；正式证书请删掉该参数"
        ;;
    esac
  done
  hr
  dim "复制上面链接，v2rayN -> 服务器 -> 从剪贴板导入"
  echo
}

# --------------------------------------------------- 6. 端口 / 启停入站 -----
cmd_port() {
  local tag="${1:-}" port="${2:-}"
  [ -n "$tag" ] && [ -n "$port" ] || { err "用法：bash $0 port <tag> <端口>"; return 1; }
  detect_cfg || { err "未找到配置文件"; return 1; }
  jq -e --arg t "$tag" '[.inbounds[]|select(.tag==$t)]|length>0' "$CFG" >/dev/null 2>&1 \
    || { err "没有 tag 为 $tag 的入站"; return 1; }

  local type
  type=$(jq -r --arg t "$tag" '.inbounds[]|select(.tag==$t)|.type' "$CFG")
  apply_cfg "$tag 端口 -> $port" \
    --arg t "$tag" --arg p "$port" \
    '(.inbounds[] | select(.tag==$t) | .listen_port) |= ($p|tonumber)' || return 1

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    case "$type" in
      hysteria2|tuic) ufw allow "$port"/udp >/dev/null 2>&1 ;;
      *)              ufw allow "$port"/tcp >/dev/null 2>&1 ;;
    esac
    ok "ufw 已放行 $port"
  fi
  warn "同步更新客户端链接与云控制台安全组"
}

cmd_disable() {
  local tag="${1:-}"
  [ -n "$tag" ] || { err "用法：bash $0 disable <tag>"; return 1; }
  detect_cfg || { err "未找到配置文件"; return 1; }
  local cnt
  cnt=$(jq -r --arg t "$tag" '[.inbounds[]|select(.tag==$t)]|length' "$CFG")
  [ "$cnt" -gt 0 ] || { err "没有 tag 为 $tag 的入站"; return 1; }

  mkdir -p "$DIS"
  jq --arg t "$tag" '.inbounds[]|select(.tag==$t)' "$CFG" >"$DIS/$tag.json"
  apply_cfg "停用入站 [$tag]" --arg t "$tag" '.inbounds |= map(select(.tag != $t))' \
    && ok "入站定义已存入 $DIS/$tag.json（可用 enable 恢复）"
}

cmd_enable() {
  local tag="${1:-}"
  [ -n "$tag" ] || { err "用法：bash $0 enable <tag>"; return 1; }
  [ -f "$DIS/$tag.json" ] || { err "找不到已停用的 [$tag]"; return 1; }
  detect_cfg || { err "未找到配置文件"; return 1; }
  apply_cfg "恢复入站 [$tag]" --slurpfile n "$DIS/$tag.json" '.inbounds += $n' \
    && rm -f "$DIS/$tag.json"
}

# ------------------------------------------------------- 7. 流量守护 --------
cmd_traffic() {
  hr; say "流量统计与配额提醒"; hr
  req_pkg vnstat
  systemctl enable --now vnstat >/dev/null 2>&1

  cat >/etc/cron.daily/sb-traffic <<'EOF'
#!/usr/bin/env bash
# 每日流量播报：600GB/月 配额，均摊 20GB/天
LOG=/var/log/sb-traffic.log
TODAY=$(vnstat -d --json 2>/dev/null | tr -d ' \n' | grep -oE '"total"[^}]*' | head -1 | grep -oE '"bytes":[0-9]+' | grep -oE '[0-9]+')
[ -z "$TODAY" ] && exit 0
GB=$(awk -v b="$TODAY" 'BEGIN{printf "%.2f", b/1024/1024/1024}')
echo "$(date '+%F %T') 今日 ${GB} GB" >>"$LOG"
if awk -v g="$GB" 'BEGIN{exit !(g>15)}'; then
  echo "$(date '+%F %T') 警告：今日已超 15GB，月配额 600GB" >>"$LOG"
fi
EOF
  chmod +x /etc/cron.daily/sb-traffic
  ok "每日流量记录已启用 -> /var/log/sb-traffic.log"
  hr
  vnstat -m 2>/dev/null | tail -8 | sed 's/^/  /'
  dim "月配额 600GB ≈ 20GB/天；4K 视频约 7GB/小时，HY2 满速约 90GB/小时"
  echo
}

# ------------------------------------------------------------ 8. 回滚 ------
cmd_rollback() {
  hr; say "可用备份"; hr
  ls -1t "$BK"/*.json 2>/dev/null | head -10 | nl -w2 -s'. ' | sed 's/^/  /' || {
    err "没有备份"; return 1; }
  echo
  local f
  f=$(ls -1t "$BK"/*.json 2>/dev/null | head -1)
  [ -n "${f:-}" ] || return 1
  ask "回滚到 $(basename "$f") ?" || return 0
  cp -a "$f" "$CFG"
  restart_svc && ok "已回滚并重启" || err "重启失败，请手工检查 $CFG"
}

# ------------------------------------------------------------ 9. 自更新 -----
self_version() { grep -m1 '^# VERSION' "$1" 2>/dev/null | awk '{print $3}'; }

cmd_update() {
  hr; say "从 GitHub 拉取最新版本"; hr
  command -v curl >/dev/null 2>&1 || req_pkg curl
  local self tmp old new
  self=$(readlink -f "$0" 2>/dev/null || echo "$0")
  tmp=$(mktemp /tmp/sbopt.XXXXXX)

  if ! curl -fsSL --max-time 30 "$REPO_RAW/sb-opt.sh" -o "$tmp"; then
    err "下载失败，请检查网络或仓库是否公开"
    rm -f "$tmp"; return 1
  fi
  if ! bash -n "$tmp" 2>/dev/null; then
    err "下载的版本语法校验失败，已放弃（可能是半截文件）"
    rm -f "$tmp"; return 1
  fi

  old=$(self_version "$self"); new=$(self_version "$tmp")
  printf '  当前版本 : %s\n  远端版本 : %s\n' "${old:-?}" "${new:-?}"
  if [ "$old" = "$new" ]; then
    ok "已是最新，无需更新"; rm -f "$tmp"; return 0
  fi
  cp -a "$self" "$BASE/sb-opt.sh.old"
  install -m 755 "$tmp" "$self"
  rm -f "$tmp"
  ok "已更新 ${old:-?} -> ${new:-?}"
  dim "旧版备份：$BASE/sb-opt.sh.old"
  echo
}

# ------------------------------------------------------------ 菜单 --------
menu() {
  while :; do
    clear 2>/dev/null || true
    cat <<EOF
${c_b}
  ============================================================
    sing-box 一体机优化工具   $(date '+%F %T')
  ============================================================${c_0}
    1) 体检          查看现状、入站清单、端口、流量（只读）
    2) 系统优化      BBR + sysctl + swap + 句柄（收益最大）
    3) 配置调参      REALITY 指纹 / HY2 混淆与端口（逐项确认）
    4) 伪装站测速    给 REALITY 挑最快的 handshake 站
    5) 生成链接      输出 vless:// 与 hysteria2:// 供客户端导入
    6) 流量守护      vnstat + 每日 20GB 提醒
    7) 回滚          恢复最近一次备份
    8) 更新          从 GitHub 拉取最新版脚本
    0) 退出
${c_d}
  提示：先跑 1 看现状，再跑 2，最后按需跑 3/5
${c_0}
EOF
    local c
    read -rp "  选择: " c </dev/tty || exit 0
    case "$c" in
      1) cmd_audit ;;
      2) cmd_sys ;;
      3) cmd_tune ;;
      4) cmd_dest ;;
      5) cmd_links ;;
      6) cmd_traffic ;;
      7) cmd_rollback ;;
      8) cmd_update ;;
      0|q) exit 0 ;;
      *) ;;
    esac
    echo; read -rp "  回车继续..." _ </dev/tty || exit 0
  done
}

# ------------------------------------------------------------ 入口 --------
need_root
mkdir -p "$BASE"
case "${1:-}" in
  audit)    cmd_audit ;;
  sys)      cmd_sys ;;
  tune)     cmd_tune ;;
  dest)     cmd_dest ;;
  links)    cmd_links ;;
  traffic)  cmd_traffic ;;
  port)     shift; cmd_port "${1:-}" "${2:-}" ;;
  disable)  shift; cmd_disable "${1:-}" ;;
  enable)   shift; cmd_enable "${1:-}" ;;
  rollback) cmd_rollback ;;
  update)   cmd_update ;;
  version|-v) self_version "${BASH_SOURCE[0]}" ;;
  menu|"")  menu ;;
  *)        sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
