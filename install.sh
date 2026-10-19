#!/usr/bin/env bash
# ==============================================================================
#  AkuBox Sendspin Client 一键安装脚本
#
#  在 AkuBox（或其它 ARMv7 / aarch64 Debian / Ubuntu 音箱设备）上从源码编译并安装
#  TermeHansen/sendspin-client，让它作为 Music Assistant 官方附加组件的本地播放器
#  （MA 主动发现并连接，无需修改 MA 服务端）。
#
#  内置 7 处与 Music Assistant 2.10.x（aiosendspin 9.1.1）的协议兼容补丁。
#
#  用法:
#     sudo bash install.sh              # 交互向导：可改设备名、确认是否释放声卡
#     sudo bash install.sh -y           # 全自动，不改设备名、不动其它服务
#     sudo bash install.sh --free-audio -y
#
#  全部选项见 --help
# ==============================================================================

# 刻意不启用 pipefail：本脚本大量使用 `cmd | grep -q` 与 `cmd | head -1` 这类惯用法，
# 读取端提前退出会让写入端收到 SIGPIPE（退出码 141），pipefail 会把整条管道判为失败。
# 曾因此让「检测服务是否存在」的 if 分支永远走假，导致 --free-audio 静默失效。
set -eu

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
NAME_GIVEN=0
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
WITH_DISPLAY=1          # 默认顺带装屏幕界面（黑胶播放页 + 时钟页）；--no-display 可跳过
NO_POWERSAVE=0          # 默认关闭 WiFi 省电；--no-powersave 可跳过
NO_DEPS=0               # --no-deps: 完全不碰 apt（跳过依赖安装）
DISPLAY_ONLY=0          # --display-only: 只装/更新屏幕界面，不动播放器
HOSTNAME_ARG=""         # --hostname: 指定 mDNS 主机名（不给则按 IP 末段推导）
NO_HOSTNAME=0           # --no-hostname: 不改主机名
HOSTNAME_ONLY=0         # --hostname-only: 只处理主机名（修已装好的设备）
DISPLAY_BIN=""          # --display-bin: 直接用预编译 showtime 二进制（无需源码/编译）
CLIENT_BIN=""           # --client-bin: 直接用预编译 sendspin-client（跳过 clone/补丁/编译）
CLIENT_BIN_FILE=""      # 校验通过后的实际文件（本地路径或下载到临时文件）
# 预编译产物目录（脚本同级 prebuilt/；用 curl | bash 方式运行时为空，不会命中）
SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
PREBUILT_DIR="${SELF_DIR}/prebuilt"
PREBUILT_CLIENT_DEFAULT="${PREBUILT_DIR}/sendspin-client.armv7"
PREBUILT_SHOWTIME_DEFAULT="${PREBUILT_DIR}/showtime.armv7"
FREE_AUDIO=0
FREE_AUDIO_EXPLICIT=0
ASSUME_YES=0
PATCH_DIR=""

# 可能与播放器争用声卡的厂商服务（仅供探测的候选名单）。
# 并非每台 AkuBox 都装了这些，实际以系统上「存在」的为准，不存在就完全不会出现。
# 注意：showtime 只写 /dev/fb0，从不打开 /dev/snd/*，不应出现在这里 ——
# 列进去会让安装时误把它停用禁用，屏幕直接不亮（真机上踩过）。
AUDIO_CONFLICT_CANDIDATES=(linux-voice-assistant akuapp voice-assistant aku-voice)
# 探测结果（运行时填充）
AUDIO_HOLDER_PIDS=()
AUDIO_HOLDER_UNITS=()
AUDIO_CONFLICT_FOUND=()

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

ask() {  # ask "提示语" -> 回显用户输入（非交互时返回空串）
  local prompt="$1" ans=""
  if [ "$INTERACTIVE" -eq 1 ]; then
    read -r -p "  ${prompt}" ans || true
  fi
  printf '%s' "$ans"
}

