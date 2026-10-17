#!/usr/bin/env bash
# ==============================================================================
#  给 AkuBox 的屏幕显示程序 showtime 加"黑胶播放页 + 时钟页"
#
#  用法: sudo bash install-showtime-nowplaying.sh [选项]
#     --bin <路径|URL>   直接安装已编译好的 showtime 二进制（跳过打补丁与编译）
#     --force-build      忽略预编译产物，强制从源码编译
#     --no-backup        不备份现有二进制
#     -y                 不交互确认
#
#  两种安装方式（自动选择）:
#    A. 预编译：--bin 指定，或把二进制放到 showtime/prebuilt/showtime.armv7
#       —— 约 5 秒，不需要厂商源码，也不需要 gcc 开发包
#    B. 源码编译：没有预编译产物时走这条
#       —— 需要厂商源码 /opt/aku/showtime/showtime.c 与编译依赖
#
#  预编译产物只适用于**同型号**设备（同屏 + 同 glibc 与同一批运行库）。
#  本仓库不附带厂商二进制；--bin 指向的文件请自行准备（从另一台同型号
#  AkuBox 复制，或你自己编译的产物）。
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
PREBUILT_DEFAULT="${SCRIPT_DIR}/prebuilt/showtime.armv7"

MODE=""                 # bin | build（留空=自动选择）
BIN_SRC=""
DO_BACKUP=1
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --bin)         MODE=bin; BIN_SRC="${2:?--bin 需要路径或 URL}"; shift 2 ;;
    --force-build) MODE=build; shift ;;
    --no-backup)   DO_BACKUP=0; shift ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    -h|--help)     sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '[✓] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[✗] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行"

# ---- 自动选择模式 ----
if [ -z "$MODE" ]; then
  if [ -f "$PREBUILT_DEFAULT" ]; then
    MODE=bin; BIN_SRC="$PREBUILT_DEFAULT"
    log "发现预编译产物: ${PREBUILT_DEFAULT}（用 --force-build 可改为源码编译）"
  else
    MODE=build
  fi
fi

echo "======================================================================"
echo "  AkuBox showtime 显示界面（黑胶播放页 + 时钟页）  模式: ${MODE}"
echo "======================================================================"

STAGE=""
TMP_STAGE=""

StageCleanup() { [ -n "${TMP_STAGE:-}" ] && [ -f "${TMP_STAGE:-}" ] && rm -f "$TMP_STAGE"; }
trap StageCleanup EXIT

# ---- 校验二进制能不能在本机跑 ----
validate_bin() {
  local f="$1"
  [ -s "$f" ] || die "二进制为空: ${f}"
  if command -v file >/dev/null 2>&1; then
    file "$f" | grep -qiE 'ELF 32-bit.*ARM' || die "不是 32 位 ARM ELF：$(file -b "$f")"
  fi
  chmod 0755 "$f"
  local missing
  missing="$(ldd "$f" 2>/dev/null | grep 'not found' || true)"
  if [ -n "$missing" ]; then
    warn "缺少运行库，尝试安装: ${missing}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    apt-get install -y --no-install-recommends libfreetype6 libpng16-16 libcurl4 zlib1g >/dev/null 2>&1 || true
    missing="$(ldd "$f" 2>/dev/null | grep 'not found' || true)"
    [ -z "$missing" ] || die "缺少运行库且自动安装失败：${missing}"
  fi
  ok "二进制可用: $(md5sum "$f" | cut -c1-12) / $(stat -c%s "$f") 字节"
}

# ---- 取二进制（本地路径或 URL）----
fetch_bin() {
  local src="$1"
  TMP_STAGE="$(mktemp /tmp/showtime-prebuilt.XXXXXX)"
  case "$src" in
    http://*|https://*)
      log "下载预编译二进制: ${src}"
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 20 -o "$TMP_STAGE" "$src" || die "下载失败"
      elif command -v wget >/dev/null 2>&1; then
        wget -q -T 20 -O "$TMP_STAGE" "$src" || die "下载失败"
      else
        die "缺少 curl / wget，无法下载"
      fi
      ;;
    *)
      [ -f "$src" ] || die "找不到二进制: ${src}"
      cp -a "$src" "$TMP_STAGE"
      ;;
  esac
  STAGE="$TMP_STAGE"
  validate_bin "$STAGE"
}

# ============================ A. 预编译安装 ============================
if [ "$MODE" = bin ]; then
  log "使用预编译二进制安装（跳过打补丁与编译）"
  [ -n "$BIN_SRC" ] || die "预编译模式需要 --bin 或 showtime/prebuilt/showtime.armv7"
  fetch_bin "$BIN_SRC"

  log "部署"
  if systemctl is-active --quiet "$SERVICE"; then
    systemctl stop "$SERVICE"; sleep 1
  fi
  [ "$DO_BACKUP" -eq 1 ] && [ ! -f "${BIN}.pre-nowplaying" ] && cp -a "$BIN" "${BIN}.pre-nowplaying"
  cp -a "$STAGE" "$BIN"
  chmod 0755 "$BIN"
  systemctl start "$SERVICE"
  sleep 4
  systemctl is-active --quiet "$SERVICE" || die "服务未能启动，请查看 journalctl -u ${SERVICE}"

  ok "showtime 已运行新版本（预编译）"
  echo
  cat <<EOF
下一步：
  · 播放一首歌，屏幕应显示旋转的黑胶封面（不显示歌名）
  · 暂停或停止播放会立即停转并停在当前角度；停止满 5 秒后回到时钟界面

回滚：
  cp -a ${BIN}.pre-nowplaying ${BIN} && systemctl restart ${SERVICE}

数据来源：${NOWPLAYING}
  由 akubox-sendspin 的补丁 0003 写出。若该文件不存在，本程序只显示时钟。
EOF
  exit 0
fi

# ============================ B. 源码编译 ============================
[ -f "$SRC" ] || {
  warn "本机只有编译好的 showtime 二进制、没有厂商源码 —— 无法从源码编译"
  log "  改用预编译安装（推荐）："
  log "    sudo bash $0 --bin /path/to/showtime.armv7"
  log "  或把二进制放到: ${PREBUILT_DEFAULT}"
  log "  预编译产物可从另一台同型号 AkuBox 复制："
  log "    scp root@<另一台>:/opt/aku/showtime/showtime /tmp/showtime.armv7"
  die "缺少 ${SRC}"
}
[ -f "$PATCH" ] || die "未找到补丁 ${PATCH}"

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
validate_bin "$SHOWTIME_DIR/showtime.new"

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

ok "showtime 已运行新版本（源码编译）"
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
