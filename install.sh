#!/usr/bin/env bash
# ==============================================================================
#  AkuBox Sendspin Client 一键安装脚本
#
#  在 AkuBox（或其它 ARMv7 / aarch64 Debian / Ubuntu 音箱设备）上从源码编译并安装
#  TermeHansen/sendspin-client，让它作为 Music Assistant 官方附加组件的本地播放器
#  （MA 主动发现并连接，无需修改 MA 服务端）。
#
#  内置 6 处与 Music Assistant 2.10.x（aiosendspin 9.1.1）的协议兼容补丁。
#
#  用法:
#     sudo bash install.sh
#     sudo bash install.sh --name "卧室 AkuBox"
#     sudo bash install.sh --build-only          # 只编译不安装，用于验证
#
#  全部选项见 --help
# ==============================================================================
set -euo pipefail

# ---------------------------- 版本锁定（可复现） ----------------------------
UPSTREAM="https://github.com/TermeHansen/sendspin-client.git"
CLIENT_REF="b3d209f93bdd2f6e88174963dc2aeda36c2baf63"   # sendspin-client v0.5.2 (2026-10-14)
CPP_REF="81216ba634d5b396862de2ef545fc1b17ffeb3f3"      # sendspin-cpp   v0.9.4

# 本仓库（用于在单文件方式运行时拉取补丁）
REPO_SLUG="JochenZhou/akubox-sendspin"
REPO_BRANCH="main"

# 国内镜像（按顺序尝试）
GIT_MIRRORS=(
  "https://ghfast.top/https://github.com/"
  "https://gh.kejilion.pro/github.com/"
)
RAW_MIRRORS=(
  "https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_BRANCH}"
  "https://ghfast.top/https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_BRANCH}"
  "https://cdn.jsdelivr.net/gh/${REPO_SLUG}@${REPO_BRANCH}"
)

# ---------------------------- 默认参数 ----------------------------
DEVICE_NAME="$(hostname 2>/dev/null || echo AkuBox)"
AUDIO_DEVICE=""
ALSA_MIXER=""
INSTALL_DIR="/opt/sendspin-client"
BIN_PATH="/usr/bin/sendspin-client"
CONF_DIR="/etc/sendspin-client"
STATE_DIR="/var/lib/sendspin-client"
SERVICE_NAME="sendspin-client"
RUN_USER="sendspin"
JOBS=1
BUILD_ONLY=0
SKIP_LEGACY_PATCH=0
FREE_AUDIO=0
ASSUME_YES=0
PATCH_DIR=""

# 已知会占用声卡、与 sendspin 冲突的厂商服务
AUDIO_CONFLICTS=("linux-voice-assistant" "showtime")

# ---------------------------- 输出工具 ----------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_OFF=""
fi
log()  { printf '%s[*]%s %s\n'  "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[✓]%s %s\n'  "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s[✗]%s %s\n'  "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "------------------------------------------------------------------------"; }

usage() {
  cat <<EOF
AkuBox Sendspin Client 安装脚本

用法: sudo bash install.sh [选项]

选项:
  --name <名称>          设备显示名（默认: 当前主机名）  当前: ${DEVICE_NAME}
  --audio-device <设备>  ALSA 播放设备（默认自动探测 plughw:N,0）
  --mixer <card:控件>    ALSA 硬件混音器（默认自动探测，如 0:Power Amplifier）
  --dir <路径>           源码目录（默认: ${INSTALL_DIR}）
  --jobs <N>             编译并行度（默认: ${JOBS}；AkuBox 单核建议 1）
  --patch-dir <路径>     指定补丁目录（默认: 脚本同级 patches/，否则自动下载）
  --build-only           只克隆+打补丁+编译，不安装、不写 systemd
  --skip-legacy-ma-patch 不应用 MA 2.10.x 兼容补丁（仅当 MA >= 2.11 / aiosendspin 10.x）
  --free-audio           安装前停止并禁用会抢占声卡的厂商服务（VAS / showtime）
  -y, --yes              不交互确认
  -h, --help             显示本帮助

示例:
  sudo bash install.sh --name "卧室 AkuBox"
  sudo bash install.sh --free-audio -y
EOF
}

# ---------------------------- 参数解析 ----------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --name)                DEVICE_NAME="${2:?--name 需要参数}"; shift 2 ;;
    --audio-device)        AUDIO_DEVICE="${2:?--audio-device 需要参数}"; shift 2 ;;
    --mixer)               ALSA_MIXER="${2:?--mixer 需要参数}"; shift 2 ;;
    --dir)                 INSTALL_DIR="${2:?--dir 需要参数}"; shift 2 ;;
    --jobs)                JOBS="${2:?--jobs 需要参数}"; shift 2 ;;
    --patch-dir)           PATCH_DIR="${2:?--patch-dir 需要参数}"; shift 2 ;;
    --build-only)          BUILD_ONLY=1; shift ;;
    --skip-legacy-ma-patch) SKIP_LEGACY_PATCH=1; shift ;;
    --free-audio)          FREE_AUDIO=1; shift ;;
    -y|--yes)              ASSUME_YES=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

