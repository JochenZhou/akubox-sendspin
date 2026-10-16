#!/usr/bin/env bash
# ==============================================================================
#  给 AkuBox 的屏幕显示程序 showtime 加"黑胶播放页 + 时钟页"
#
#  用法: sudo bash install-showtime-nowplaying.sh [选项]
#     --no-backup   不备份现有二进制
#     -y            不交互确认
#
#  做的事:
#     1. 装编译依赖（freetype / libpng / libcurl 开发包）
#     2. 把 patches/showtime-nowplaying.patch 应用到 /opt/aku/showtime/showtime.c
#     3. 编译并替换二进制，重启 showtime 服务
#
#  依赖 akubox-sendspin 的客户端补丁 0003（把当前曲目写到
#  /var/lib/sendspin-client/nowplaying）。没装那个补丁时本程序只是永远显示时钟。
# ==============================================================================
set -eu

SHOWTIME_DIR="/opt/aku/showtime"
SRC="${SHOWTIME_DIR}/showtime.c"
BIN="${SHOWTIME_DIR}/showtime"
SERVICE="showtime"
NOWPLAYING="/var/lib/sendspin-client/nowplaying"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="${SCRIPT_DIR}/patches/showtime-nowplaying.patch"

DO_BACKUP=1
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-backup) DO_BACKUP=0; shift ;;
    -y|--yes)    ASSUME_YES=1; shift ;;
    -h|--help)   sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '[✓] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[✗] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行"
[ -f "$SRC" ] || die "未找到 ${SRC} —— 这台设备的显示程序不是 showtime？"
[ -f "$PATCH" ] || die "未找到补丁 ${PATCH}"

echo "======================================================================"
echo "  AkuBox showtime 显示界面（黑胶播放页 + 时钟页）"
echo "======================================================================"

log "安装编译依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || warn "apt-get update 失败，继续"
apt-get install -y --no-install-recommends \
  libfreetype-dev libpng-dev libcurl4-openssl-dev pkg-config >/dev/null || die "依赖安装失败"
ok "依赖就绪"

if grep -q "NOWPLAYING_PATH" "$SRC"; then
  log "补丁已应用过，跳过"
else
  log "应用补丁"
  cd "$SHOWTIME_DIR"
  patch -p1 --dry-run < "$PATCH" >/dev/null || die "补丁无法干净应用（showtime.c 版本不同？）"
  [ "$DO_BACKUP" -eq 1 ] && cp -a "$SRC" "${SRC}.pre-nowplaying"
  patch -p1 < "$PATCH" >/dev/null
  ok "补丁已应用（原文件备份为 showtime.c.pre-nowplaying）"
fi

log "编译"
CFLAGS="$(pkg-config --cflags freetype2 libpng libcurl)"
LIBS="$(pkg-config --libs freetype2 libpng libcurl)"
cd "$SHOWTIME_DIR"
# shellcheck disable=SC2086
gcc -O2 -Wall $CFLAGS -o showtime.new showtime.c $LIBS -lz -lm || die "编译失败"
ok "编译完成: $(ls -l showtime.new | awk '{print $5}') 字节"

log "部署"
if systemctl is-active --quiet "$SERVICE"; then
  systemctl stop "$SERVICE"
  sleep 1
fi
# 运行中的二进制被占用，必须先停服务再覆盖（否则 Text file busy）
[ "$DO_BACKUP" -eq 1 ] && [ ! -f "${BIN}.pre-nowplaying" ] && cp -a "$BIN" "${BIN}.pre-nowplaying"
cp -a showtime.new "$BIN"
chmod 0755 "$BIN"
systemctl start "$SERVICE"
sleep 4
systemctl is-active --quiet "$SERVICE" || die "服务未能启动，请查看 journalctl -u ${SERVICE}"

ok "showtime 已运行新版"
echo
cat <<EOF
下一步：
  · 播放一首歌，屏幕应显示旋转的黑胶封面（不显示歌名）
  · 暂停或停止播放会立即停转并停在当前角度；停止满 5 秒后回到时钟界面

回滚：
  cp -a ${BIN}.pre-nowplaying ${BIN} && systemctl restart ${SERVICE}
  cp -a ${SRC}.pre-nowplaying ${SRC}

数据来源：${NOWPLAYING}
  由 akubox-sendspin 的补丁 0003 写出。若该文件不存在，本程序只显示时钟。
EOF
