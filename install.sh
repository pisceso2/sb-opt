#!/usr/bin/env bash
# ============================================================================
#  install.sh —— sb-opt 一键安装 / 升级
#
#  首次安装：
#    curl -fsSL https://raw.githubusercontent.com/pisceso2/sb-opt/main/install.sh | bash
#
#  以后升级（任选其一）：
#    1) 重跑上面那条命令
#    2) sbopt update
#    3) bash /root/sb-opt/sb-opt.sh update
# ============================================================================

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/pisceso2/sb-opt/main"
SELF_URL="$REPO_RAW/sb-opt.sh"
DEST="/root/sb-opt/sb-opt.sh"
BIN="/usr/local/bin/sbopt"

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_0=$'\e[0m'
ok()   { printf '%s OK %s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s !! %s %s\n' "$c_y" "$c_0" "$*"; }
err()  { printf '%s XX %s %s\n' "$c_r" "$c_0" "$*" >&2; }

[ "$(id -u)" = 0 ] || { err "请用 root 运行：curl -fsSL <url> | sudo bash"; exit 1; }

command -v curl >/dev/null 2>&1 || {
  warn "缺少 curl，正在安装"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq curl
}

echo ">>> 下载 sb-opt.sh"
mkdir -p /root/sb-opt
TMP=$(mktemp /tmp/sbopt.XXXXXX)
curl -fsSL --max-time 60 "$SELF_URL" -o "$TMP" || { err "下载失败"; rm -f "$TMP"; exit 1; }

echo ">>> 语法校验"
bash -n "$TMP" || { err "下载的文件语法有误，未安装"; rm -f "$TMP"; exit 1; }

if [ -f "$DEST" ]; then
  OLD=$(grep -m1 '^# VERSION' "$DEST" | awk '{print $3}')
  cp -a "$DEST" "/root/sb-opt/sb-opt.sh.old"
  ok "旧版本 ${OLD:-?} 已备份到 /root/sb-opt/sb-opt.sh.old"
fi

install -m 755 "$TMP" "$DEST"
rm -f "$TMP"
ok "已安装到 $DEST"

ln -sf "$DEST" "$BIN"
ok "已创建命令 sbopt -> $BIN"

NEW=$(grep -m1 '^# VERSION' "$DEST" | awk '{print $3}')
echo
echo "安装完成，版本 ${NEW:-unknown}"
echo
echo "  运行菜单        : sbopt"
echo "  只体检          : sbopt audit"
echo "  系统优化        : sbopt sys"
echo "  配置调参        : sbopt tune"
echo "  生成客户端链接  : sbopt links"
echo "  以后升级        : sbopt update"
echo