# ---------------------------- 前置检查 ----------------------------
preflight() {
  hr; log "环境检查"
  [ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo bash install.sh）"

  local arch; arch="$(uname -m)"
  case "$arch" in
    armv7l|armv6l|aarch64|arm64) ok "架构 $arch 受支持" ;;
    *) warn "架构 $arch 未验证，继续尝试" ;;
  esac

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    ok "系统 ${PRETTY_NAME:-unknown}"
    case "${ID:-}" in
      ubuntu|debian|raspbian) ;;
      *) warn "非 Debian 系发行版，apt 依赖安装可能失败" ;;
    esac
  fi

  local cores; cores="$(nproc 2>/dev/null || echo 1)"
  local mem_mb; mem_mb="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
  log "CPU ${cores} 核 / 内存 ${mem_mb} MB"
  if [ "$cores" -le 1 ] && [ "$JOBS" -gt 1 ]; then
    warn "单核设备，已将编译并行度调整为 1"
    JOBS=1
  fi

  command -v systemctl >/dev/null || die "缺少 systemd，本脚本不适用"
  ok "systemd 可用"

  # 源码 + 编译产物约需 300 MB；空间不足会在编译中途失败，提前拦住
  local parent="$INSTALL_DIR"
  while [ ! -d "$parent" ] && [ "$parent" != "/" ]; do parent="$(dirname "$parent")"; done
  local avail_kb
  avail_kb="$(df -Pk "$parent" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
  if [ -n "$avail_kb" ] && [ "$avail_kb" -lt 512000 ]; then
    die "磁盘空间不足：$parent 仅剩 $((avail_kb/1024)) MB，建议至少 800 MB"
  fi
  ok "磁盘空间充足（$parent 剩余 $((avail_kb/1024)) MB）"
}

# ---------------------------- 依赖安装 ----------------------------
install_deps() {
  hr; log "安装编译依赖"
  export DEBIAN_FRONTEND=noninteractive
  local pkgs=(git cmake pkg-config build-essential libasound2-dev
              libavahi-compat-libdnssd-dev avahi-daemon)
  local missing=()
  local p
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    ok "依赖已齐备"
    return 0
  fi
  log "需要安装: ${missing[*]}"
  apt-get update -qq || warn "apt-get update 失败，继续尝试安装"
  apt-get install -y --no-install-recommends "${missing[@]}" || die "依赖安装失败"
  ok "依赖安装完成"
}

# ---------------------------- 声卡探测 ----------------------------
detect_audio_device() {
  local card
  card="$(aplay -l 2>/dev/null | sed -n 's/^card \([0-9][0-9]*\):.*/\1/p' | head -1)"
  [ -n "$card" ] || return 1
  printf 'plughw:%s,0' "$card"
}

detect_mixer() {
  local card="${1:-0}" ctl
  for ctl in "Power Amplifier" Master PCM Digital Speaker Headphone Playback; do
    if amixer -c "$card" scontrols 2>/dev/null | grep -qF "'${ctl}'"; then
      printf '%s:%s' "$card" "$ctl"
      return 0
    fi
  done
  return 1
}

resolve_audio() {
  hr; log "探测音频设备"
  if [ -z "$AUDIO_DEVICE" ]; then
    if AUDIO_DEVICE="$(detect_audio_device)"; then
      ok "播放设备: ${AUDIO_DEVICE}（自动探测）"
    else
      AUDIO_DEVICE="plughw:0,0"
      warn "未探测到声卡，回退到 ${AUDIO_DEVICE}"
    fi
  else
    ok "播放设备: ${AUDIO_DEVICE}（手动指定）"
  fi

  if [ -z "$ALSA_MIXER" ]; then
    if ALSA_MIXER="$(detect_mixer 0)"; then
      ok "硬件混音器: ${ALSA_MIXER}（自动探测）"
    else
      ALSA_MIXER=""
      warn "未探测到可用混音器，将不使用硬件音量控制"
    fi
  else
    ok "硬件混音器: ${ALSA_MIXER}（手动指定）"
  fi

  if aplay -l 2>/dev/null | grep -q '^card'; then
    ok "声卡列表:"
    aplay -l 2>/dev/null | sed -n 's/^\(card [0-9]*:.*\)/    \1/p'
  fi
}