yes_no() {  # yes_no "提示语"；返回 0 = 是
  local prompt="$1" ans=""
  [ "$INTERACTIVE" -eq 1 ] || return 1
  read -r -p "  ${prompt} [y/N] " ans || true
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

usage() {
  cat <<EOF
AkuBox Sendspin Client 安装脚本

用法: sudo bash install.sh [选项]

交互行为（默认）:
  · 可修改设备显示名（直接回车保持当前主机名）
  · 检测并列出当前占用声卡的进程，以及系统上真实存在、可能争用声卡的服务
  · 询问是否停止并禁用这些服务
  加 -y 或让标准输入不是终端（如 curl | bash）即转为全自动，不做任何交互。

选项:
  --name <名称>          设备显示名（跳过交互改名）  当前: ${DEVICE_NAME}
  --audio-device <设备>  ALSA 播放设备（默认自动探测 plughw:N,0）
  --mixer <card:控件>    ALSA 硬件混音器（默认自动探测，如 0:Power Amplifier）
  --dir <路径>           源码目录（默认: ${INSTALL_DIR}）
  --jobs <N>             编译并行度（默认: ${JOBS}；AkuBox 单核建议 1）
  --patch-dir <路径>     指定补丁目录（默认: 脚本同级 patches/，否则自动下载）
  --build-only           只克隆+打补丁+编译，不安装、不写 systemd
  --with-display         安装屏幕界面（黑胶播放页 + 时钟页）—— 现在是默认行为
  --no-display           不装屏幕界面，只装播放器
  --display-bin <路径|URL>
                         直接用预编译好的 showtime 二进制安装屏幕界面：
                         跳过打补丁与编译，不需要厂商源码，约 5 秒完成。
                         也可把二进制放到 prebuilt/showtime.armv7 自动使用。
  --client-bin <路径|URL>
                         直接用预编译好的 sendspin-client（含 7 处兼容补丁）：
                         跳过 clone / 打补丁 / 编译，30-40 分钟的编译变成几秒。
                         也可把二进制放到 prebuilt/sendspin-client.armv7 自动使用。
                         要求同型号 + 同发行版（glibc/GLIBCXX 一致），脚本会校验。
  --no-powersave         不关闭 WiFi 省电
                         （默认会关闭，见下方「为什么要关 WiFi 省电」）
  --display-only         只安装/更新屏幕界面，不动播放器、不碰声卡服务。
                         用于只改了显示（例如加了 WiFi 图标）想单独更新的场景。
                         会顺带检查 alsa-utils（屏幕要显示音量）与屏幕字体。
  --hostname <名字>      指定 mDNS 主机名（默认按 IP 末段推导为 akubox-<末段>）。
                         出厂主机名都叫 akubox，多台同网会互相抢 akubox.local，
                         导致 avahi 改名并撤回记录、客户端服务注册丢失、MA 发现不到。
  --no-hostname          不改主机名（保持现状）
  --hostname-only        只处理主机名（改完重启 avahi 与客户端），供已装好的设备补做
  --no-deps              完全不碰 apt：跳过依赖安装，直接按现有环境装。
                         预编译模式下通常只缺 avahi-utils；缺运行库会在校验阶段报出来。
  --skip-legacy-ma-patch 不应用 MA 2.10.x 兼容补丁（仅当 MA >= 2.11 / aiosendspin 10.x）
  --free-audio           停止并禁用探测到的声卡争用服务（非交互时仍需 -y 才不再询问）
  --free-audio-services <列表>
                         指定要停止并禁用的服务（空格分隔），不再探测、不再询问。
                         例如只释放语音助手而保留 showtime:
                         --free-audio-services "linux-voice-assistant"
  -y, --yes              全自动：不改名、不询问、按参数执行
  -h, --help             显示本帮助

为什么要关 WiFi 省电（默认会做）:
  AkuBox 是纯 WiFi 设备。这颗 brcmfmac 网卡开着省电时，会出现「设备自己能上网，
  但局域网里别人 ping 不通、SSH 连不上、MA 也发现不到」的间歇性故障 ——
  抓包能看到 who-has 请求发出却零应答（ARP 不回）。把 powersave 设成 2(disable)
  后实测从多台主机均可达。脚本会对当前 WiFi 连接写入该设置并重连一次。

探测的候选服务: ${AUDIO_CONFLICT_CANDIDATES[*]}
（仅当系统上确实存在该服务时才会出现在列表中）

示例:
  sudo bash install.sh                          # 交互式
  sudo bash install.sh --name "卧室 AkuBox"      # 只改名，其余交互
  sudo bash install.sh --name "卧室 AkuBox" -y   # 全自动
EOF
}

# ---------------------------- 参数解析 ----------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --name)                DEVICE_NAME="${2:?--name 需要参数}"; NAME_GIVEN=1; shift 2 ;;
    --audio-device)        AUDIO_DEVICE="${2:?--audio-device 需要参数}"; shift 2 ;;
    --mixer)               ALSA_MIXER="${2:?--mixer 需要参数}"; shift 2 ;;
    --dir)                 INSTALL_DIR="${2:?--dir 需要参数}"; shift 2 ;;
    --jobs)                JOBS="${2:?--jobs 需要参数}"; shift 2 ;;
    --patch-dir)           PATCH_DIR="${2:?--patch-dir 需要参数}"; shift 2 ;;
    --build-only)          BUILD_ONLY=1; shift ;;
    --with-display)        WITH_DISPLAY=1; shift ;;
    --no-display)          WITH_DISPLAY=0; shift ;;
    --display-bin)         DISPLAY_BIN="${2:?--display-bin 需要路径或 URL}"; shift 2 ;;
    --client-bin)          CLIENT_BIN="${2:?--client-bin 需要路径或 URL}"; shift 2 ;;
    --no-powersave)        NO_POWERSAVE=1; shift ;;
    --no-deps)             NO_DEPS=1; shift ;;
    --display-only)        DISPLAY_ONLY=1; WITH_DISPLAY=1; shift ;;
    --hostname)            HOSTNAME_ARG="${2:?--hostname 需要参数}"; shift 2 ;;
    --no-hostname)         NO_HOSTNAME=1; shift ;;
    --hostname-only)       HOSTNAME_ONLY=1; shift ;;
    --skip-legacy-ma-patch) SKIP_LEGACY_PATCH=1; shift ;;
    --free-audio)          FREE_AUDIO=1; shift ;;
    --free-audio-services)
                           [ $# -ge 2 ] || die "--free-audio-services 需要参数"
                           FREE_AUDIO=1
                           FREE_AUDIO_EXPLICIT=1
                           read -r -a AUDIO_CONFLICT_CANDIDATES <<< "$2"
                           [ "${#AUDIO_CONFLICT_CANDIDATES[@]}" -gt 0 ] || die "--free-audio-services 列表为空"
                           shift 2 ;;
    -y|--yes)              ASSUME_YES=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

# 交互能力：显式 -y 关闭；标准输入不是终端也关闭
# （curl | bash 时 stdin 就是脚本本身，绝不能去读它）
INTERACTIVE=1
if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
  INTERACTIVE=0
fi

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
  avail_kb="$(df -Pk "$parent" 2>/dev/null | awk 'NR==2{print $4}')"
  avail_kb="${avail_kb:-0}"
  if [ "$avail_kb" -lt 512000 ]; then
    die "磁盘空间不足：$parent 仅剩 $((avail_kb/1024)) MB，建议至少 800 MB"
  fi
  ok "磁盘空间充足（$parent 剩余 $((avail_kb/1024)) MB）"
}

