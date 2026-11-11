#!/usr/bin/env bash
# ============================================================================
# VERSION 1.0.0
#  sbopt-restore.sh —— 把 sb-opt 做过的改动全部还原到初始状态
#
#  还原内容（默认）：
#    1) 被 disable 的入站           ← 从 /root/sb-opt/backups 最早一份还原
#    2) Hysteria2 的 obfs 混淆       ← 同上
#    3) JSONC 规范化丢失的注释       ← 同上（备份是原始 JSONC 文件）
#
#  可选（--sys）：
#    4) sysctl 文件 / tc 队列 / swap / systemd 句柄 drop-in
#
#  安全机制：
#    · 撤销前先把当前状态快照到 /root/sb-opt/restore-snapshot/<时间戳>/
#    · 还原后先在临时目录做 sing-box check -C，通过才落盘
#    · 落盘后重启失败 -> 自动用快照回滚到「撤销前」
#    · 全程写日志 /root/sb-opt/restore.log
#
#  用法：
#    bash sbopt-restore.sh              交互确认后还原配置
#    bash sbopt-restore.sh --yes        跳过确认
#    bash sbopt-restore.sh --dry-run    只列出计划，不动任何文件
#    bash sbopt-restore.sh --sys        同时还原系统层（sysctl/tc/swap/句柄）
#    bash sbopt-restore.sh --list       只看备份里有哪些原始文件
# ============================================================================

set -uo pipefail

BASE="/root/sb-opt"
BK="$BASE/backups"
DIS="$BASE/disabled"
LOGF="$BASE/restore.log"
SNAP_ROOT="$BASE/restore-snapshot"

CFG=""
SVC=""
SB_BIN=""
ASSUME_YES=0
DRY_RUN=0
DO_SYS=0

