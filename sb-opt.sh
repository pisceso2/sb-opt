#!/usr/bin/env bash
# ============================================================================
# VERSION 1.5.3
#  sb-opt.sh  ——  sing-box / Xray 一体机 性能优化 · 体检 · 排障 工具
#
#  适用：Debian 11/12、Ubuntu 20.04+（内核 >= 4.9），root 运行
#  场景：香港 2C2G 小机 + sing-box 四合一（Reality / Hysteria2 / TUIC / Argo）
#
#  v1.1.0 变更：
#    · 配置探测重写：运行进程参数 / systemd ExecStart / docker / 已知路径 /
#      受限 find 五路探测，兼容 mack-a 等多文件目录布局
#    · 新增 doctor 子命令，探测失败时可单独出诊断报告
#    · 多文件目录模式下按「文件+索引」精确定位入站再修改
#
#  安全原则：
#    1) 改动配置前自动备份到 /root/sb-opt/backups/
#    2) 改动后执行 sing-box check 校验（目录模式在临时副本上校验）
#    3) 校验或重启失败 -> 自动回滚到上一份可用配置
#    4) 幂等：反复执行不会重复叠加
#
#  用法：bash sb-opt.sh                 交互菜单
#        bash sb-opt.sh doctor          只做配置探测诊断（只读）
#        bash sb-opt.sh audit           只体检（只读，不改任何东西）
#        bash sb-opt.sh sys             系统层优化（BBR/sysctl/swap/句柄）
#        bash sb-opt.sh tune            配置层调参（逐项确认）
#        bash sb-opt.sh dest            REALITY 伪装站选优
#        bash sb-opt.sh links           生成客户端链接
#        bash sb-opt.sh port <tag|type> <n>  改某个入站端口
#        bash sb-opt.sh disable <tag|type>  停用某个入站
#        bash sb-opt.sh enable <tag|type>   恢复某个入站
#        bash sb-opt.sh traffic         流量统计 + 每日配额提醒
#        bash sb-opt.sh rollback        回滚到最近一次备份
#        bash sb-opt.sh update          从 GitHub 拉取最新版
# ============================================================================

set -uo pipefail

BASE="/root/sb-opt"
BK="$BASE/backups"
DIS="$BASE/disabled"
LOGF="$BASE/sb-opt.log"
SYSCTL_FILE="/etc/sysctl.d/99-sb-opt.conf"
REPO_RAW="https://raw.githubusercontent.com/pisceso2/sb-opt/main"
# 下载源（按顺序尝试）：国内网络下 raw.githubusercontent 常被挡
MIRRORS=(
  "$REPO_RAW"
  "https://cdn.jsdelivr.net/gh/pisceso2/sb-opt@main"
  "https://raw.gitmirror.com/pisceso2/sb-opt/main"
  "https://ghfast.top/https://raw.githubusercontent.com/pisceso2/sb-opt/main"
)

CFG=""          # 配置文件，或（多文件模式）配置目录
CFG_MULTI=0     # 1 = 目录多文件
CFG_SRC=""      # 探测来源说明
CONTAINER=""    # docker 容器名（若适用）
SVC=""          # systemd 服务名
SB_BIN=""       # sing-box / xray 可执行文件路径

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

_JQSTATE=""
jqok() {
  if [ -z "$_JQSTATE" ]; then
    if command -v jq >/dev/null 2>&1 \
       && printf '{"a":1}' | jq -e '.a==1' >/dev/null 2>&1; then _JQSTATE=1; else _JQSTATE=0; fi
  fi
  [ "$_JQSTATE" = 1 ]
}

# 确保 jq 可用（不可用则自动安装），v1.1 起所有解析都依赖它
ensure_jq() {
  jqok && return 0
  req_pkg jq
  _JQSTATE=""
  jqok && return 0
  err "jq 不可用，请手动安装：apt install -y jq"
  return 1
}

# ============================================================ 配置探测 ======
# 探测来源（按可信度）：
#   1) 正在运行的 sing-box/xray 进程命令行里的 -c / --config
#   2) systemd 单元 ExecStart 里的 -c / --config
#   3) docker 容器（映射到宿主机的路径）
#   4) 已知安装路径
#   5) 受限 find（/etc /opt /root /usr/local 下 5 层内）

_p_pid() {
  local pid cmd path
  for pid in $(pgrep -f '[s]ing-box|[x]ray|[v]2ray' 2>/dev/null); do
    cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || continue
    path=$(printf '%s\n' "$cmd" | tr ' ' '\n' \
           | awk 'p{print;exit} /^-c$|^--config$|^-config$/{p=1}' )
    [ -n "${path:-}" ] && printf '%s|进程 %s\n' "$path" "$pid"
    # 也支持 -c/path 粘连写法
    printf '%s\n' "$cmd" | grep -oE '\-c/?[^ ]+\.(json|yaml)' 2>/dev/null \
      | sed -E 's/^-c//' | while read -r q; do [ -n "$q" ] && printf '%s|进程参数\n' "$q"; done
  done
}

_p_unit() {
  local u a path
  for u in $(systemctl list-unit-files --no-legend --no-pager 2>/dev/null \
             | awk '{print $1}' | grep -Ei 'sing|xray|v2ray|hysteria|hy2|tuic|mihomo'); do
    a=$(systemctl show -p ExecStart --value "$u" 2>/dev/null) || continue
    path=$(printf '%s\n' "${a//;/ }" | tr ' ' '\n' \
           | awk 'p{print;exit} /^-c$|^--config$|^-config$/{p=1}')
    [ -n "${path:-}" ] && printf '%s|单元 %s\n' "$path" "$u"
  done
}