show_audio_holders() {
  [ -d /dev/snd ] || return 0
  command -v fuser >/dev/null 2>&1 || return 0
  local holders=""
  holders="$(fuser -v /dev/snd/* 2>&1 | awk '/F\.\.\.\./ {print $NF}' | sort -u || true)"
  if [ -n "$holders" ]; then
    warn "当前占用声卡的进程: $(echo "$holders" | tr '\n' ' ')"
  fi
}

# ---------------------------- 释放声卡 ----------------------------
free_audio() {
  local svc
  for svc in "${AUDIO_CONFLICTS[@]}"; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
      if [ "$FREE_AUDIO" -eq 1 ]; then
        log "停止并禁用 ${svc}.service"
        systemctl stop "$svc" >/dev/null 2>&1 || true
        systemctl disable "$svc" >/dev/null 2>&1 || true
      else
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
          warn "${svc}.service 正在运行，会抢占声卡。加 --free-audio 可自动停止并禁用它"
        fi
      fi
    fi
  done
}

# ---------------------------- 源码获取 ----------------------------
prepare_source_dir() {
  local src="$1"
  if [ -d "${src}/.git" ]; then
    log "复用已有仓库: ${src}"
    # 丢弃本地改动（含旧补丁），保证每次都是「锁定提交 + 重新打补丁」的确定状态
    git -C "$src" checkout --quiet --force "$CLIENT_REF" 2>/dev/null || true
    return 0
  fi
  if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null || true)" ]; then
    local bak="${src}.bak.$(date +%Y%m%d%H%M%S)"
    warn "${src} 已存在且不是 git 仓库，移动到 ${bak}"
    mv "$src" "$bak"
  fi
  return 0
}

try_fetch_sources() {
  local mirror="$1" src="$2"
  local -a cfg=()
  [ -n "$mirror" ] && cfg=(-c "url.${mirror}.insteadOf=https://github.com/")

  if [ ! -d "${src}/.git" ]; then
    rm -rf "$src"
    git "${cfg[@]}" clone --quiet "$UPSTREAM" "$src" || return 1
  fi
  git -C "$src" "${cfg[@]}" fetch --quiet origin 2>/dev/null || return 1
  # --force：确保落到锁定提交并清掉上一次的补丁残留，使本脚本可重复执行
  git -C "$src" "${cfg[@]}" checkout --quiet --force "$CLIENT_REF" || return 1
  git -C "$src" "${cfg[@]}" submodule sync --recursive >/dev/null 2>&1 || true
  git -C "$src" "${cfg[@]}" submodule update --init --recursive --force --quiet || return 1
  return 0
}

fetch_sources() {
  hr; log "获取上游源码（锁定版本）"
  log "  sendspin-client ${CLIENT_REF:0:8} / sendspin-cpp ${CPP_REF:0:8}"
  prepare_source_dir "$INSTALL_DIR"
  local mirror
  for mirror in "" "${GIT_MIRRORS[@]}"; do
    local label="直连 GitHub"
    [ -n "$mirror" ] && label="镜像 ${mirror}"
    log "  尝试 ${label} ..."
    if try_fetch_sources "$mirror" "$INSTALL_DIR"; then
      ok "源码已就绪: ${INSTALL_DIR}"
      break
    fi
    warn "  ${label} 失败"
  done
  [ -d "$INSTALL_DIR/.git" ] || die "源码拉取失败：请检查网络，或手动把仓库放到 ${INSTALL_DIR}"

  # 锁定校验
  local got
  got="$(git -C "$INSTALL_DIR" rev-parse HEAD)"
  [ "$got" = "$CLIENT_REF" ] || die "客户端提交不符（期望 ${CLIENT_REF}，实际 ${got}）"
  ok "客户端提交已锁定: ${got:0:8}"

  got="$(git -C "${INSTALL_DIR}/sendspin-cpp" rev-parse HEAD 2>/dev/null || echo none)"
  if [ "$got" != "$CPP_REF" ]; then
    warn "sendspin-cpp 提交为 ${got:0:8}（期望 ${CPP_REF:0:8}），补丁可能无法应用"
  else
    ok "子模块提交已锁定: ${got:0:8}"
  fi
}

