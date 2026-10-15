#!/usr/bin/env bash
# ==============================================================================
#  AkuBox Sendspin Client 卸载脚本
#
#  用法: sudo bash uninstall.sh [-y] [--purge]
#    -y       不交互确认
#    --purge  同时删除源码目录、状态目录（配对密钥/client_id）与专用用户
# ==============================================================================
set -euo pipefail

SERVICE_NAME="sendspin-client"
BIN_PATH="/usr/bin/sendspin-client"
CONF_DIR="/etc/sendspin-client"
STATE_DIR="/var/lib/sendspin-client"
INSTALL_DIR="/opt/sendspin-client"
RUN_USER="sendspin"

ASSUME_YES=0
PURGE=0

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    --purge)  PURGE=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '[✓] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行" >&2; exit 1; }

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local ans
  read -r -p "$1 [y/N] " ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

echo "======================================================================"
echo "  AkuBox Sendspin Client 卸载"
echo "======================================================================"

log "停止并禁用服务"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true

if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  ok "已移除 systemd 单元"
fi

if [ -f "$BIN_PATH" ]; then
  rm -f "$BIN_PATH"
  ok "已删除 $BIN_PATH"
fi

if [ -d "$CONF_DIR" ]; then
  if confirm "删除配置目录 $CONF_DIR ?"; then
    rm -rf "$CONF_DIR"
    ok "已删除配置"
  else
    log "保留配置"
  fi
fi

if [ "$PURGE" -eq 1 ]; then
  if [ -d "$STATE_DIR" ]; then
    rm -rf "$STATE_DIR"
    ok "已删除状态目录（含配对密钥与 client_id）"
  fi
  if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    ok "已删除源码目录"
  fi
  if id "$RUN_USER" >/dev/null 2>&1; then
    userdel "$RUN_USER" 2>/dev/null || true
    ok "已删除用户 $RUN_USER"
  fi
else
  warn "状态目录与源码目录已保留：$STATE_DIR / $INSTALL_DIR（用 --purge 彻底删除）"
fi

ok "卸载完成"