_p_docker() {
  command -v docker >/dev/null 2>&1 || return 0
  local line name img cpath hostpath mnts
  docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | while IFS='|' read -r name img; do
    printf '%s' "$img" | grep -qiE 'sing-box|xray|v2ray|hysteria|mihomo' || continue
    cpath=$(docker inspect "$name" --format '{{range .Config.Cmd}}{{.}} {{end}}' 2>/dev/null \
            | tr ' ' '\n' | awk 'p{print;exit} /^-c$|^--config$/{p=1}')
    mnts=$(docker inspect "$name" --format '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' 2>/dev/null)
    hostpath=""
    if [ -n "${cpath:-}" ]; then
      for pair in $mnts; do
        src="${pair%%:*}"; dst="${pair#*:}"
        case "$cpath" in
          "$dst"/*) hostpath="$src/${cpath#"$dst"/}" ;;
          "$dst")   hostpath="$src" ;;
        esac
        [ -n "$hostpath" ] && break
      done
      [ -z "$hostpath" ] && hostpath="$cpath"
    fi
    [ -n "${hostpath:-}" ] && printf '%s|docker %s（容器内 %s）\n' "$hostpath" "$name" "${cpath:-未知}"
  done
}

_p_known() {
  local p
  for p in \
    /etc/sing-box/config.json \
    /usr/local/etc/sing-box/config.json \
    /opt/sing-box/config.json \
    /root/sing-box/config.json \
    /etc/sing-box/conf/config.json \
    /etc/sing-box/conf \
    /etc/sing-box \
    /usr/local/etc/sing-box/conf \
    /etc/v2ray-agent/sing-box/conf/config \
    /etc/v2ray-agent/sing-box/conf \
    /usr/local/etc/v2ray-agent/sing-box/conf/config \
    /etc/xray/config.json \
    /usr/local/etc/xray/config.json \
    /etc/v2ray-agent/xray/conf \
    /usr/local/etc/xray/conf
  do
    [ -e "$p" ] && printf '%s|已知路径\n' "$p"
  done
}

_p_find() {
  find /etc /opt /root /usr/local/etc -maxdepth 5 \
       \( -name 'config.json' -o -name '*sing*.json' -o -name 'config-*.json' \) \
       -path '*sing*' 2>/dev/null | head -20 | while read -r p; do
    printf '%s|find\n' "$p"
  done
}

# 目录是否像 sing-box 多文件配置目录
dir_looks_like_cfg() {
  local d="$1" f n=0 hit=0
  [ -d "$d" ] || return 1
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue
    n=$((n+1))
    if jqok; then
      jq -e '.inbounds // .outbounds' "$f" >/dev/null 2>&1 && hit=$((hit+1))
    else
      grep -qE '"(inbounds|outbounds)"' "$f" 2>/dev/null && hit=$((hit+1))
    fi
    [ "$n" -ge 20 ] && break
  done
  [ "$n" -gt 0 ] && [ "$hit" -gt 0 ]
}

# 单文件是否像 sing-box/xray 配置
file_looks_like_cfg() {
  local f="$1"
  [ -f "$f" ] || return 1
  case "$f" in *.yaml|*.yml) return 1 ;; esac
  [ "$f" = "/etc/sing-box/config.json" ] && return 0
  grep -q '"inbounds"' "$f" 2>/dev/null
}

# 接受候选路径，判定并设置 CFG / CFG_MULTI
_accept_cfg() {
  local path="${1%%|*}" src="${1#*|}"
  [ -n "$path" ] || return 1

  # docker 场景：记下容器名，后续重启走 docker restart
  case "$src" in
    docker\ *) CONTAINER=$(printf '%s' "$src" | sed -E 's/^docker +//; s/[（(].*$//' | tr -d ' ') ;;
  esac

  if [ -d "$path" ]; then
    dir_looks_like_cfg "$path" || return 1
    CFG="$path"; CFG_MULTI=1; CFG_SRC="$src"
    return 0
  fi
  if [ -f "$path" ]; then
    file_looks_like_cfg "$path" || return 1
    CFG="$path"; CFG_MULTI=0; CFG_SRC="$src"
    return 0
  fi
  return 1
}

# 探测失败时，把带 inbounds 的 json 找出来做兜底
_fallback_scan() {
  local f
  while read -r f; do
    [ -f "$f" ] || continue
    grep -q '"inbounds"' "$f" 2>/dev/null || continue
    # 判断是否属于某个多文件目录
    local d; d=$(dirname "$f")
    if dir_looks_like_cfg "$d"; then
      CFG="$d"; CFG_MULTI=1; CFG_SRC="兜底扫描"
      return 0
    fi
    CFG="$f"; CFG_MULTI=0; CFG_SRC="兜底扫描"
    return 0
  done < <(find /etc /opt /root /usr/local /srv -maxdepth 6 -name '*.json' -size -2M 2>/dev/null | head -200)
  return 1
}

detect_cfg() {
  [ -n "$CFG" ] && return 0
  local c

  # 探测依赖 jq（判断目录/文件是否为配置），缺失时静默装一次
  if ! jqok; then
    req_pkg jq >/dev/null 2>&1 || true
    _JQSTATE=""; jqok || true
  fi

  # 1) 进程
  while IFS= read -r c; do _accept_cfg "$c" && return 0; done < <(_p_pid)
  # 2) systemd
  while IFS= read -r c; do _accept_cfg "$c" && return 0; done < <(_p_unit)
  # 3) docker
  while IFS= read -r c; do _accept_cfg "$c" && return 0; done < <(_p_docker)
  # 4) 已知路径
  while IFS= read -r c; do _accept_cfg "$c" && return 0; done < <(_p_known)
  # 5) find
  while IFS= read -r c; do _accept_cfg "$c" && return 0; done < <(_p_find)
  # 6) 兜底
  _fallback_scan && return 0
  return 1
}

# 服务名必须真的是代理核心，禁止把 argo/nginx 之类当成 sing-box 重启
_svc_safe() {
  case "$1" in
    sing-box|singbox|sing-box-server|xray|v2ray|mihomo|hysteria|hysteria-server) return 0 ;;
    *sing-box*|*singbox*|*xray*|*hysteria*) return 0 ;;
    *) return 1 ;;
  esac
}

detect_svc() {
  [ -n "$SVC" ] && return 0
  local u out

  # 1) 直接探测候选单元是否存在（systemctl cat 不受颜色/分页影响）
  for u in sing-box singbox sing-box-server xray v2ray mihomo hysteria-server hysteria; do
    if systemctl cat "${u}.service" >/dev/null 2>&1; then
      SVC="$u"; return 0
    fi
  done

  # 2) 在所有 unit 里找 ExecStart 提到 sing-box/xray 的那个
  for u in $(systemctl list-unit-files --no-legend --no-pager 2>/dev/null \
             | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $1}' | grep -E '\.service$'); do
    out=$(systemctl show -p ExecStart --value "$u" 2>/dev/null)
    case "$out" in
      *sing-box*|*xray*) _svc_safe "${u%.service}" && { SVC="${u%.service}"; return 0; } ;;
    esac
  done

  # 3) 从进程反推（只接受名字像代理服务的单元）
  local pid name
  for pid in $(pgrep -f '[s]ing-box|[x]ray' 2>/dev/null | head -3); do
    name=$(systemctl status "$pid" 2>/dev/null | head -1 \
           | sed 's/\x1b\[[0-9;]*m//g' | grep -oE '[a-zA-Z0-9_.-]+\.service' | head -1)
    [ -n "${name:-}" ] || continue
    if _svc_safe "${name%.service}"; then
      SVC="${name%.service}"; return 0
    fi
  done
  return 1
}

# 配置里的所有 json 文件（多文件目录 -> 多个）
cfg_files() {
  if [ "$CFG_MULTI" = 1 ]; then
    find "$CFG" -maxdepth 1 -name '*.json' -type f | sort
  else
    echo "$CFG"
  fi
}

# ==================================================== 入站索引（文件+下标） ==
declare -a IDX=()   # 每项 "文件|下标|tag|type|端口"
# ------------------------------------------------- JSONC（带注释）兼容 ------
# sing-box 用 jsonc 兼容解析器，允许 // 注释、/* */ 注释与尾逗号；
# jq 只吃严格 JSON，所以带注释的文件会被 jq 判为非法。
declare -A CLEAN=()

_sanitize_jsonc() {   # $1 源文件  $2 输出文件
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" "$2" <<'PYEOF'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
s = open(src, 'rb').read().decode('utf-8-sig', 'replace')
out = []; i = 0; n = len(s); instr = False; esc = False
while i < n:
    c = s[i]
    if instr:
        out.append(c)
        if esc: esc = False
        elif c == '\\': esc = True
        elif c == '"': instr = False
        i += 1; continue
    if c == '"':
        instr = True; out.append(c); i += 1; continue
    if c == '/' and i + 1 < n and s[i+1] == '/':
        while i < n and s[i] not in '\r\n': i += 1
        continue
    if c == '/' and i + 1 < n and s[i+1] == '*':
        i += 2
        while i + 1 < n and not (s[i] == '*' and s[i+1] == '/'): i += 1
        i += 2; continue
    out.append(c); i += 1
t = ''.join(out)
t = re.sub(r',(\s*[}\]])', r'\1', t)
open(dst, 'w', encoding='utf-8').write(t)
PYEOF
}

# 返回一个 jq 能读的等价文件：本身合法就用原文件，否则生成规范化副本
readable_file() {
  local f="$1" clean rc
  if jq -e . "$f" >/dev/null 2>&1; then printf '%s\n' "$f"; return 0; fi
  [ -n "${CLEAN[$f]:-}" ] && { printf '%s\n' "${CLEAN[$f]}"; return 0; }
  mkdir -p "$BASE/clean"
  clean="$BASE/clean/$(printf '%s' "$f" | md5sum | cut -c1-8)-$(basename "$f")"
  if _sanitize_jsonc "$f" "$clean" && jq -e . "$clean" >/dev/null 2>&1; then
    CLEAN[$f]="$clean"
    printf '%s\n' "$clean"; return 0
  fi
  rm -f "$clean"
  return 1
}

# 与 jq 用法一致，但文件参数支持 JSONC：内部自动换成规范化副本
qjq() {
  local n=$# file="${!#}" rf
  [ "$n" -ge 2 ] || { jq "$@"; return $?; }
  local -a args=("${@:1:$((n-1))}")
  rf=$(readable_file "$file") || return 2
  jq "${args[@]}" "$rf"
}

SKIPPED_FILES=()
build_index() {
  IDX=(); SKIPPED_FILES=()
  jqok || return 1
  local f n i tag type port
  local rf
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if ! rf=$(readable_file "$f"); then
      case "$(basename "$f")" in
        *inbound*|*inb*) SKIPPED_FILES+=("$(basename "$f")") ;;
      esac
      continue
    fi
    n=$(jq '.inbounds | length' "$rf" 2>/dev/null) || continue
    [ -n "$n" ] || continue
    if [ "$n" -eq 0 ]; then
      case "$(basename "$f")" in
        *inbound*|*inb*) SKIPPED_FILES+=("$(basename "$f")（inbounds 为空）") ;;
      esac
      continue
    fi
    for ((i=0; i<n; i++)); do
      tag=$(jq -r ".inbounds[$i].tag // \"-\"" "$rf")
      type=$(jq -r ".inbounds[$i].type // \"-\"" "$rf")
      port=$(jq -r ".inbounds[$i].listen_port // \"-\"" "$rf")
      IDX+=("$f|$i|$tag|$type|$port")
    done
  done < <(cfg_files)
  [ ${#IDX[@]} -gt 0 ]
}

# 按 tag 或 type 查找索引项，输出 "文件|下标"
_idx_emit() { printf '%s|%s\n' "$(printf '%s' "$1" | cut -d'|' -f1)" \
                                "$(printf '%s' "$1" | cut -d'|' -f2)"; }

# 协议别名：hy2 -> hysteria2 等
_type_alias() {
  case "$1" in
    hy2|hysteria|h2|hysteria2) echo hysteria2 ;;
    ss|shadowsocks)            echo shadowsocks ;;
    stls|shadow-tls)           echo shadowtls ;;
    *)                         echo "$1" ;;
  esac
}