# ---------------------------- 补丁获取与应用 ----------------------------
ensure_patches() {
  [ -n "$PATCH_DIR" ] && { [ -d "$PATCH_DIR" ] || die "补丁目录不存在: ${PATCH_DIR}"; return 0; }

  local self_dir=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  if [ -n "$self_dir" ] && [ -f "${self_dir}/patches/0001-sendspin-cpp-legacy-ma-compat.patch" ]; then
    PATCH_DIR="${self_dir}/patches"
    ok "使用本地补丁: ${PATCH_DIR}"
    return 0
  fi

  # 单文件运行（curl | bash）：下载补丁
  log "本地无补丁目录，尝试下载 ..."
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "${tmp}/patches"
  local f base url
  for f in 0001-sendspin-cpp-legacy-ma-compat.patch 0002-sendspin-client-pcm-first.patch; do
    local got=0
    for url in "${RAW_MIRRORS[@]}"; do
      if curl -fsSL --connect-timeout 15 -o "${tmp}/patches/${f}" "${url}/patches/${f}" 2>/dev/null \
         && [ -s "${tmp}/patches/${f}" ] && grep -q '^diff --git' "${tmp}/patches/${f}"; then
        got=1; break
      fi
    done
    [ "$got" -eq 1 ] || die "补丁下载失败: ${f}"
  done
  PATCH_DIR="${tmp}/patches"
  ok "补丁已下载: ${PATCH_DIR}"
}

apply_one_patch() {
  local repo="$1" patch="$2" label="$3"
  [ -f "$patch" ] || die "补丁文件缺失: $patch"
  if git -C "$repo" apply --check "$patch" 2>/dev/null; then
    git -C "$repo" apply "$patch"
    ok "  已应用: ${label}"
  elif git -C "$repo" apply --check --reverse "$patch" 2>/dev/null; then
    log "  已应用过，跳过: ${label}"
  else
    die "补丁无法应用: ${label}
       上游代码可能已变更。请确认版本锁定未被修改，或提交 issue。"
  fi
}

apply_patches() {
  hr; log "应用兼容补丁"
  ensure_patches

  if [ "$SKIP_LEGACY_PATCH" -eq 1 ]; then
    warn "已跳过 MA 2.10.x 兼容补丁（仅适用于 MA >= 2.11 / aiosendspin 10.x）"
  else
    apply_one_patch "${INSTALL_DIR}/sendspin-cpp" \
      "${PATCH_DIR}/0001-sendspin-cpp-legacy-ma-compat.patch" \
      "sendspin-cpp: 5 处 MA 2.10.x 协议兼容（Noise/hello/state）"
  fi
  apply_one_patch "$INSTALL_DIR" \
    "${PATCH_DIR}/0002-sendspin-client-pcm-first.patch" \
    "sendspin-client: PCM 优先编码（修复 FLAC 解码失败导致无声）"
}

# ---------------------------- 编译 ----------------------------
build_client() {
  hr; log "编译（单核 ARM 约需 30-40 分钟，请耐心等待）"
  local build_dir="${INSTALL_DIR}/build"
  cmake -S "$INSTALL_DIR" -B "$build_dir" \
        -DCMAKE_BUILD_TYPE=Release >/dev/null || die "cmake 配置失败"
  ok "cmake 配置完成"
  log "  并行度 -j${JOBS}"
  if ! cmake --build "$build_dir" -j"$JOBS"; then
    die "编译失败"
  fi
  [ -x "${build_dir}/sendspin-client" ] || die "编译产物缺失"
  ok "编译完成: ${build_dir}/sendspin-client"

  # 产物体检
  file "${build_dir}/sendspin-client" | sed 's/^/    /'
  if ldd "${build_dir}/sendspin-client" 2>/dev/null | grep -q 'not found'; then
    ldd "${build_dir}/sendspin-client" | grep 'not found' | sed 's/^/    /'
    die "二进制存在缺失的动态库"
  fi
  ok "动态库依赖完整"
}