# ---------------------------- 客户端来源判定（必须在装依赖之前） ----------------------------
# 预编译模式不需要任何编译工具链，只装运行期依赖；源码模式才要 cmake / -dev 开发包。
USE_PREBUILT=0
decide_client_source() {
  if [ -z "$CLIENT_BIN" ] && [ -n "$PREBUILT_DIR" ] && [ -f "$PREBUILT_CLIENT_DEFAULT" ]; then
    CLIENT_BIN="$PREBUILT_CLIENT_DEFAULT"
    log "发现预编译客户端: ${PREBUILT_CLIENT_DEFAULT}"
    log "  （想改为源码编译：删掉该文件，或加 --build-only）"
  fi
  if [ -n "$CLIENT_BIN" ]; then
    [ "$BUILD_ONLY" -eq 1 ] && die "--build-only 与 --client-bin 冲突：预编译模式不编译"
    USE_PREBUILT=1
  else
    USE_PREBUILT=0
  fi
}

install_deps() {
  hr; log "安装依赖"
  if [ "${NO_DEPS:-0}" -eq 1 ]; then
    log "已指定 --no-deps，跳过依赖安装"
    log "  （预编译模式只需运行库；缺库会在校验阶段明确报出来）"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  # 运行期依赖（任何模式都要）：
  #   avahi-daemon / avahi-utils   mDNS 广播与服务注册自检
  #   iw                           关闭 WiFi 省电、读 SSID
  #   alsa-utils (aplay/amixer)    声卡探测与硬件混音器
  #   psmisc (fuser)               查谁占着 /dev/snd
  local pkgs=(avahi-daemon avahi-utils iw alsa-utils psmisc)
  if [ "${USE_PREBUILT:-0}" -eq 1 ]; then
    # 预编译模式：只补二进制需要的运行库，不装 cmake / build-essential / -dev 开发包
    pkgs+=(libavahi-compat-libdnssd1 libasound2)
    log "  预编译模式：只检查运行期依赖（不装 cmake / 开发包）"
  else
    pkgs+=(git cmake pkg-config build-essential libasound2-dev
           libavahi-compat-libdnssd-dev)
    log "  源码编译模式：需要工具链与开发包"
  fi
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

# ---------------------------- 交互：设备名 ----------------------------
interactive_name_step() {
  if [ "$INTERACTIVE" -ne 1 ] || [ "$NAME_GIVEN" -eq 1 ]; then
    log "设备显示名: ${DEVICE_NAME}"
    return 0
  fi
  hr; log "设备名称"
  printf '    当前: %s\n' "$DEVICE_NAME"
  printf '    这个名字会显示在 Music Assistant 与 Home Assistant 中；\n'
  printf '    多台 AkuBox 请使用不同名称以便区分。\n'
  local ans; ans="$(ask "输入新名称，直接回车保持不变: ")"
  if [ -n "$ans" ]; then
    DEVICE_NAME="$ans"
    ok "设备显示名已设为: ${DEVICE_NAME}"
  else
    ok "保持: ${DEVICE_NAME}"
  fi
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

  local cards; cards="$(aplay -l 2>/dev/null || true)"
  if printf '%s' "$cards" | grep -q '^card'; then
    ok "声卡列表:"
    printf '%s\n' "$cards" | sed -n 's/^\(card [0-9]*:.*\)/    \1/p'
  fi
}

# ---------------------------- WiFi 省电（AkuBox 是纯 WiFi 设备） ----------------------------
# 真机判据：省电开着时，设备自己能上网（能 clone GitHub），但局域网内其它主机
# ping/SSH/MA 全部连不上；抓包是 who-has 请求发出、零应答（不回 ARP）。
# 把 powersave 设为 2(disable) 后，从有线主机与同为 WiFi 客户端的主机均可达。
wifi_iface() {
  local ifc
  ifc="$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')"
  [ -n "$ifc" ] || return 1
  [ -d "/sys/class/net/${ifc}/wireless" ] || return 1   # 有线连接不必处理
  printf '%s' "$ifc"
}

nm_active_uuid_for() {
  local dev="$1"
  nmcli -t -f UUID,DEVICE con show --active 2>/dev/null | awk -F: -v d="$dev" '$2==d {print $1; exit}'
}

fix_wifi_powersave() {
  hr; log "关闭 WiFi 省电（避免设备间歇性不回 ARP、MA 发现不到）"
  if [ "${NO_POWERSAVE:-0}" -eq 1 ]; then
    log "已指定 --no-powersave，跳过"
    return 0
  fi
  local ifc
  if ! ifc="$(wifi_iface)"; then
    ok "当前是有线连接，无需处理"
    return 0
  fi
  local ssid
  ssid="$(iw dev "$ifc" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p' | head -1)"
  [ -n "$ssid" ] || ssid="$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v d="$ifc" '$2==d {print $1; exit}')"
  log "  接口: ${ifc}  SSID: ${ssid:-未知}"

  if command -v nmcli >/dev/null 2>&1; then
    local uuid cur
    uuid="$(nm_active_uuid_for "$ifc")"
    if [ -n "$uuid" ]; then
      cur="$(nmcli -f 802-11-wireless.powersave con show "$uuid" 2>/dev/null | awk '{print $2}' | tail -1)"
      if [ "$cur" = "2" ]; then
        ok "已是 powersave=2(disable)，无需改动"
      else
        log "  当前 powersave=${cur:-unknown} → 设为 2(disable) 并重连（会短暂断网）"
        nmcli con mod "$uuid" 802-11-wireless.powersave 2 >/dev/null 2>&1 \
          || warn "写入 powersave 失败（该连接可能由其它组件托管）"
        nmcli con up "$uuid" >/dev/null 2>&1 || warn "重连失败，请检查 WiFi 状态"
        sleep 4
        cur="$(nmcli -f 802-11-wireless.powersave con show "$uuid" 2>/dev/null | awk '{print $2}' | tail -1)"
        if [ "$cur" = "2" ]; then ok "已设为 powersave=2(disable)"; else warn "设置后读到 powersave=${cur:-unknown}"; fi
      fi
      log "  IP: $(ip -4 -br addr show "$ifc" 2>/dev/null | awk '{print $3}')"
      return 0
    fi
    warn "未找到 ${ifc} 的 NetworkManager 活动连接，改用运行时设置"
  fi

  if command -v iw >/dev/null 2>&1; then
    if iw dev "$ifc" set power_save off >/dev/null 2>&1; then
      ok "已在运行时关闭省电（重启后可能恢复，建议交给 NetworkManager 管理）"
    else
      warn "iw set power_save off 失败"
    fi
  else
    warn "缺少 nmcli / iw，无法关闭 WiFi 省电"
  fi
}

# ---------------------------- 唯一主机名（消除 mDNS 抢名） ----------------------------
# 出厂主机名都叫 akubox。多台同网时 avahi 会改名（akubox-2/3…）并反复
# "Withdrawing address record"；客户端若正好在那个窗口注册服务，SRV 会指向被撤回的
# 主机名 → 服务条目失效 → MA 永远发现不到（.176/.180 都踩过，日志铁证）。
# 对策：装的时候把主机名改成 akubox-<IP末段>，交互模式下必须用户输入 y 才改。
hostname_is_modifiable() {
  local h="$1"
  [ "$h" = "akubox" ] && return 0
  printf '%s' "$h" | grep -qE '^akubox-[0-9a-f]+$' && return 0
  return 1
}

derive_hostname() {
  local ip oct mac
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [ -n "$ip" ]; then
    oct="${ip##*.}"
    printf 'akubox-%s' "$oct"
    return 0
  fi
  mac="$(cat /sys/class/net/wlan0/address 2>/dev/null | tr -d ':')"
  if [ -n "$mac" ]; then
    printf 'akubox-%s' "$(printf '%s' "$mac" | tail -c 5)"
    return 0
  fi
  return 1
}

valid_hostname() {
  printf '%s' "$1" | grep -qE '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
}

ensure_hosts_entry() {
  local name="$1" hosts="/etc/hosts"
  if grep -qE '^127\.0\.1\.1[[:space:]]' "$hosts" 2>/dev/null; then
    sed -i -E "s|^127\.0\.1\.1.*|127.0.1.1\t${name}|" "$hosts"
  else
    printf '127.0.1.1\t%s\n' "$name" >> "$hosts"
  fi
}

avahi_wait_ready() {
  local i
  for i in $(seq 1 20); do
    avahi-daemon --check >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

fix_unique_hostname() {
  hr; log "唯一主机名（避免多台 AkuBox 互抢 akubox.local）"
  if [ "${NO_HOSTNAME:-0}" -eq 1 ]; then
    log "已指定 --no-hostname，跳过"
    return 0
  fi

  local cur target
  cur="$(hostname 2>/dev/null || echo akubox)"
  if [ -n "${HOSTNAME_ARG:-}" ]; then
    target="$HOSTNAME_ARG"
  else
    target="$(derive_hostname || true)"
  fi
  if [ -z "$target" ]; then
    warn "无法推导主机名（没有可用 IP/MAC），跳过"
    return 0
  fi
  if ! valid_hostname "$target"; then
    warn "主机名不合法: ${target}（只允许 a-z0-9-，不能以 - 开头或结尾）"
    return 0
  fi

  if [ "$cur" = "$target" ]; then
    ok "主机名已是 ${target}，无需改动"
    return 0
  fi
  if ! hostname_is_modifiable "$cur"; then
    log "当前主机名 ${cur} 是自定义名，不覆盖"
    log "  如需统一：hostnamectl set-hostname ${target} && systemctl restart avahi-daemon && systemctl restart ${SERVICE_NAME}"
    return 0
  fi

  log "  当前: ${cur}   →   建议: ${target}"

  # 交互模式：由用户输入 y 确认；非交互（-y）不改，避免无提示地改动系统
  if [ -z "${HOSTNAME_ARG:-}" ]; then
    if [ "${INTERACTIVE:-0}" -ne 1 ]; then
      warn "非交互模式（-y）不改主机名。要改请加: --hostname ${target}"
      return 0
    fi
    if ! yes_no "多台 AkuBox 同名会互相抢 mDNS 名（可能让 MA 发现不到本机），是否把主机名改为 ${target}?"; then
      warn "已跳过 —— 若本机在 MA 里时有时无，先执行："
      warn "  hostnamectl set-hostname ${target} && systemctl restart avahi-daemon && systemctl restart ${SERVICE_NAME}"
      return 0
    fi
  fi

  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="/root/akubox-install-backup/hostname.${stamp}"
  install -d -m 0700 /root/akubox-install-backup
  printf '%s\n' "$cur" > "$backup"

  if ! hostnamectl set-hostname "$target" 2>/dev/null; then
    warn "hostnamectl 设置失败，跳过"
    return 0
  fi
  ensure_hosts_entry "$target"
  ok "主机名已设为 ${target}（原值: ${backup}）"

  # 顺序关键：先让 avahi 用新名重启并就绪，客户端稍后启动时再注册，才不会再被撤回
  systemctl restart avahi-daemon >/dev/null 2>&1 || warn "重启 avahi-daemon 失败"
  if avahi_wait_ready; then
    ok "avahi 已用新主机名就绪"
  else
    warn "avahi 未在 10 秒内就绪"
  fi

  # 自检 1：hostname 生效
  if [ "$(hostname)" = "$target" ]; then ok "自检1 hostname=${target}"; else warn "自检1 失败：实际为 $(hostname)"; fi

  # 自检 2：mDNS 能把自己的名字解析到本机
  local i resolved="" own_ip=""
  own_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  for i in $(seq 1 6); do
    resolved="$(avahi-resolve -n "${target}.local" 2>/dev/null | awk '{print $2}')"
    [ -n "$resolved" ] && break
    sleep 1
  done
  if [ -z "$resolved" ]; then
    warn "自检2 ${target}.local 暂未解析出（avahi 可能仍在发布）"
  elif [ "$resolved" = "$own_ip" ]; then
    ok "自检2 ${target}.local → ${resolved}（本机）"
  else
    warn "自检2 ${target}.local → ${resolved}，与本机 ${own_ip} 不一致（同网仍有同名设备？）"
  fi

  # 自检 3：本次 avahi 启动没有主机名冲突
  if journalctl -u avahi-daemon --since "-40s" --no-pager 2>/dev/null | grep -q "Host name conflict"; then
    warn "自检3 avahi 日志仍出现 Host name conflict —— 同网可能有同名设备"
  else
    ok "自检3 本次 avahi 启动无主机名冲突"
  fi
}

# ---------------------------- mDNS 就绪与注册自检 ----------------------------
# 踩过的坑：systemctl restart avahi-daemon sendspin-client 同时重启两者时，
# 客户端抢在 avahi 就绪前注册，Bonjour 兼容层**不报错**、日志也看不出来，
# 结果是主机名能解析、服务却不出现在 browse 里，MA 永远发现不到设备。
# 对策：等 avahi 真就绪再启动客户端；万一没注册上，只重启客户端（绝不连 avahi 一起）。
ensure_avahi_ready() {
  hr; log "mDNS（avahi）就绪检查"
  if ! systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    if systemctl cat avahi-daemon.service >/dev/null 2>&1; then
      log "  avahi-daemon 未运行，尝试启动"
      systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
    fi
  fi
  if ! systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    warn "avahi-daemon 不可用 —— MA 靠 mDNS 发现设备，缺少它设备不会出现在 MA 里"
    return 0
  fi
  local i
  for i in $(seq 1 20); do
    if avahi-daemon --check >/dev/null 2>&1; then
      ok "avahi 已就绪（客户端可正常注册服务）"
      return 0
    fi
    sleep 0.5
  done
  warn "avahi 未在 10 秒内就绪，仍继续（若 MA 看不到设备，重启一次客户端）"
}

mdns_hits() {
  local out
  out="$(timeout 4 avahi-browse -rt _sendspin._tcp 2>/dev/null || true)"
  printf '%s' "$out" | grep -F -c "name=${DEVICE_NAME}\"" 2>/dev/null || true
}

verify_mdns_registration() {
  command -v avahi-browse >/dev/null 2>&1 || return 0
  local i hits=0
  for i in $(seq 1 8); do
    hits="$(mdns_hits)"
    if [ "${hits:-0}" -gt 0 ]; then
      ok "mDNS 已广播「${DEVICE_NAME}」"
      return 0
    fi
    sleep 1
  done
  warn "未看到本机的 _sendspin._tcp 通告 —— 重启一次客户端重试"
  systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
  sleep 6
  hits="$(mdns_hits)"
  if [ "${hits:-0}" -gt 0 ]; then
    ok "mDNS 已广播「${DEVICE_NAME}」（重启客户端后恢复）"
  else
    warn "仍未广播，MA 里可能看不到本机；请检查: systemctl status avahi-daemon"
  fi
}

# ---------------------------- 声卡占用检测与释放 ----------------------------
# 由 PID 反查所属 systemd 单元（取 cgroup 里最后一个 .service）
pid_to_unit() {
  local pid="$1" unit=""
  if [ -r "/proc/${pid}/cgroup" ]; then
    unit="$(sed -n 's#.*/\([^/]*\.service\)$#\1#p' "/proc/${pid}/cgroup" | tail -1)"
  fi
  printf '%s' "$unit"
}

# 填充 AUDIO_HOLDER_PIDS / AUDIO_HOLDER_UNITS
detect_audio_holders() {
  AUDIO_HOLDER_PIDS=()
  AUDIO_HOLDER_UNITS=()
  [ -d /dev/snd ] || return 0
  command -v fuser >/dev/null 2>&1 || return 0
  local pid unit
  # fuser -v 输出列: USER PID ACCESS COMMAND，只取真正持有句柄的 F.... 行
  while read -r pid _comm; do
    [ -n "$pid" ] || continue
    AUDIO_HOLDER_PIDS+=("$pid")
    AUDIO_HOLDER_UNITS+=("$(pid_to_unit "$pid")")
  done < <(fuser -v /dev/snd/* 2>&1 | awk '/F\.\.\.\./ {print $(NF-1), $NF}' | sort -u)
}

# 填充 AUDIO_CONFLICT_FOUND：候选名单里「系统上确实存在」的服务
detect_conflict_services() {
  AUDIO_CONFLICT_FOUND=()
  local svc
  for svc in "${AUDIO_CONFLICT_CANDIDATES[@]}"; do
    [ "$svc" = "$SERVICE_NAME" ] && continue          # 绝不把本播放器自己列进去
    # 用 systemctl cat 判断单元是否存在：不经过管道，避免 SIGPIPE 误判
    if systemctl cat "${svc}.service" >/dev/null 2>&1; then
      AUDIO_CONFLICT_FOUND+=("$svc")
    fi
  done
}

audio_conflicts_step() {
  hr; log "声卡占用检查"
  detect_audio_holders
  detect_conflict_services

  # ---- 1) 当前持有哪些进程 ----
  local i pid unit name note
  if [ "${#AUDIO_HOLDER_PIDS[@]}" -gt 0 ]; then
    log "当前占用声卡的进程:"
    for i in "${!AUDIO_HOLDER_PIDS[@]}"; do
      pid="${AUDIO_HOLDER_PIDS[$i]}"
      unit="${AUDIO_HOLDER_UNITS[$i]}"
      name="$(ps -o comm= -p "$pid" 2>/dev/null || echo '?')"
      if [ "$unit" = "${SERVICE_NAME}.service" ]; then
        note="  ← 本播放器自身（正常）"
      elif [ -n "$unit" ]; then
        note="  (${unit})"
      else
        note="  ← 非 systemd 服务，未纳入自动处理"
      fi
      printf '    PID %-7s %-24s%s\n' "$pid" "$name" "$note"
    done
  else
    ok "当前没有进程占用声卡"
  fi

  # ---- 2) 系统上存在哪些争用服务 ----
  if [ "${#AUDIO_CONFLICT_FOUND[@]}" -eq 0 ]; then
    ok "系统上未发现会争用声卡的厂商服务（候选: ${AUDIO_CONFLICT_CANDIDATES[*]}）"
    return 0
  fi
  log "系统上存在以下可能争用声卡的服务:"
  local svc en ac
  for svc in "${AUDIO_CONFLICT_FOUND[@]}"; do
    en="$(systemctl is-enabled "$svc" 2>/dev/null || echo unknown)"
    ac="$(systemctl is-active  "$svc" 2>/dev/null || echo unknown)"
    printf '    %-34s %s / %s\n' "${svc}.service" "$en" "$ac"
  done

  # ---- 3) 决定处理哪些 ----
  local targets=()
  if [ "$FREE_AUDIO_EXPLICIT" -eq 1 ]; then
    targets=("${AUDIO_CONFLICT_FOUND[@]}")                 # --free-audio-services 明确指定，不再询问
  elif [ "$FREE_AUDIO" -eq 1 ]; then
    if [ "$INTERACTIVE" -eq 1 ] && ! yes_no "停止并禁用以上服务以释放声卡?"; then
      warn "已跳过释放声卡"
      return 0
    fi
    targets=("${AUDIO_CONFLICT_FOUND[@]}")
  elif [ "$INTERACTIVE" -eq 1 ]; then
    if yes_no "是否停止并禁用以上服务以释放声卡?"; then
      targets=("${AUDIO_CONFLICT_FOUND[@]}")
    else
      log "保持现状，未释放声卡"
      return 0
    fi
  else
    warn "非交互模式未释放声卡；若声卡被上述服务占用，播放器不会出声。"
    warn "如需自动处理请加 --free-audio -y"
    return 0
  fi

  if [ "${#targets[@]}" -eq 0 ]; then
    return 0
  fi

  for svc in "${targets[@]}"; do
    log "  停止并禁用 ${svc}.service"
    systemctl stop "$svc" >/dev/null 2>&1 || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
  done
  ok "已释放声卡（如需恢复: systemctl enable --now <服务名>）"
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
  if [ -n "$PATCH_DIR" ]; then
    [ -d "$PATCH_DIR" ] || die "补丁目录不存在: ${PATCH_DIR}"
    return 0
  fi

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
  local f url got
  for f in 0001-sendspin-cpp-legacy-ma-compat.patch \
           0002-sendspin-client-16bit-pcm-only.patch \
           0003-sendspin-client-nowplaying-bridge.patch; do
    got=0
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
      "sendspin-cpp: 6 处 MA 2.10.x 协议兼容（Noise / hello / state / server 命令）"
  fi
  apply_one_patch "$INSTALL_DIR" \
    "${PATCH_DIR}/0002-sendspin-client-16bit-pcm-only.patch" \
    "sendspin-client: 只宣告 16-bit PCM（避免服务端协商到解不了的位深而静音）"
  # 把当前曲目写到 /var/lib/sendspin-client/nowplaying，供设备屏幕程序读取。
  # 不写这个文件也不影响播放；文件不会被任何东西消费时它只是静静地放着。
  apply_one_patch "$INSTALL_DIR" \
    "${PATCH_DIR}/0003-sendspin-client-nowplaying-bridge.patch" \
    "sendspin-client: 曲目信息落盘（供屏幕显示歌名/封面）"
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
  local ldd_out; ldd_out="$(ldd "${build_dir}/sendspin-client" 2>/dev/null || true)"
  if printf '%s' "$ldd_out" | grep -q 'not found'; then
    printf '%s\n' "$ldd_out" | grep 'not found' | sed 's/^/    /'
    die "二进制存在缺失的动态库"
  fi
  ok "动态库依赖完整"
}

# ---------------------------- 预编译客户端（跳过 clone / 打补丁 / 编译） ----------------------------
# 同型号 + 同发行版设备的产物可以复用：真机实测两台 AKU R8-AkuBox 各自编译的
# sendspin-client 大小同为 1161764 字节，**只差 27 字节**，且全部落在 ELF BuildID
# note 区（f6dfafb8… vs fc5b936a…），代码区逐字节一致 → 功能上就是同一个程序。
#
# 注意：**上游官方 armhf 发布包不能用** —— 它们要求 glibc 2.38 / GLIBCXX 3.4.32，
# 本机 Ubuntu 22.04（glibc 2.35）跑不起来。这里要的是在同类设备上**自己编译**
# 且打过兼容补丁的产物。
prepare_client_bin() {
  local src="$1" f
  hr; log "使用预编译客户端（跳过 clone / 打补丁 / 编译）"
  case "$src" in
    http://*|https://*)
      f="$(mktemp /tmp/sendspin-client.XXXXXX)"
      log "  下载: ${src}"
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 20 -o "$f" "$src" || die "下载失败: ${src}"
      elif command -v wget >/dev/null 2>&1; then
        wget -q -T 20 -O "$f" "$src" || die "下载失败: ${src}"
      else
        die "缺少 curl / wget，无法下载"
      fi
      ;;
    *)
      [ -f "$src" ] || die "找不到二进制: ${src}"
      f="$(mktemp /tmp/sendspin-client.XXXXXX)"
      cp -a "$src" "$f"
      ;;
  esac
  [ -s "$f" ] || die "二进制为空: ${src}"
  chmod 0755 "$f"

  if command -v file >/dev/null 2>&1; then
    file "$f" | grep -qiE 'ELF 32-bit.*ARM' || die "不是 32 位 ARM ELF：$(file -b "$f")"
  fi
  ok "架构校验通过"

  local missing
  missing="$(ldd "$f" 2>/dev/null | grep 'not found' || true)"
  if [ -n "$missing" ]; then
    printf '%s\n' "$missing" | sed 's/^/    /'
    die "缺少运行时库（发行版/glibc 不匹配？）—— 请改用源码编译，不要跨发行版复用二进制"
  fi
  ok "运行时依赖完整"

  # 必须是打过兼容补丁的构建，否则连 MA 2.10 会握手失败或出更隐蔽的问题
  local s lack=()
  s="$(strings "$f" 2>/dev/null || true)"
  printf '%s' "$s" | grep -qF '(legacy server); trying all'      || lack+=("0001 协议兼容")
  printf '%s' "$s" | grep -qF 'Advertising   : %zu formats'      || lack+=("0002 只宣告 16-bit PCM")
  printf '%s' "$s" | grep -qF '/nowplaying'                       || lack+=("0003 曲目落盘")
  if [ "${#lack[@]}" -gt 0 ]; then
    warn "这个二进制缺少补丁标记: ${lack[*]}"
    warn "多半是未打补丁的构建 —— 连 MA 2.10 会握手失败或静默无声。"
    die "拒绝安装未打补丁的预编译二进制（请用源码编译，或换一个打过补丁的产物）"
  fi
  ok "补丁标记齐全（0001 / 0002 / 0003）"

  CLIENT_BIN_FILE="$f"
  ok "使用: $(md5sum "$f" | cut -c1-12) / $(stat -c%s "$f") 字节"
}

# ---------------------------- 安装 ----------------------------
install_client() {
  hr; log "安装到系统"

  local bin_src="${CLIENT_BIN_FILE:-${INSTALL_DIR}/build/sendspin-client}"
  install -m0755 "$bin_src" "$BIN_PATH"
  ok "二进制: ${BIN_PATH}（$(md5sum "$BIN_PATH" | cut -c1-12)）"

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
  # 必须等 avahi 就绪再启动客户端：否则客户端注册 mDNS 服务会静默失败，
  # 表现为「主机名能解析、服务不在 browse 里」，MA 永远发现不到设备。
  ensure_avahi_ready
  systemctl restart "$SERVICE_NAME"
  sleep 6

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "服务已启动: ${SERVICE_NAME}"
  else
    warn "服务未处于 active，请查看: journalctl -u ${SERVICE_NAME} -n 50"
  fi
  verify_mdns_registration
}

summary() {
  hr; log "部署完成，自检"
  systemctl is-enabled "$SERVICE_NAME" 2>/dev/null | sed 's/^/    开机自启: /'
  systemctl is-active  "$SERVICE_NAME" 2>/dev/null | sed 's/^/    运行状态: /'
  local listen_out; listen_out="$({ ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null; } || true)"
  if printf '%s' "$listen_out" | grep -q ':8928'; then
    ok "监听 0.0.0.0:8928（MA 将由此连入）"
  else
    warn "未检测到 8928 监听"
  fi
  hr
  if [ "$WITH_DISPLAY" -eq 1 ] && systemctl cat showtime.service >/dev/null 2>&1; then
    printf '    屏幕界面: %s / %s\n' "$(systemctl is-enabled showtime 2>/dev/null)" "$(systemctl is-active showtime 2>/dev/null)"
  fi
  cat <<EOF
下一步：
  1. 打开 Music Assistant → 设置 → 提供商（Sendspin），应能发现设备「${DEVICE_NAME}」
     （MA 的发现是触发式扫描：刚装完若没立刻出现，打开该提供商页面或重启 MA 插件即可）
  2. 在 HA 中会出现 media_player 实体，直接播放即可
  3. 首次播放前确认声卡没被其它服务占用
  4. 播放时屏幕显示黑胶旋转封面；暂停/结束立即停转，停止满 5 秒回时钟

常用命令：
  查看日志   journalctl -u ${SERVICE_NAME} -f
  重启服务   systemctl restart ${SERVICE_NAME}
  显示配对码 sudo -u ${RUN_USER} ${BIN_PATH} -T
  卸载       bash uninstall.sh

配置文件：${CONF_DIR}/sendspin-client.conf
EOF
}

# ---------------------------- 仅处理主机名 ----------------------------
# 供已装好的设备补做（比如 .176/.180 这种撞名导致 MA 时有时无的）
run_hostname_only() {
  hr; log "仅处理主机名（播放器与屏幕不动）"
  if ! command -v avahi-resolve >/dev/null 2>&1 || ! command -v avahi-browse >/dev/null 2>&1; then
    log "  补装 avahi-utils（主机名自检需要）"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || warn "apt-get update 失败，继续"
    apt-get install -y --no-install-recommends avahi-utils >/dev/null 2>&1 || true
  fi
  local hn_before hn_after
  hn_before="$(hostname 2>/dev/null || echo '')"
  fix_unique_hostname
  hn_after="$(hostname 2>/dev/null || echo '')"
  # 只有主机名真的变了才重启客户端（跳过/幂等时不打断播放）
  if [ "$hn_before" = "$hn_after" ]; then
    log "  主机名未变，不重启 ${SERVICE_NAME}"
    hr; ok "主机名处理完成"; return 0
  fi
  if systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    log "  重启 ${SERVICE_NAME} 以在新主机名下重新注册"
    systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || warn "重启 ${SERVICE_NAME} 失败"
    sleep 4
    printf '    %s: %s\n' "$SERVICE_NAME" "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)"
    if command -v avahi-browse >/dev/null 2>&1; then
      local name; name="$(grep -E '^FRIENDLY_NAME' "/etc/sendspin-client/sendspin-client.conf" 2>/dev/null | sed 's/.*="\(.*\)"/\1/')"
      if [ -n "$name" ] && timeout 6 avahi-browse -rt _sendspin._tcp 2>/dev/null | grep -qF "name=${name}\""; then
        ok "mDNS 已广播「${name}」"
      else
        warn "未在广播里看到本机名称，稍后可再跑一次本命令"
      fi
    fi
  fi
  hr
  ok "主机名处理完成"
}

# ---------------------------- 仅安装屏幕界面 ----------------------------
# 只改显示（比如新增 WiFi 图标）时用：不动播放器、不碰声卡、不重启 sendspin。
run_display_only() {
  hr; log "仅安装屏幕界面（播放器不动）"
  if [ "${NO_DEPS:-0}" -eq 0 ] && ! dpkg -s alsa-utils >/dev/null 2>&1; then
    log "  安装 alsa-utils（屏幕要显示音量，需要 amixer）"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || warn "apt-get update 失败，继续"
    apt-get install -y --no-install-recommends alsa-utils >/dev/null 2>&1 \
      || warn "alsa-utils 安装失败（音量可能显示 0）"
  fi
  install_display
  hr
  if systemctl cat showtime.service >/dev/null 2>&1; then
    printf '    showtime: %s / %s\n' \
      "$(systemctl is-enabled showtime 2>/dev/null)" "$(systemctl is-active showtime 2>/dev/null)"
  fi
  ok "屏幕界面已就位（播放器与声卡未改动）"
}

# ---------------------------- 屏幕界面：黑胶播放页 + 时钟页 ----------------------------
install_display() {
  hr; log "安装屏幕界面（黑胶播放页 + 时钟页）"
  local self_dir=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  local script="${self_dir}/showtime/install-showtime-nowplaying.sh"
  if [ ! -f "$script" ]; then
    warn "未找到 ${script}（单文件方式运行时没有该目录），跳过"
    return 0
  fi
  if [ ! -f /opt/aku/showtime/showtime.c ] && [ -z "${DISPLAY_BIN:-}" ]; then
    warn "本机只有编译好的 showtime 二进制、没有厂商源码 —— 跳过屏幕改造"
    log "  用预编译产物安装（推荐，不需要源码）："
    log "    sudo bash install.sh --display-bin /path/to/showtime.armv7"
    log "  或把二进制放到 showtime/prebuilt/showtime.armv7 后重跑"
    log "  预编译产物可从另一台同型号 AkuBox 复制："
    log "    scp root@<另一台>:/opt/aku/showtime/showtime /tmp/showtime.armv7"
    return 0
  fi
  local -a dargs=(-y)
  if [ -n "${DISPLAY_BIN:-}" ]; then dargs+=(--bin "$DISPLAY_BIN"); fi
  if bash "$script" "${dargs[@]}"; then
    ok "屏幕界面已安装"
  else
    warn "屏幕界面安装失败 —— 播放器本身不受影响，可稍后单独运行该脚本"
    return 0
  fi
  # showtime 只写 /dev/fb0，不占声卡；如果之前被当成「争用服务」禁用过，这里恢复它。
  if systemctl cat showtime.service >/dev/null 2>&1; then
    if ! systemctl is-active --quiet showtime; then
      log "  showtime 未运行，重新启用以显示屏幕"
      systemctl enable --now showtime >/dev/null 2>&1 || warn "启动 showtime 失败"
      sleep 3
    fi
    if systemctl is-active --quiet showtime; then
      ok "屏幕服务 showtime: $(systemctl is-enabled showtime 2>/dev/null) / active"
    else
      warn "showtime 未能启动，请查看: journalctl -u showtime -n 50"
    fi
  fi
}

# ---------------------------- 主流程 ----------------------------
main() {
  printf '%s\n' "======================================================================"
  printf '%s\n' "  AkuBox Sendspin Client 安装脚本"
  printf '%s\n' "======================================================================"

  preflight
  # 只装屏幕：跳过设备名/依赖/声卡/播放器全部流程
  if [ "$DISPLAY_ONLY" -eq 1 ]; then
    run_display_only
    exit 0
  fi
  # 只处理主机名：供已装好的设备补做
  if [ "$HOSTNAME_ONLY" -eq 1 ]; then
    run_hostname_only
    exit 0
  fi
  interactive_name_step
  # 先判定客户端来源：预编译模式只需运行期依赖，不必拉 cmake/开发包
  decide_client_source
  install_deps
  resolve_audio
  audio_conflicts_step

  if [ "$USE_PREBUILT" -eq 1 ]; then
    prepare_client_bin "$CLIENT_BIN"
  else
    fetch_sources
    apply_patches
    build_client
  fi

  # 屏幕界面也默认用仓库内的预编译产物（缺失时由屏幕脚本回退到源码编译）
  if [ "$WITH_DISPLAY" -eq 1 ] && [ -z "$DISPLAY_BIN" ] && [ -f "$PREBUILT_SHOWTIME_DEFAULT" ]; then
    DISPLAY_BIN="$PREBUILT_SHOWTIME_DEFAULT"
    log "发现预编译屏幕界面: ${PREBUILT_SHOWTIME_DEFAULT}"
  fi

  if [ "$BUILD_ONLY" -eq 1 ]; then
    hr; ok "仅编译模式完成，未修改系统"
    log "产物: ${INSTALL_DIR}/build/sendspin-client"
    exit 0
  fi

  # 放在所有需要联网的步骤之后（会重连 WiFi）；安装阶段不需要网络
  fix_wifi_powersave
  # 主机名必须在客户端启动前定好：这样 avahi 先用新名就绪，客户端启动时注册才不会被撤回
  fix_unique_hostname
  install_client
  if [ "$WITH_DISPLAY" -eq 1 ]; then
    install_display
  fi
  summary
}

main "$@"