# 定位入站：支持 序号(#1) / tag 精确 / tag 包含 / type / type 别名
locate_inbound() {
  local key="$1" e tag type k alias

  # 1) 纯数字 = audit 里的序号（1 起）
  if [[ "$key" =~ ^#?[0-9]+$ ]]; then
    k=$(printf '%s' "${key#\#}")
    if [ "$k" -ge 1 ] && [ "$k" -le "${#IDX[@]}" ]; then
      _idx_emit "${IDX[$((k-1))]}"; return 0
    fi
    return 1
  fi

  # 2) tag 精确
  for e in "${IDX[@]}"; do
    tag=$(printf '%s' "$e" | cut -d'|' -f3)
    [ "$tag" = "$key" ] && { _idx_emit "$e"; return 0; }
  done

  # 3) tag 包含（忽略大小写），适配 "🇭🇰 xxx tuic" 这种长 tag
  for e in "${IDX[@]}"; do
    tag=$(printf '%s' "$e" | cut -d'|' -f3)
    case "${tag,,}" in *"${key,,}"*) _idx_emit "$e"; return 0 ;; esac
  done

  # 4) type 精确 / 别名
  alias=$(_type_alias "$key")
  for e in "${IDX[@]}"; do
    type=$(printf '%s' "$e" | cut -d'|' -f4)
    [ "$type" = "$alias" ] && { _idx_emit "$e"; return 0; }
  done
  return 1
}

# =================================================== 备份 / 校验 / 回滚 ====
backup_file() {
  local f="$1" desc="$2"
  [ -f "$f" ] || return 0
  mkdir -p "$BK"
  local b="$BK/$(date +%Y%m%d-%H%M%S)-$(basename "$f")"
  cp -a "$f" "$b"
  printf '%s\n' "$f" >"$BASE/last_target"
  printf '%s\n' "$b" >"$BASE/last_backup"
  dim "已备份 -> $b"
  ls -1t "$BK"/* 2>/dev/null | tail -n +16 | xargs -r rm -f
  log "backup $f -> $b ($desc)"
}

_is_proxy_bin() {
  case "$(basename "${1:-}")" in
    sing-box|xray|sing-box-real) return 0 ;;
    *) return 1 ;;
  esac
}

detect_bin() {
  [ -n "$SB_BIN" ] && return 0
  local pid exe cwd

  # 1) 运行中进程的真实可执行文件（/proc/<pid>/exe）——最可靠
  for pid in $(pgrep -f '[s]ing-box|[x]ray' 2>/dev/null); do
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
    exe=${exe% (deleted)}
    _is_proxy_bin "$exe" || continue
    if [ -x "$exe" ]; then SB_BIN="$exe"; return 0; fi
    # 二进制被替换/删除：记住路径，但校验会失败，交给下面的搜索
    [ -n "${_SB_BIN_HINT:-}" ] || _SB_BIN_HINT="$exe"
  done

  # 2) 进程 argv[0]（支持相对路径，用 /proc/<pid>/cwd 还原）
  for pid in $(pgrep -f '[s]ing-box|[x]ray' 2>/dev/null); do
    exe=$(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | head -1)
    case "$exe" in
      /*) : ;;
      */*) cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null); exe="${cwd}/${exe}" ;;
      *) continue ;;
    esac
    _is_proxy_bin "$exe" || continue
    [ -x "$exe" ] && { SB_BIN="$exe"; return 0; }
  done

  # 3) systemd 单元 ExecStart 的第一个 token
  local u first
  if detect_svc; then
    first=$(systemctl show -p ExecStart --value "${SVC}.service" 2>/dev/null \
            | tr ';' '\n' | sed -n 's/^ *path=\([^ ;]*\).*/\1/p' | head -1)
    if [ -n "${first:-}" ] && _is_proxy_bin "$first" && [ -x "$first" ]; then
      SB_BIN="$first"; return 0
    fi
  fi

  # 4) PATH 与常见安装位置
  local p
  for p in sing-box xray \
           /usr/local/bin/sing-box /usr/bin/sing-box /etc/sing-box/sing-box \
           /etc/sing-box/bin/sing-box /etc/sing-box/argo/sing-box \
           /etc/v2ray-agent/sing-box/sing-box /etc/v2ray-agent/xray/xray \
           /opt/sing-box/sing-box /usr/local/bin/xray /usr/bin/xray; do
    case "$p" in
      /*) [ -x "$p" ] && { SB_BIN="$p"; return 0; } ;;
      *)  command -v "$p" >/dev/null 2>&1 && { SB_BIN=$(command -v "$p"); return 0; } ;;
    esac
  done

  # 5) 受限 find 兜底
  exe=$(find /etc /usr/local /opt /root -maxdepth 4 -type f \
        \( -name 'sing-box' -o -name 'xray' \) -perm -u+x 2>/dev/null | head -1)
  [ -n "${exe:-}" ] && [ -x "$exe" ] && { SB_BIN="$exe"; return 0; }

  return 1
}

check_cfg() {   # 校验 CFG（单文件或目录）；$1 可选=替换后的临时文件
  detect_bin || return 0
  local out rc stage
  if [ "$CFG_MULTI" = 1 ]; then
    stage=$(mktemp -d)
    cp -a "$CFG"/. "$stage"/ 2>/dev/null
    [ -n "${1:-}" ] && cp "$1" "$stage/$(basename "$TARGET_FILE")"
    out=$("$SB_BIN" check -C "$stage" 2>&1); rc=$?
    rm -rf "$stage"
  else
    out=$("$SB_BIN" check -c "${1:-$CFG}" 2>&1); rc=$?
  fi
  [ $rc -eq 0 ] && return 0
  grep -qi 'unknown command\|unknown flag\|flag provided but not defined' <<<"$out" && return 0
  printf '%s\n' "$out" | sed 's/^/       /' >&2
  return 1
}

# 服务最后的错误日志（重启失败时给用户看真正的原因）
svc_last_error() {
  [ -n "$SVC" ] || detect_svc 2>/dev/null || return 0
  command -v journalctl >/dev/null 2>&1 || return 0
  local log
  log=$(journalctl -u "${SVC}.service" -n 12 --no-pager -o cat 2>/dev/null | tail -12)
  [ -n "${log:-}" ] && printf '%s\n' "$log" | sed 's/^/       /' >&2
  return 0
}

# 重启并轮询等待就绪：2C2G 上 12 个入站启动常需 3-5 秒，2 秒判定会误判失败
restart_svc() {
  if [ -n "$CONTAINER" ]; then
    local i
    docker restart "$CONTAINER" >/dev/null 2>&1 || return 1
    for i in $(seq 1 30); do
      sleep 0.5
      [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ] && return 0
    done
    return 1
  fi
  if [ -z "$SVC" ]; then
    if ! detect_svc; then
      err "未找到 sing-box/xray 服务名，无法重启（服务可能由 docker 或前台进程管理）"
      return 1
    fi
  fi
  _svc_safe "$SVC" || { err "拒绝重启非代理服务：$SVC（请先确认服务名）"; return 1; }

  local attempt i
  for attempt in 1 2 3; do
    systemctl restart "$SVC" >/dev/null 2>&1
    for i in $(seq 1 40); do          # 最多等 20 秒
      sleep 0.5
      systemctl is-active --quiet "$SVC" && return 0
      systemctl is-failed --quiet "$SVC" 2>/dev/null && break
    done
    [ "$attempt" -lt 3 ] && sleep 2    # 端口释放/依赖就绪，再试一次
  done
  return 1
}

# apply_file <文件> <说明> [jq选项...] <jq表达式>
apply_file() {
  local f="$1" desc="$2"; shift 2
  local tmp rf
  TARGET_FILE="$f"
  if ! rf=$(readable_file "$f"); then
    err "$desc：$(basename "$f") 无法解析（JSONC 规范化也失败）"
    return 1
  fi
  [ "$rf" != "$f" ] && { warn "$(basename "$f") 含注释/尾逗号，写回后会变成严格 JSON"; }
  tmp=$(mktemp "/tmp/sbcfg.XXXXXX.json")
  if ! jq "$@" "$rf" >"$tmp" 2>"$BASE/jq.err"; then
    err "$desc：jq 处理失败"; sed 's/^/       /' "$BASE/jq.err" >&2; rm -f "$tmp"; return 1
  fi
  if ! check_cfg "$tmp"; then
    err "$desc：新配置未通过校验，已放弃本次修改"
    cp "$tmp" "$BASE/last-failed.json" 2>/dev/null
    rm -f "$tmp"; return 1
  fi
  backup_file "$f" "$desc"
  # 用 cat 覆写：保留原文件的权限/属主/ACL（sing-box 可能以非 root 运行）
  if ! cat "$tmp" >"$f" 2>/dev/null; then
    err "$desc：写入 $f 失败"; rm -f "$tmp"; return 1
  fi
  rm -f "$tmp"
  if restart_svc; then
    ok "$desc —— 已生效"; log "applied: $desc ($f)"
    return 0
  fi
  err "$desc：重启失败，正在回滚"
  dim "最近日志："; svc_last_error
  rollback_last
  return 1
}

rollback_last() {
  local t b
  t=$(cat "$BASE/last_target" 2>/dev/null)
  b=$(cat "$BASE/last_backup" 2>/dev/null)
  if [ -n "${t:-}" ] && [ -n "${b:-}" ] && [ -f "$b" ]; then
    cp -a "$b" "$t"
    if restart_svc; then
      ok "已回滚 $(basename "$b") -> $t"
    else
      err "回滚后服务仍无法启动，请手工检查"
      dim "最近日志："; svc_last_error
    fi
    log "rollback $b -> $t"
    return 0
  fi
  err "没有可用的最近备份"
  return 1
}

# ==================================================== 1. 配置探测诊断 ======
cmd_doctor() {
  hr; say "配置探测诊断"; hr
  ensure_jq

  printf '  探测进程 : %s\n' "$(pgrep -f '[s]ing-box|[x]ray' 2>/dev/null | tr '\n' ' ')"
  local u
  printf '  候选单元 : %s\n' \
    "$(systemctl list-unit-files --no-legend --no-pager 2>/dev/null | awk '{print $1}' \
       | grep -Ei 'sing|xray|v2ray|hysteria|hy2|tuic' | tr '\n' ' ')"

  hr; say "各来源原始输出"; hr
  echo "  [进程参数]"; _p_pid    | sed 's/^/    /' || echo "    （无）"
  echo "  [systemd]";   _p_unit   | sed 's/^/    /' || echo "    （无）"
  echo "  [docker]";    _p_docker | sed 's/^/    /' || echo "    （无）"
  echo "  [已知路径]";  _p_known  | sed 's/^/    /' || echo "    （无）"
  echo "  [find]";      _p_find   | sed 's/^/    /' || echo "    （无）"

  hr; say "判定结果"; hr
  detect_svc && ok "systemd 服务：$SVC" || warn "未找到 systemd 服务（可能是 docker 或前台进程）"
  detect_bin && ok "二进制：$SB_BIN" || warn "未找到 sing-box/xray 二进制，跳过配置校验"
  [ -n "$CONTAINER" ] && ok "docker 容器：$CONTAINER（改动后走 docker restart）"
  if detect_cfg; then
    ok "配置：$CFG"
    ok "模式：$([ "$CFG_MULTI" = 1 ] && echo '多文件目录' || echo '单文件')"
    ok "来源：$CFG_SRC"
    echo "  文件清单："
    cfg_files | sed 's/^/    /'
  else
    err "仍未定位到配置，请把上面全部输出贴回来"
  fi
  echo
}

# ------------------------------------------------------------ 2. 体检 ------
cmd_audit() {
  hr; say "环境体检"; hr

  printf '  系统    : %s\n' "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  printf '  内核    : %s' "$(uname -r)"
  if kernel_ok; then printf '  %s(>=4.9 可开 BBR)%s\n' "$c_g" "$c_0"
  else printf '  %s(<4.9，BBR 不可用，建议重装 Debian 12)%s\n' "$c_r" "$c_0"; fi
  printf '  架构    : %s\n' "$(uname -m)"

  local mem_total
  mem_total=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo)
  printf '  内存    : %sMB\n' "$mem_total"
  printf '  Swap    : %s\n' "$(swapon --show --noheadings 2>/dev/null | awk '{print $3}' | head -1)"

  printf '  拥塞控制: %s' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] \
    && printf '  %s✓%s\n' "$c_g" "$c_0" || printf '  %s✗ 未开启（跑 sys 修复）%s\n' "$c_y" "$c_0"
  local _dev _q
  _dev=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
  _q=""
  [ -n "${_dev:-}" ] && _q=$(tc qdisc show dev "$_dev" 2>/dev/null | awk '{print $2}' | head -1)
  printf '  qdisc   : %s（默认） / %s（%s 实际）\n' \
    "$(sysctl -n net.core.default_qdisc 2>/dev/null)" "${_q:-未知}" "${_dev:-?}"
  printf '  文件句柄: %s\n' "$(ulimit -n)"

  hr
  if ! detect_cfg; then
    err "未找到 sing-box / xray 配置文件"
    dim "请先执行：sbopt doctor   然后把输出发出来"
    return 0
  fi
  detect_svc
  [ -f "$BASE/last_target" ] || true
  ok "配置：$CFG"
  dim "模式：$([ "$CFG_MULTI" = 1 ] && echo '多文件目录' || echo '单文件')    来源：$CFG_SRC"
  printf '  服务    : %s  %s\n' "${SVC:-未找到}" "$(systemctl is-active "${SVC:-none}" 2>/dev/null)"
  if detect_bin; then
    printf '  二进制  : %s\n' "$SB_BIN"
    printf '  版本    : %s\n' "$("$SB_BIN" version 2>/dev/null | head -1)"
  else
    printf '  二进制  : %s未找到%s（改配置时将跳过 sing-box check）\n' "$c_y" "$c_0"
    printf '  版本    : %s\n' "未知"
  fi

  if ! jqok; then warn "缺少 jq，无法解析配置（跑 sys 会自动安装）"; return 0; fi

  hr; say "入站清单"; hr
  if ! build_index; then
    warn "配置里没有可解析的 .inbounds 数组"
    dim "可能是 hysteria 的 yaml 配置，或 sing-box 只用 .outbounds 做客户端"
    return 0
  fi
  printf '  %-3s %-16s %-12s %-7s %s\n' "#" "TAG" "类型" "端口" "备注"
  printf '  %s\n' "$(printf '%.0s-' {1..62})"
  local k=0 e tag type port note
  for e in "${IDX[@]}"; do
    k=$((k+1))
    tag=$(printf '%s' "$e" | cut -d'|' -f3)
    type=$(printf '%s' "$e" | cut -d'|' -f4)
    port=$(printf '%s' "$e" | cut -d'|' -f5)
    case "$type" in
      vless)     note="REALITY/Vision，TCP 主力" ;;
      hysteria2) note="QUIC 抗丢包，最费流量" ;;
      tuic)      note="QUIC，与 hy2 二选一" ;;
      vmess|trojan) note="常规代理" ;;
      *)         note="" ;;
    esac
    printf '  %-3s %-16s %-12s %-7s %s\n' "$k" "$tag" "$type" "$port" "$note"
  done

  if [ ${#SKIPPED_FILES[@]} -gt 0 ]; then
    hr; warn "以下 inbound 配置文件没能解析出 .inbounds，已被跳过："
    printf '       %s\n' "${SKIPPED_FILES[@]}"
  fi

  local n=${#IDX[@]}
  if [ "$n" -gt 2 ]; then
    hr; warn "当前有 $n 个入站，建议只保留 2 个"
    local has_reality=0 has_quic=0
    local ee tt
    for ee in "${IDX[@]}"; do
      tt=$(printf '%s' "$ee" | cut -d'|' -f4)
      [ "$tt" = "vless" ] && has_reality=1
      case "$tt" in hysteria2|tuic) has_quic=1 ;; esac
    done
    if [ "$has_reality" = 1 ]; then
      dim "推荐组合：VLESS-REALITY（TCP 主力）+ Hysteria2（晚高峰抗丢包）"
    elif [ "$has_quic" = 1 ]; then
      dim "推荐组合：一个 QUIC（hysteria2 或 tuic 只留其一）+ 一个 TCP-TLS（trojan 或 anytls 只留其一）"
      dim "同时开 hy2 与 tuic 会互相抢 UDP 配额，且更容易被 QoS 针对"
    else
      dim "推荐组合：一个 TCP-TLS（trojan 或 anytls 只留其一）+ 一个 QUIC（可选）"
    fi
    dim "多开不提升速度，只增加暴露面、CPU 与排查难度"
  fi

  hr; say "端口监听"; hr
  ss -lntup 2>/dev/null | grep -E 'sing-box|xray' | awk '{print "  "$1"  "$5"  "$7}' || echo "  （无）"

  # 对账：对外监听端口 vs 配置里声明的端口，抓「配置没读全」
  local -a declared=()
  local pe pp f3 rf3
  while IFS= read -r pe; do
    [ -n "$pe" ] && declared+=("$pe")
  done < <(
    while IFS= read -r f3; do
      rf3=$(readable_file "$f3") || continue
      jq -r '.. | objects | .listen_port? // empty' "$rf3" 2>/dev/null
    done < <(cfg_files)
  )
  local -a unknown=()
  while read -r pp; do
    [ -n "$pp" ] || continue
    case " ${declared[*]} " in *" $pp "*) ;; *) unknown+=("$pp") ;; esac
  done < <(ss -lntup 2>/dev/null | grep -E 'sing-box|xray' \
             | awk '$5 !~ /^127\.0\.0\.1:/ && $5 !~ /^\[::1\]:/ {n=split($5,a,":"); p=a[n]; if (p >= 30000) next; print p}' \
             | sort -un)

  if [ ${#unknown[@]} -gt 0 ]; then
    hr; warn "有 ${#unknown[@]} 个对外端口在配置里找不到对应入站：${unknown[*]}"
    dim "说明配置没读全（可能有多份配置文件），请跑：sbopt doctor"
  fi

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
  local e2 seen_reality=0 seen_obfs=0
  for e2 in "${IDX[@]}"; do
    local f2 i2
    f2=$(printf '%s' "$e2" | cut -d'|' -f1)
    i2=$(printf '%s' "$e2" | cut -d'|' -f2)
    if [ "$seen_reality" = 0 ] && qjq -e '.inbounds['"$i2"'].type=="vless" and .inbounds['"$i2"'].tls.reality.enabled==true and ((.inbounds['"$i2"'].tls.reality.short_id | if type=="array" then (.[0] // "") else (. // "") end) == "")' "$f2" >/dev/null 2>&1; then
      dim "· 有 REALITY 入站 short_id 为空 -> 建议补一个随机 shortId"; seen_reality=1
    fi
    if [ "$seen_obfs" = 0 ] && jq -e ".inbounds[$i2].type==\"hysteria2\" and (.inbounds[$i2].obfs.type//\"\")==\"\"" "$(readable_file "$f2")" >/dev/null 2>&1; then
      dim "· Hysteria2 未加 obfs，UDP 易被 QoS -> 执行 tune"; seen_obfs=1
    fi
  done
  [ "$n" -eq 0 ] && dim "· 没有可用入站信息 -> 执行 doctor"
  echo
}

# ------------------------------------------------------- 3. 系统层优化 ------
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
  [ "$cc" = "bbr" ] && ok "拥塞控制 = bbr" || err "拥塞控制 = $cc（未生效）"

  qd=$(sysctl -n net.core.default_qdisc)
  if [ "$qd" != "fq" ]; then
    warn "默认队列被其它 sysctl 覆盖成 $qd，用 99-zz 抢回优先级"
    cat >/etc/sysctl.d/99-zz-sb-opt-qdisc.conf <<'EOF'
# sb-opt：排在最后，覆盖其他 sysctl.d 里的 fq_pie 等设置
net.core.default_qdisc = fq
EOF
    sysctl --system >/dev/null 2>&1
    qd=$(sysctl -n net.core.default_qdisc)
  fi
  [ "$qd" = "fq" ] && ok "默认队列 = fq" || warn "默认队列仍为 $qd（有程序在运行时改它，只影响新建网卡）"

  # default_qdisc 只作用于新建网卡；已存在的网卡要 tc 显式替换
  local dev main_dev
  main_dev=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
  for dev in $(
    { echo "${main_dev:-}"; ip -o link show 2>/dev/null | awk -F': ' '{print $2}'; } \
    | awk 'NF' | grep -vE '^(lo|docker.*|veth.*|br-.*|tun.*|sing.*|wg.*)$' | sort -u
  ); do
    [ -d "/sys/class/net/$dev" ] || continue
    if tc qdisc replace dev "$dev" root fq 2>/dev/null; then
      ok "$dev 队列 -> fq"
    else
      warn "$dev 设置 fq 失败（驱动不支持？）"
    fi
  done
  local q_show
  q_show=$(tc qdisc show dev "${main_dev:-eth0}" 2>/dev/null | head -1)
  [ -n "$q_show" ] && dim "当前：$q_show"

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

  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true 2>/dev/null || true
    if timedatectl status 2>/dev/null | grep -qi 'synchronized: yes'; then
      ok "系统时间已同步"
    else
      warn "时间未同步 —— 建议 apt install -y systemd-timesyncd && systemctl enable --now systemd-timesyncd"
    fi
  fi

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

# ------------------------------------------------------- 4. 配置层调参 ------
cmd_tune() {
  hr; say "配置层调参"; hr
  detect_cfg || { err "未找到配置文件，请先跑 sbopt doctor"; return 1; }
  detect_svc
  ensure_jq
  build_index || { err "配置里没有可解析的入站"; return 1; }

  dim "配置：$CFG（$([ "$CFG_MULTI" = 1 ] && echo 多文件目录 || echo 单文件)）"
  local changed=0 e f i type tag

  # ---------- REALITY ----------
  for e in "${IDX[@]}"; do
    f=$(printf '%s' "$e" | cut -d'|' -f1)
    i=$(printf '%s' "$e" | cut -d'|' -f2)
    tag=$(printf '%s' "$e" | cut -d'|' -f3)
    type=$(printf '%s' "$e" | cut -d'|' -f4)
    [ "$type" = "vless" ] || continue
    qjq -e ".inbounds[$i].tls.reality.enabled == true" "$f" >/dev/null 2>&1 || continue

    local hs sid
    hs=$(qjq -r ".inbounds[$i].tls.reality.handshake.server // .inbounds[$i].tls.server_name // \"-\"" "$f")
    sid=$(qjq -r '.inbounds[$i].tls.reality.short_id | if type=="array" then (.[0] // "") else (. // "") end' "$f")

    hr; printf '  REALITY 入站 [%s]  (%s)\n' "$tag" "$(basename "$f")"
    printf '    伪装站 : %s\n' "$hs"
    printf '    shortId: %s\n' "${sid:-（空）}"
    dim "    uTLS 指纹（fp=chrome）属于客户端参数，服务端没有这个字段；"
    dim "    生成的链接里已带 fp=chrome，无需在服务器上设置"
    [ -z "$sid" ] && warn "short_id 为空，建议填一个随机值（sbopt 不自动改，避免客户端失联）"
  done

  # ---------- Hysteria2 ----------
  for e in "${IDX[@]}"; do
    f=$(printf '%s' "$e" | cut -d'|' -f1)
    i=$(printf '%s' "$e" | cut -d'|' -f2)
    tag=$(printf '%s' "$e" | cut -d'|' -f3)
    type=$(printf '%s' "$e" | cut -d'|' -f4)
    [ "$type" = "hysteria2" ] || continue

    local port obfs up down
    port=$(qjq -r ".inbounds[$i].listen_port // \"-\"" "$f")
    obfs=$(qjq -r ".inbounds[$i].obfs.type // \"\"" "$f")
    up=$(qjq -r ".inbounds[$i].up_mbps // \"未设\"" "$f")
    down=$(qjq -r ".inbounds[$i].down_mbps // \"未设\"" "$f")

    hr; printf '  Hysteria2 入站 [%s]  (%s)\n' "$tag" "$(basename "$f")"
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
        apply_file "$f" "HY2[$tag] 启用 obfs" \
          ".inbounds[$i].obfs = {\"type\":\"salamander\",\"password\":\"$pw\"}" \
          && { ok "混淆密码：$pw"; dim "客户端需同步填写 obfs-password"; changed=1; }
      fi
    fi

    if [ "$port" = "443" ]; then
      if ask "把 Hysteria2 端口从 443 改到 24443？"; then
        apply_file "$f" "HY2[$tag] 端口 443->24443" ".inbounds[$i].listen_port = 24443" \
          && { command -v ufw >/dev/null 2>&1 && ufw allow 24443/udp >/dev/null 2>&1
               ok "别忘了云控制台安全组也放行 24443/udp"
               changed=1; }
      fi
    fi
  done

  if [ "${#IDX[@]}" -gt 2 ]; then
    hr; warn "建议精简入站（当前 ${#IDX[@]} 个）"
    for e in "${IDX[@]}"; do
      printf '       %s  (%s  %s)\n' \
        "$(printf '%s' "$e" | cut -d'|' -f3)" \
        "$(printf '%s' "$e" | cut -d'|' -f4)" \
        "$(printf '%s' "$e" | cut -d'|' -f5)"
    done
    dim "用法：sbopt disable <tag>"
  fi

  [ "$changed" = 0 ] && dim "本次未做任何修改"
  echo
}

# ------------------------------------------- 5. REALITY 伪装站测速选优 ------
cmd_dest() {
  hr; say "REALITY 伪装站候选测速"; hr
  req_pkg curl
  local hosts=(www.microsoft.com www.apple.com swcdn.apple.com
               www.cloudflare.com www.bing.com www.tesla.com
               one.one.one.one dl.google.com)
  printf '  %-24s %-10s %-10s %-6s %s\n' "站点" "TCP连接" "TLS握手" "HTTP" "TLS1.3"
  printf '  %s\n' "$(printf '%.0s-' {1..62})"
  local h c a hv t13 best="" rc13
  for h in "${hosts[@]}"; do
    # 先用 --tlsv1.3 探测；成功即代表支持 TLS1.3
    read -r c a hv < <(
      curl -sI -o /dev/null --max-time 8 --tlsv1.3 \
           -w '%{time_connect} %{time_appconnect} %{http_version}' "https://$h" 2>/dev/null
      echo
    )
    if [ -n "${c:-}" ]; then t13="✓"; else
      read -r c a hv < <(
        curl -sI -o /dev/null --max-time 8 \
             -w '%{time_connect} %{time_appconnect} %{http_version}' "https://$h" 2>/dev/null
        echo
      )
      [ -n "${c:-}" ] && t13="—" || t13="?"
    fi
    [ -z "${c:-}" ] && { printf '  %-24s %s\n' "$h" "不可用"; continue; }
    printf '  %-24s %-10s %-10s %-6s %s\n' "$h" "${c}s" "${a}s" "${hv:-?}" "$t13"
    case "${hv:-?}:$t13" in
      2*:✓) [ -z "$best" ] && best="$h" ;;
    esac
  done
  hr
  [ -n "$best" ] && ok "首选（HTTP/2 + TLS1.3 且排在前面的）：$best"
  dim "换法：sbopt setdest <域名>"
  dim "注意：别选被墙域名，也别选与你落地机同机房/同 CDN 回源过近的站"
  echo
}

# ------------------------------------------------- 6. 生成客户端链接 --------
pubkey_from_priv() {
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
  detect_cfg || { err "未找到配置文件，请先跑 sbopt doctor"; return 1; }
  ensure_jq
  build_index || { err "没有可解析的入站"; return 1; }

  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  [ -n "${ip:-}" ] || ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null)
  [ -n "${ip:-}" ] || { err "无法获取公网 IP"; return 1; }
  ok "服务器 IP：$ip"

  local e f i type tag port
  for e in "${IDX[@]}"; do
    f=$(printf '%s' "$e" | cut -d'|' -f1)
    i=$(printf '%s' "$e" | cut -d'|' -f2)
    tag=$(printf '%s' "$e" | cut -d'|' -f3)
    type=$(printf '%s' "$e" | cut -d'|' -f4)
    port=$(printf '%s' "$e" | cut -d'|' -f5)
    [ "$port" = "-" ] && continue

    case "$type" in
      vless)
        qjq -e ".inbounds[$i].tls.reality.enabled == true" "$f" >/dev/null 2>&1 || continue
        local uuid sni sid priv pub flow
        uuid=$(qjq -r ".inbounds[$i].users[0].uuid // empty" "$f")
        sni=$(qjq -r ".inbounds[$i].tls.server_name // empty" "$f")
        sid=$(qjq -r ".inbounds[$i].tls.reality.short_id[0] // empty" "$f")
        priv=$(qjq -r ".inbounds[$i].tls.reality.private_key // empty" "$f")
        flow=$(qjq -r ".inbounds[$i].users[0].flow // \"xtls-rprx-vision\"" "$f")
        pub=$(pubkey_from_priv "$priv" 2>/dev/null || true)
        [ -z "${pub:-}" ] && { warn "无法自动推导 REALITY 公钥，请用 sing-box generate reality-keypair 重配"; pub="<公钥>"; }
        hr; printf '  [%s] VLESS-REALITY\n' "$tag"
        printf '  vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s-REALITY\n' \
          "$uuid" "$ip" "$port" "$flow" "$sni" "$pub" "$sid" "$tag"
        ;;
      hysteria2)
        local pw sni2 obfst obfsp extra=""
        pw=$(qjq -r ".inbounds[$i].users[0].password // empty" "$f")
        sni2=$(qjq -r ".inbounds[$i].tls.server_name // empty" "$f")
        obfst=$(qjq -r ".inbounds[$i].obfs.type // empty" "$f")
        obfsp=$(qjq -r ".inbounds[$i].obfs.password // empty" "$f")
        [ -n "$obfst" ] && extra="&obfs=${obfst}&obfs-password=${obfsp}"
        hr; printf '  [%s] Hysteria2\n' "$tag"
        printf '  hysteria2://%s@%s:%s?sni=%s&insecure=1%s#%s-HY2\n' \
          "$pw" "$ip" "$port" "$sni2" "$extra" "$tag"
        dim "自签证书用 insecure=1；正式证书请删掉该参数"
        ;;
      trojan)
        local tpw tsni
        tpw=$(qjq -r ".inbounds[$i].users[0].password // empty" "$f")
        tsni=$(qjq -r ".inbounds[$i].tls.server_name // empty" "$f")
        hr; printf '  [%s] Trojan\n' "$tag"
        printf '  trojan://%s@%s:%s?sni=%s&allowInsecure=1#%s\n' "$tpw" "$ip" "$port" "$tsni" "$tag"
        ;;
      tuic)
        local tuuid tpw2 tsni2
        tuuid=$(qjq -r ".inbounds[$i].users[0].uuid // empty" "$f")
        tpw2=$(qjq -r ".inbounds[$i].users[0].password // empty" "$f")
        tsni2=$(qjq -r ".inbounds[$i].tls.server_name // empty" "$f")
        hr; printf '  [%s] TUIC v5\n' "$tag"
        printf '  tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=bbr&allow_insecure=1#%s\n' \
          "$tuuid" "$tpw2" "$ip" "$port" "$tsni2" "$tag"
        ;;
      anytls)
        local apw asni
        apw=$(qjq -r ".inbounds[$i].users[0].password // empty" "$f")
        asni=$(qjq -r ".inbounds[$i].tls.server_name // empty" "$f")
        hr; printf '  [%s] AnyTLS\n' "$tag"
        printf '  anytls://%s@%s:%s?sni=%s&insecure=1#%s\n' "$apw" "$ip" "$port" "$asni" "$tag"
        ;;
      shadowsocks)
        local sm sp
        sm=$(qjq -r ".inbounds[$i].method // empty" "$f")
        sp=$(qjq -r ".inbounds[$i].password // empty" "$f")
        if [ -n "$sm" ] && [ -n "$sp" ]; then
          local b64
          b64=$(printf '%s' "$sm:$sp" | base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '=')
          hr; printf '  [%s] Shadowsocks\n' "$tag"
          printf '  ss://%s@%s:%s#%s\n' "$b64" "$ip" "$port" "$tag"
        fi
        ;;
    esac
  done
  hr
  dim "复制上面链接，v2rayN -> 服务器 -> 从剪贴板导入"
  echo
}

# --------------------------------------------------- 7. 端口 / 启停入站 -----
cmd_port() {
  local key="${1:-}" port="${2:-}"
  [ -n "$key" ] && [ -n "$port" ] || { err "用法：sbopt port <tag|type> <端口>"; return 1; }
  detect_cfg || { err "未找到配置文件"; return 1; }
  ensure_jq
  build_index || { err "没有可解析的入站"; return 1; }

  local loc f i type
  loc=$(locate_inbound "$key") || { err "找不到 tag/type 为 $key 的入站"; return 1; }
  f=$(printf '%s' "$loc" | cut -d'|' -f1)
  i=$(printf '%s' "$loc" | cut -d'|' -f2)
  type=$(qjq -r ".inbounds[$i].type" "$f")

  apply_file "$f" "$key 端口 -> $port" \
    --arg p "$port" "(.inbounds[$i].listen_port) |= (\$p|tonumber)" || return 1

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
  local key="${1:-}"
  [ -n "$key" ] || { err "用法：sbopt disable <tag|type>"; return 1; }
  detect_cfg || { err "未找到配置文件"; return 1; }
  ensure_jq
  build_index || { err "没有可解析的入站"; return 1; }

  local loc f i tag
  loc=$(locate_inbound "$key") || { err "找不到 tag/type 为 $key 的入站"; return 1; }
  f=$(printf '%s' "$loc" | cut -d'|' -f1)
  i=$(printf '%s' "$loc" | cut -d'|' -f2)
  tag=$(qjq -r ".inbounds[$i].tag // \"$key\"" "$f")

  mkdir -p "$DIS"
  local safe
  safe=$(printf '%s' "$tag" | tr '/ ' '__')
  qjq ".inbounds[$i]" "$f" >"$DIS/$safe.json"
  apply_file "$f" "停用入站 [$tag]" "del(.inbounds[$i])" \
    && ok "入站定义已存入 $DIS/$safe.json（可用 enable 恢复）"
}

cmd_enable() {
  local key="${1:-}"
  [ -n "$key" ] || { err "用法：sbopt enable <tag>"; return 1; }
  detect_cfg || { err "未找到配置文件"; return 1; }
  ensure_jq
  local safe
  safe=$(printf '%s' "$key" | tr '/ ' '__')
  [ -f "$DIS/$safe.json" ] || { err "找不到已停用的 [$key]"; return 1; }

  # 回加到原目录的第一个文件（多文件模式）或唯一文件
  local target
  if [ "$CFG_MULTI" = 1 ]; then
    target=$(cfg_files | head -1)
    dim "多文件模式：追加到 $target"
  else
    target="$CFG"
  fi
  apply_file "$target" "恢复入站 [$key]" --slurpfile n "$DIS/$safe.json" '.inbounds += $n' \
    && rm -f "$DIS/$safe.json"
}

# ------------------------------------------------------- 8. 流量守护 --------
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

# ------------------------------------------------------------ 9. 回滚 ------
cmd_rollback() {
  hr; say "可用备份"; hr
  ls -1t "$BK"/* 2>/dev/null | head -10 | nl -w2 -s'. ' | sed 's/^/  /' || { err "没有备份"; return 1; }
  echo
  local t b
  t=$(cat "$BASE/last_target" 2>/dev/null)
  b=$(cat "$BASE/last_backup" 2>/dev/null)
  if [ -z "${b:-}" ] || [ ! -f "$b" ]; then
    err "没有最近一次备份记录"; return 1
  fi
  printf '  目标文件: %s\n  备份文件: %s\n' "${t:-?}" "$b"
  ask "回滚到 $(basename "$b") ?" || return 0
  cp -a "$b" "$t"
  restart_svc && ok "已回滚并重启" || err "重启失败，请手工检查 $t"
}

# ----------------------------------------------------------- 10. 自更新 -----
self_version() { grep -m1 '^# VERSION' "$1" 2>/dev/null | awk '{print $3}'; }

cmd_update() {
  hr; say "从 GitHub 拉取最新版本"; hr
  command -v curl >/dev/null 2>&1 || req_pkg curl
  local self tmp old new
  self=$(readlink -f "$0" 2>/dev/null || echo "$0")
  tmp=$(mktemp /tmp/sbopt.XXXXXX)

  local got=0 m
  for m in "${MIRRORS[@]}"; do
    dim "尝试 $m"
    if curl -fsSL --max-time 25 "$m/sb-opt.sh" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      got=1; ok "下载成功：$m"; break
    fi
  done
  if [ "$got" = 0 ]; then
    err "所有下载源都失败（raw / jsdelivr / gitmirror / ghfast）"
    dim "请检查服务器出网，或稍后重试；也可手工下载后覆盖 /root/sb-opt/sb-opt.sh"
    rm -f "$tmp"; return 1
  fi
  if ! bash -n "$tmp" 2>/dev/null; then
    err "下载的版本语法校验失败，已放弃"; rm -f "$tmp"; return 1
  fi
  # 完整性：末尾必须有 __END_SBOPT__ 标记，否则是被截断的半截文件
  if ! grep -q '^# __END_SBOPT__' "$tmp" || [ -z "$(self_version "$tmp")" ]; then
    err "下载的文件不完整（缺结束标记），已放弃。稍后重试或检查网络"
    rm -f "$tmp"; return 1
  fi

  old=$(self_version "$self"); new=$(self_version "$tmp")
  printf '  当前版本 : %s\n  远端版本 : %s\n' "${old:-?}" "${new:-?}"
  if [ "$old" = "$new" ]; then ok "已是最新，无需更新"; rm -f "$tmp"; return 0; fi
  cp -a "$self" "$BASE/sb-opt.sh.old"
  install -m 755 "$tmp" "$self"
  rm -f "$tmp"
  ok "已更新 ${old:-?} -> ${new:-?}"
  dim "旧版备份：$BASE/sb-opt.sh.old"
  echo
}

# --------------------------------------------- 12. 更换 REALITY 伪装站 --------
cmd_setdest() {
  local host="${1:-}"
  hr; say "更换 REALITY 伪装站"; hr
  if [ -z "$host" ]; then
    dim "用法：sbopt setdest <域名>"
    dim "先用 sbopt dest 测速，再指定；实测推荐 www.cloudflare.com / one.one.one.one"
    return 1
  fi

  detect_cfg || { err "未找到配置"; return 1; }
  detect_svc
  ensure_jq || return 1
  build_index || { err "没有可解析的入站"; return 1; }

  req_pkg curl
  local probe
  probe=$(curl -sI -o /dev/null --max-time 8 --tlsv1.3 "https://$host" 2>/dev/null && echo ok13)
  if [ -n "${probe:-}" ]; then
    ok "$host 可达，支持 TLS1.3"
  elif curl -sI -o /dev/null --max-time 8 "https://$host" >/dev/null 2>&1; then
    warn "$host 可达，但 TLS1.3 探测失败（可能被中间设备干扰），REALITY 建议 TLS1.3"
  else
    err "$host 从本机不可达，不能作为伪装站"
    dim "换一个站点：sbopt dest 会列出可用候选"
    return 1
  fi

  local e f i tag type changed=0
  for e in "${IDX[@]}"; do
    f=$(printf '%s' "$e" | cut -d'|' -f1)
    i=$(printf '%s' "$e" | cut -d'|' -f2)
    tag=$(printf '%s' "$e" | cut -d'|' -f3)
    type=$(printf '%s' "$e" | cut -d'|' -f4)
    [ "$type" = "vless" ] || continue
    qjq -e ".inbounds[$i].tls.reality.enabled == true" "$f" >/dev/null 2>&1 || continue

    hr; printf '  [%s] 当前：%s\n' "$tag" \
      "$(qjq -r ".inbounds[$i].tls.reality.handshake.server // .inbounds[$i].tls.server_name // \"-\"" "$f")"
    if ask "把 handshake.server 与 server_name 都改成 $host ?"; then
      apply_file "$f" "REALITY[$tag] dest -> $host" \
        --arg h "$host" \
        ".inbounds[$i].tls.reality.handshake.server = \$h | .inbounds[$i].tls.server_name = \$h" \
        && changed=$((changed+1))
    fi
  done

  if [ "$changed" -gt 0 ]; then
    echo
    warn "客户端 SNI 已改变，旧链接会失效 -> 执行 sbopt links 重新导入"
  else
    dim "未做修改"
  fi
  echo
}

# ------------------------------------------- 10.5 JSONC 规范化（修复 jq） ----
cmd_fixjson() {
  hr; say "JSONC 规范化"; hr
  detect_cfg || { err "未找到配置，请先跑 sbopt doctor"; return 1; }
  detect_svc && dim "服务：$SVC" || warn "未探测到 systemd 服务，重启可能失败"
  ensure_jq || return 1

  local -a bad=()
  local f
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    jq -e . "$f" >/dev/null 2>&1 || bad+=("$f")
  done < <(cfg_files)

  if [ ${#bad[@]} -eq 0 ]; then ok "所有文件都是严格 JSON，无需处理"; return 0; fi

  warn "以下 ${#bad[@]} 个文件不是严格 JSON（含 // 注释 / 块注释 / 尾逗号）"
  dim "sing-box 自己的解析器兼容它们，所以能正常加载；jq 严格，读不了"
  for f in "${bad[@]}"; do dim "  $(basename "$f") ($(stat -c %s "$f" 2>/dev/null) B)"; done
  echo
  ask "原地规范化（去掉注释，原文件先备份）？" || return 0

  local stage tmp out rc
  local -a map=()
  stage=$(mktemp -d)
  cp -a "$CFG"/. "$stage"/ 2>/dev/null

  for f in "${bad[@]}"; do
    tmp=$(mktemp "/tmp/fixjson.XXXXXX")
    if _sanitize_jsonc "$f" "$tmp" && jq -e . "$tmp" >/dev/null 2>&1; then
      map+=("$f|$tmp")
      cp "$tmp" "$stage/$(basename "$f")"
    else
      rm -f "$tmp"
      err "$(basename "$f")：规范化失败，保持原样"
    fi
  done

  if [ ${#map[@]} -eq 0 ]; then
    err "没有可用的规范化结果"; rm -rf "$stage"; return 1
  fi

  if detect_bin; then
    out=$("$SB_BIN" check -C "$stage" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
      err "规范化后的配置未通过 sing-box check，已放弃（原文件未改动）"
      printf '%s\n' "$out" | head -8 | sed 's/^/       /'
      rm -rf "$stage"
      while IFS='|' read -r _ tmp; do rm -f "$tmp"; done < <(printf '%s\n' "${map[@]}")
      return 1
    fi
    ok "规范化后的配置通过 sing-box check"
  else
    warn "未找到 sing-box 二进制，跳过检查（仍然先备份）"
  fi

  mkdir -p "$BK"
  local -a pairs=()
  local b
  while IFS='|' read -r f tmp; do
    b="$BK/$(date +%Y%m%d-%H%M%S)-$(basename "$f")"
    cp -a "$f" "$b"
    pairs+=("$f|$b|$tmp")
  done < <(printf '%s\n' "${map[@]}")

  local src bk new
  while IFS='|' read -r src bk new; do
    cat "$new" >"$src"
  done < <(printf '%s\n' "${pairs[@]}")

  if restart_svc; then
    ok "已规范化并重启服务：${#pairs[@]} 个文件"
    while IFS='|' read -r _ _ new; do rm -f "$new"; done < <(printf '%s\n' "${pairs[@]}")
    rm -rf "$stage"
    dim "注释已被去掉；如需保留原样，备份在 $BK"
    return 0
  fi

  err "重启失败，正在逐个恢复备份"
  dim "最近日志："; svc_last_error
  while IFS='|' read -r src bk _; do
    cp -a "$bk" "$src"
  done < <(printf '%s\n' "${pairs[@]}")
  restart_svc && ok "已全部恢复并重启" || err "恢复后仍未启动，请手工检查"
  rm -rf "$stage"
  return 1
}

# --------------------------------------------------- 11. 配置文件逐个检查 ---
cmd_files() {
  hr; say "配置文件逐个检查"; hr
  detect_cfg || { err "未找到配置目录，请先跑 sbopt doctor"; return 1; }
  ensure_jq || return 1
  dim "配置：$CFG（$([ "$CFG_MULTI" = 1 ] && echo 多文件目录 || echo 单文件)）"
  echo
  printf '  %-40s %8s  %-9s %s\n' "文件" "大小" "JSON" "入站（type:port）"
  printf '  %s\n' "$(printf '%.0s-' {1..78})"

  local f size st types err1 bad=0
  while IFS= read -r f; do
    size=$(stat -c %s "$f" 2>/dev/null || echo 0)
    err1=$(jq -e . "$f" 2>&1 >/dev/null | head -1)
    if [ -z "$err1" ]; then
      st="OK"
      types=$(qjq -r '[.inbounds[]? | "\(.type):\(.listen_port // "-")"] | join(", ")' "$f" 2>/dev/null)
      [ -z "$types" ] && types="（无 inbounds）"
      printf '  %-40s %8s  %-9s %s\n' "$(basename "$f")" "$size" "$st" "$types"
    else
      bad=$((bad+1))
      printf '  %-40s %8s  %s%s%s %s\n' "$(basename "$f")" "$size" "$c_r" "FAIL" "$c_0" "${err1:0:40}"
    fi
  done < <(cfg_files)

  echo
  if [ "$bad" -gt 0 ]; then
    warn "$bad 个文件不是合法的 JSON，sing-box 能跑但不代表它们被加载了"
    dim "常见原因：文件里混入了注释 // 或 /* */、结尾多了逗号、被编辑器插入 BOM"
    dim "修法：把该文件贴给脚本作者，或手工删掉注释与尾逗号后 systemctl restart sing-box"
  else
    ok "所有文件 JSON 合法"
  fi

  # 重复端口 / 重复 tag 检查
  local dup_port dup_tag
  dup_port=$(build_index >/dev/null 2>&1; for e in "${IDX[@]}"; do printf '%s\n' "$(printf '%s' "$e" | cut -d'|' -f5)"; done \
             | grep -v '^-$' | sort | uniq -d | tr '\n' ' ')
  dup_tag=$(build_index >/dev/null 2>&1; for e in "${IDX[@]}"; do printf '%s\n' "$(printf '%s' "$e" | cut -d'|' -f3)"; done \
            | sort | uniq -d | tr '\n' ' ')
  [ -n "${dup_port// /}" ] && warn "端口重复：$dup_port"
  [ -n "${dup_tag// /}" ] && warn "tag 重复：$dup_tag（disable 时只能命中第一个）"
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
    9) 诊断          配置探测失败时用，输出各来源原始结果
   10) 文件检查      逐个校验配置 JSON 与入站端口，抓漏读
   11) 规范化 JSONC  把带注释的配置文件转成严格 JSON（jq 可读）
   12) 换伪装站      把 REALITY 的 handshake/SNI 换成指定域名
    0) 退出