# ---------------------------- 安装 ----------------------------
install_client() {
  hr; log "安装到系统"

  install -m0755 "${INSTALL_DIR}/build/sendspin-client" "$BIN_PATH"
  ok "二进制: ${BIN_PATH}"

  if ! id "$RUN_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$STATE_DIR" \
            --shell /usr/sbin/nologin "$RUN_USER"
    ok "已创建系统用户 ${RUN_USER}"
  else
    log "系统用户 ${RUN_USER} 已存在"
  fi
  usermod -aG audio "$RUN_USER" 2>/dev/null || true

  install -d -m 0700 -o "$RUN_USER" -g "$RUN_USER" "$STATE_DIR"
  install -d -m 0755 "$CONF_DIR"
  ok "状态目录: ${STATE_DIR}（持久化 client_id 与配对密钥）"

  # ---- 配置文件 ----
  {
    printf 'FRIENDLY_NAME="%s"\n' "$DEVICE_NAME"
    printf 'AUDIO_DEVICE="%s"\n' "$AUDIO_DEVICE"
    if [ -n "$ALSA_MIXER" ]; then
      printf 'ALSA_MIXER_SPEC="%s"\n' "$ALSA_MIXER"
    else
      printf '# ALSA_MIXER_SPEC=""   # 未探测到硬件混音器\n'
    fi
    cat <<'CONF'
LOG_LEVEL="info"
# 注意：不要设置 CONNECT_URL。
# 本客户端以监听模式运行（默认端口 8928）并通过 mDNS 广播 _sendspin._tcp，
# 由 Music Assistant 主动连入。设置 CONNECT_URL 会变成客户端出站连 MA 的反向流程。
IDLE_TIMEOUT=0
LIVENESS_TIMEOUT=60
RECONNECT_ON_LOSS=true
UNPAIRED_ACCESS=true
CONF
  } > "${CONF_DIR}/sendspin-client.conf"
  chmod 0644 "${CONF_DIR}/sendspin-client.conf"
  ok "配置: ${CONF_DIR}/sendspin-client.conf"

  # ---- systemd ----
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<UNIT
[Unit]
Description=SendSpin Client Service (akubox)
After=network-online.target sound.target avahi-daemon.service
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
ExecStart=${BIN_PATH} "${DEVICE_NAME}"
Restart=on-failure
RestartSec=5s
StateDirectory=sendspin-client
StateDirectoryMode=0700
Nice=-10

[Install]
WantedBy=multi-user.target
UNIT
  ok "systemd 单元: /etc/systemd/system/${SERVICE_NAME}.service"

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  systemctl restart "$SERVICE_NAME"
  sleep 6

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "服务已启动: ${SERVICE_NAME}"
  else
    warn "服务未处于 active，请查看: journalctl -u ${SERVICE_NAME} -n 50"
  fi
}

summary() {
  hr; log "部署完成，自检"
  systemctl is-enabled "$SERVICE_NAME" 2>/dev/null | sed 's/^/    开机自启: /'
  systemctl is-active  "$SERVICE_NAME" 2>/dev/null | sed 's/^/    运行状态: /'
  { ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null; } | grep -q ':8928' \
    && ok "监听 0.0.0.0:8928（MA 将由此连入）" \
    || warn "未检测到 8928 监听"
  hr
  cat <<EOF
下一步：
  1. 打开 Music Assistant → 设置 → 提供商（Sendspin），应能发现设备「${DEVICE_NAME}」
  2. 在 HA 中会出现 media_player 实体，直接播放即可
  3. 首次播放前确认声卡没被其它服务占用

常用命令：
  查看日志   journalctl -u ${SERVICE_NAME} -f
  重启服务   systemctl restart ${SERVICE_NAME}
  显示配对码 sudo -u ${RUN_USER} ${BIN_PATH} -T
  卸载       bash uninstall.sh

配置文件：${CONF_DIR}/sendspin-client.conf
EOF
}

# ---------------------------- 主流程 ----------------------------
main() {
  printf '%s\n' "======================================================================"
  printf '%s\n' "  AkuBox Sendspin Client 安装脚本"
  printf '%s\n' "======================================================================"
  log "设备名称: ${DEVICE_NAME}"

  preflight
  install_deps
  resolve_audio
  show_audio_holders
  free_audio
  fetch_sources
  apply_patches
  build_client

  if [ "$BUILD_ONLY" -eq 1 ]; then
    hr; ok "仅编译模式完成，未修改系统"
    log "产物: ${INSTALL_DIR}/build/sendspin-client"
    exit 0
  fi

  install_client
  summary
}

main "$@"