c_0=$'\e[0m'; c_r=$'\e[31m'; c_g=$'\e[32m'; c_y=$'\e[33m'; c_b=$'\e[36m'; c_d=$'\e[90m'
say()  { printf '%s>>>%s %s\n' "$c_b" "$c_0" "$*"; }
ok()   { printf '  %s OK %s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '  %s !! %s %s\n' "$c_y" "$c_0" "$*"; }
err()  { printf '  %s XX %s %s\n' "$c_r" "$c_0" "$*"; }
dim()  { printf '       %s%s%s\n' "$c_d" "$*" "$c_0"; }
hr()   { printf '%s\n' "------------------------------------------------------------------"; }
log()  { mkdir -p "$BASE"; printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOGF"; }

usage() {
  cat <<'EOF'
sbopt-restore.sh —— 还原 sb-opt 的全部改动

  bash sbopt-restore.sh              还原配置（交互确认）
  bash sbopt-restore.sh --yes        还原配置，跳过确认
  bash sbopt-restore.sh --dry-run    只列计划，不动文件
  bash sbopt-restore.sh --sys        同时还原系统层（sysctl/tc/swap/句柄）
  bash sbopt-restore.sh --list       列出备份里的原始文件
EOF
  exit 0
}

need_root() { [ "$(id -u)" = 0 ] || { err "必须用 root 运行：sudo bash $0"; exit 1; }; }

ask() {
  local a
  [ "$ASSUME_YES" = 1 ] && return 0
  read -rp "  ?  $1 [y/N] " a </dev/tty || return 1
  [[ $a =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------- 环境探测 --
detect_cfg() {
  local p pid dir
  [ -n "$CFG" ] && { [ -d "$CFG" ] || [ -f "$CFG" ]; } && return 0
  for p in /etc/sing-box/conf /usr/local/etc/sing-box/conf /etc/sing-box; do
    [ -d "$p" ] && { CFG="$p"; return 0; }
  done
  for pid in $(pgrep -f '[s]ing-box' 2>/dev/null); do
    dir=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null |
          tr ' ' '\n' | awk 'p{print;exit} /^-C$/{p=1}')
    [ -n "${dir:-}" ] && [ -d "$dir" ] && { CFG="$dir"; return 0; }
  done
  for p in /etc/sing-box/config.json /usr/local/etc/sing-box/config.json; do
    [ -f "$p" ] && { CFG="$p"; return 0; }
  done
  return 1
}

detect_svc() {
  command -v systemctl >/dev/null 2>&1 || return 1
  local u
  for u in sing-box singbox sing-box-server xray; do
    systemctl cat "${u}.service" >/dev/null 2>&1 && { SVC="$u"; return 0; }
  done
  return 1
}

detect_bin() {
  local pid exe p
  for pid in $(pgrep -f '[s]ing-box|[x]ray' 2>/dev/null); do
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null); exe=${exe% (deleted)}
    case "$(basename "${exe:-}")" in
      sing-box|xray) [ -x "$exe" ] && { SB_BIN="$exe"; return 0; } ;;
    esac
  done
  for p in sing-box /etc/sing-box/sing-box /usr/local/bin/sing-box /usr/bin/sing-box xray; do
    case "$p" in
      /*) [ -x "$p" ] && { SB_BIN="$p"; return 0; } ;;
      *)  command -v "$p" >/dev/null 2>&1 && { SB_BIN=$(command -v "$p"); return 0; } ;;
    esac
  done
  return 1
}

# --------------------------------------------------- 找出「每个文件最早备份」 --
# 备份命名：<YYYYMMDD-HHMMSS>-<原名>，时间戳前缀 16 字符
declare -A ORIG=()
declare -a ORIG_BASE=()

scan_backups() {
  ORIG=(); ORIG_BASE=()
  [ -d "$BK" ] || { err "备份目录不存在：$BK"; return 1; }
  local f name base
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    [ "${#name}" -gt 16 ] || continue
    case "$name" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*) ;; *) continue ;; esac
    base=${name:16}
    [ -n "${ORIG[$base]:-}" ] && continue          # sort 保证先到的最早
    ORIG[$base]="$f"
    ORIG_BASE+=("$base")
  done < <(printf '%s\n' "$BK"/* 2>/dev/null | sort)
  [ ${#ORIG_BASE[@]} -gt 0 ]
}

cmd_list() {
  hr; say "备份中的原始文件"; hr
  scan_backups || return 1
  printf '  %-42s %s\n' "原始文件名" "最早备份时间"
  printf '  %s\n' "$(printf '%.0s-' {1..66})"
  local b
  for b in "${ORIG_BASE[@]}"; do
    printf '  %-42s %s\n' "$b" "$(basename "${ORIG[$b]}" | cut -c1-15 |
      sed -E 's/^([0-9]{8})-([0-9]{2})([0-9]{2})([0-9]{2})/\1 \2:\3:\4/')"
  done
  echo
  dim "共 ${#ORIG_BASE[@]} 个文件可还原"
}

# ------------------------------------------------------------- 校验与重启 ---
check_cfg_dir() {   # $1=目录或文件
  [ -n "$SB_BIN" ] || return 0
  local p="$1" out
  if [ -d "$p" ]; then
    out=$("$SB_BIN" check -C "$p" 2>&1) || { printf '%s\n' "$out" | sed 's/^/       /' >&2; return 1; }
  else
    out=$("$SB_BIN" check -c "$p" 2>&1) || { printf '%s\n' "$out" | sed 's/^/       /' >&2; return 1; }
  fi
  return 0
}

restart_svc() {
  [ -n "$SVC" ] || return 1
  command -v systemctl >/dev/null 2>&1 || { err "没有 systemctl，无法重启服务"; return 1; }
  local attempt i
  for attempt in 1 2 3; do
    systemctl restart "$SVC" >/dev/null 2>&1
    for i in $(seq 1 40); do
      sleep 0.5
      systemctl is-active --quiet "$SVC" && return 0
      systemctl is-failed --quiet "$SVC" 2>/dev/null && break
    done
    [ "$attempt" -lt 3 ] && sleep 2
  done
  return 1
}

svc_log() {
  [ -n "$SVC" ] || return 0
  command -v journalctl >/dev/null 2>&1 || return 0
  journalctl -u "${SVC}.service" -n 12 --no-pager -o cat 2>/dev/null | sed 's/^/       /' >&2
}

# ------------------------------------------------------------------ 主流程 ---
do_restore_config() {
  hr; say "第一步：扫描备份，确定要还原的文件"; hr
  scan_backups || return 1
  detect_cfg || { err "未找到 sing-box 配置目录，无法确定还原位置"; return 1; }
  detect_svc || warn "未探测到 systemd 服务，还原后不会自动重启"
  detect_bin && dim "二进制：$SB_BIN" || warn "未找到二进制，将跳过 sing-box check"

  ok "配置目录：$CFG"
  ok "可还原文件：${#ORIG_BASE[@]} 个"
  echo
  printf '  %-42s %s\n' "文件" "来源备份"
  printf '  %s\n' "$(printf '%.0s-' {1..70})"
  local b
  for b in "${ORIG_BASE[@]}"; do
    printf '  %-42s %s\n' "$b" "$(basename "${ORIG[$b]}")"
  done
  echo

  if [ "$DRY_RUN" = 1 ]; then
    warn "--dry-run：不做任何改动"
    return 0
  fi
  ask "确认把这些文件还原为备份内容（当前状态会先快照）？" || { dim "已取消"; return 1; }

  # ---- 快照当前状态 ----
  local snap
  snap="$SNAP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$snap"
  for b in "${ORIG_BASE[@]}"; do
    [ -f "$CFG/$b" ] && cp -a "$CFG/$b" "$snap/$b"
  done
  ok "当前状态已快照 -> $snap"
  printf '%s\n' "$snap" >"$BASE/last-snapshot"
  log "snapshot -> $snap"

  # ---- 临时目录里预演 ----
  hr; say "第二步：在临时副本上校验"; hr
  local stage
  stage=$(mktemp -d)
  cp -a "$CFG"/. "$stage"/ 2>/dev/null
  for b in "${ORIG_BASE[@]}"; do
    cp "${ORIG[$b]}" "$stage/$b"
  done
  if ! check_cfg_dir "$stage"; then
    err "还原后的配置未通过 sing-box check，已放弃（原文件未改动）"
    rm -rf "$stage"; return 1
  fi
  ok "校验通过"
  rm -rf "$stage"

  # ---- 落盘 ----
  hr; say "第三步：写回文件"; hr
  local n=0
  for b in "${ORIG_BASE[@]}"; do
    if cat "${ORIG[$b]}" >"$CFG/$b" 2>/dev/null; then
      ok "已还原 $b"
      n=$((n+1))
    else
      err "写入失败：$CFG/$b"
    fi
  done
  log "restored $n files"
  [ "$n" -gt 0 ] || { err "没有任何文件被还原"; return 1; }

  # ---- 重启 ----
  hr; say "第四步：重启服务"; hr
  if [ -z "$SVC" ]; then
    warn "无 systemd 服务，请手工启动"; return 0
  fi
  if restart_svc; then
    ok "服务已重启：$SVC active"
  else
    err "重启失败，正在用快照回滚到撤销前状态"
    svc_log
    local b2
    for b2 in "${ORIG_BASE[@]}"; do
      [ -f "$snap/$b2" ] && cat "$snap/$b2" >"$CFG/$b2"
    done
    if restart_svc; then
      ok "已回滚到撤销前状态并重启"
      warn "还原未生效；请查看 $LOGF 与上面的日志"
    else
      err "回滚后服务仍未启动 —— 请立即手工检查：systemctl status $SVC"
      svc_log
    fi
    return 1
  fi
  return 0
}

do_restore_sys() {
  hr; say "第五步：还原系统层"; hr
  dim "只删除 sb-opt 自己创建的东西，不动系统原有配置"

  local removed=0

  if [ -f /etc/sysctl.d/99-sb-opt.conf ]; then
    rm -f /etc/sysctl.d/99-sb-opt.conf && { ok "删除 /etc/sysctl.d/99-sb-opt.conf"; removed=1; }
  fi
  if [ -f /etc/sysctl.d/99-zz-sb-opt-qdisc.conf ]; then
    rm -f /etc/sysctl.d/99-zz-sb-opt-qdisc.conf && { ok "删除 99-zz-sb-opt-qdisc.conf"; removed=1; }
  fi
  if [ -f /etc/modules-load.d/sb-bbr.conf ]; then
    rm -f /etc/modules-load.d/sb-bbr.conf && ok "删除 sb-bbr.conf（模块已加载，本次运行不受影响）"
  fi
  [ "$removed" = 1 ] && sysctl --system >/dev/null 2>&1
  printf '  当前拥塞控制：%s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  printf '  当前默认队列：%s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null)"

  # tc 队列：尽量回到 Ubuntu 默认的 fq_codel / 你原来的 fq_pie
  local dev
  dev=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
  if [ -n "${dev:-}" ]; then
    if tc qdisc replace dev "$dev" root fq_pie 2>/dev/null; then
      ok "$dev 队列 -> fq_pie（你原来的值）"
    elif tc qdisc replace dev "$dev" root fq_codel 2>/dev/null; then
      ok "$dev 队列 -> fq_codel（系统默认）"
    else
      warn "$dev 队列未能改回，保持现状"
    fi
  fi

  # systemd 句柄 drop-in
  local d=/etc/systemd/system/sing-box.service.d
  if [ -d "$d" ] && [ -f "$d/limits.conf" ]; then
    if [ "$(ls -1 "$d" | wc -l)" -le 1 ]; then
      rm -rf "$d" && ok "删除句柄 drop-in：$d"
    else
      rm -f "$d/limits.conf" && ok "删除 $d/limits.conf（保留该目录其他文件）"
    fi
    systemctl daemon-reload
  fi

  # swap（sb-opt 创建的 1G swapfile）
  if [ -f /swapfile ] && swapon --show 2>/dev/null | grep -q '/swapfile'; then
    if ask "关闭并删除 sb-opt 创建的 1G swap？（2G 内存机上会降低 OOM 容错）"; then
      swapoff /swapfile 2>/dev/null
      rm -f /swapfile
      sed -i '\#^/swapfile#d' /etc/fstab 2>/dev/null
      rm -f /etc/sysctl.d/99-sb-swap.conf
      sysctl --system >/dev/null 2>&1
      ok "swap 已移除"
    else
      dim "保留 swap"
    fi
  fi

  # 缓存
  [ -d "$BASE/clean" ] && rm -rf "$BASE/clean" && ok "清理 JSONC 规范化缓存"

  hr
  if [ -n "$SVC" ] && systemctl is-active --quiet "$SVC"; then
    systemctl restart "$SVC" >/dev/null 2>&1 && ok "服务已按新句柄上限重启"
  fi
  ok "系统层还原完成"
}

show_result() {
  hr; say "还原结果"; hr
  detect_cfg || return 0
  if command -v jq >/dev/null 2>&1; then
    local total f n
    total=0
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      n=$(jq '(.inbounds // []) | length' "$f" 2>/dev/null) || n=0
      total=$((total+n))
    done < <(find "$CFG" -maxdepth 1 -name '*.json' -type f 2>/dev/null)
    printf '  入站总数：%s\n' "$total"
    dim "（还原后应回到 12 个）"
  fi
  printf '  服务状态：%s\n' "$(systemctl is-active "${SVC:-none}" 2>/dev/null)"
  echo
  dim "反悔：从快照还原"
  dim "  cp -a $(cat "$BASE/last-snapshot" 2>/dev/null)/* $CFG/ && systemctl restart ${SVC:-sing-box}"
  echo
}

# ------------------------------------------------------------------ 入口 ----
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)   ASSUME_YES=1 ;;
    --dry-run)  DRY_RUN=1 ;;
    --sys)      DO_SYS=1 ;;
    --list)     need_root; cmd_list; exit 0 ;;
    --help|-h)  usage ;;
    *)          err "未知参数：$1"; usage ;;
  esac
  shift
done

need_root
mkdir -p "$BASE"

if do_restore_config; then
  [ "$DO_SYS" = 1 ] && do_restore_sys
  show_result
  ok "完成。日志：$LOGF"
else
  err "还原未完成，请查看上面的输出"
  exit 1
fi