${c_d}
  提示：体检报「未找到配置」时，先跑 9
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
      9) cmd_doctor ;;
      10) cmd_files ;;
      11) cmd_fixjson ;;
      12) shift 2>/dev/null; read -rp "  伪装站域名: " _h </dev/tty; cmd_setdest "$_h" ;;
      0|q) exit 0 ;;
      *) ;;
    esac
    echo; read -rp "  回车继续..." _ </dev/tty || exit 0
  done
}

usage() {
  cat <<'EOF'
sb-opt —— sing-box / xray 一体机优化工具

  sbopt                 交互菜单（推荐从这里开始）
  sbopt doctor          配置探测诊断（找不到配置时先跑）
  sbopt audit           只读体检
  sbopt sys             系统层优化（BBR + sysctl + swap + 句柄）
  sbopt tune            配置层调参（REALITY 指纹 / HY2 混淆端口）
  sbopt dest            REALITY 伪装站测速
  sbopt links           生成 vless:// 与 hysteria2:// 链接
  sbopt traffic         流量统计与每日提醒
  sbopt rollback        回滚最近一次备份
  sbopt update          从 GitHub 拉取最新版
  sbopt version         查看当前版本

  sbopt port <tag|type> <端口>   例如：sbopt port hysteria2 24443
  sbopt disable <tag|type>       例如：sbopt disable tuic
  sbopt enable <tag>             恢复被停用的入站
EOF
}

# ------------------------------------------------------------ 入口 --------
need_root
mkdir -p "$BASE"
case "${1:-}" in
  doctor)   cmd_doctor ;;
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
  files)    cmd_files ;;
  fixjson)  cmd_fixjson ;;
  setdest)  shift; cmd_setdest "${1:-}" ;;
  update)   cmd_update ;;
  version|-v) self_version "${BASH_SOURCE[0]}" ;;
  menu|"")  menu ;;
  *)        usage ;;
esac

# __END_SBOPT__  ← 完整性标记，缺失说明文件被截断，请重新安装
