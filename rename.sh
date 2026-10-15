#!/usr/bin/env bash
# ==============================================================================
#  AkuBox Sendspin Client 改名工具（安装后使用，无需重新编译）
#
#  用法:
#     sudo bash rename.sh                  # 查看当前名称
#     sudo bash rename.sh "卧室 AkuBox"     # 改成新名称
#
#  说明:
#    客户端读取的显示名以 /etc/sendspin-client/sendspin-client.conf 里的
#    FRIENDLY_NAME 为准；systemd 单元里的命令行参数只在配置缺该键时才生效，
#    所以改配置即可，本脚本会顺带把单元参数同步一致。
#
#    改完客户端侧会立刻生效（mDNS 广播名 + client/hello 上报名）。
#    但 Music Assistant 侧的播放器对象（Universal Player）名称是创建时固定的，
#    不会跟着改，因此 Home Assistant 里的实体名仍是旧名 —— 需要在 MA 的
#    设置 → 播放器 里重命名，或删除该播放器后重新添加。
# ==============================================================================
set -eu

SERVICE_NAME="sendspin-client"
CONF_FILE="/etc/sendspin-client/sendspin-client.conf"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '[✓] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[✗] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo bash rename.sh \"新名称\"）"

if [ ! -f "$CONF_FILE" ]; then
  die "未找到 $CONF_FILE —— 请先运行 install.sh 完成安装"
fi
if ! systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; then
  die "未找到 ${SERVICE_NAME}.service —— 请先运行 install.sh 完成安装"
fi

current_name() {
  python3 - "$CONF_FILE" <<'PY'
import re, sys
for line in open(sys.argv[1], encoding='utf-8'):
    m = re.match(r'\s*FRIENDLY_NAME\s*=\s*"?([^"\n]*)"?\s*$', line)
    if m:
        print(m.group(1))
        break
PY
}

if [ $# -eq 0 ]; then
  log "当前设备显示名: $(current_name)"
  echo
  echo "改用: sudo bash rename.sh \"新名称\""
  exit 0
fi

NEW_NAME="$*"

# 名称会被写进带引号的配置值与 systemd 单元，含引号或换行会破坏文件
case "$NEW_NAME" in
  *'"'*) die "名称不能包含双引号" ;;
  *$'\n'*) die "名称不能包含换行" ;;
esac
[ -n "$NEW_NAME" ] || die "名称不能为空"

OLD_NAME="$(current_name)"
if [ "$OLD_NAME" = "$NEW_NAME" ]; then
  ok "名称未变化: ${NEW_NAME}"
  exit 0
fi

log "改名: 「${OLD_NAME}」 → 「${NEW_NAME}」"

# 备份
backup_dir="/root/sendspin-rename-backup.$(date +%Y%m%d%H%M%S)"
mkdir -p "$backup_dir"
cp -a "$CONF_FILE" "${backup_dir}/sendspin-client.conf"
[ -f "$UNIT_FILE" ] && cp -a "$UNIT_FILE" "${backup_dir}/sendspin-client.service"
log "已备份到 ${backup_dir}"

# 1) 配置（权威来源）
python3 - "$CONF_FILE" "$NEW_NAME" <<'PY'
import re, sys
path, name = sys.argv[1], sys.argv[2]
lines = open(path, encoding='utf-8').read().splitlines(keepends=True)
out, done = [], False
for line in lines:
    if re.match(r'\s*FRIENDLY_NAME\s*=', line):
        out.append(f'FRIENDLY_NAME="{name}"\n'); done = True
    else:
        out.append(line)
if not done:
    out.append(f'FRIENDLY_NAME="{name}"\n')
open(path, 'w', encoding='utf-8').writelines(out)
PY
ok "配置已更新: ${CONF_FILE}"

# 2) systemd 单元参数同步（保持文件一致，避免以后看日志时困惑）
if [ -f "$UNIT_FILE" ]; then
  python3 - "$UNIT_FILE" "$NEW_NAME" <<'PY'
import re, sys
path, name = sys.argv[1], sys.argv[2]
src = open(path, encoding='utf-8').read()
new, n = re.subn(r'(?m)^ExecStart=(\S+)(\s+".*")?$', lambda m: f'ExecStart={m.group(1)} "{name}"', src)
if n:
    open(path, 'w', encoding='utf-8').write(new)
PY
  ok "systemd 单元参数已同步"
fi

# 3) 重启使新名称生效
systemctl daemon-reload
systemctl restart "$SERVICE_NAME"
sleep 6

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  warn "服务未处于 active！可用备份回滚:"
  warn "  cp ${backup_dir}/sendspin-client.conf ${CONF_FILE}"
  warn "  cp ${backup_dir}/sendspin-client.service ${UNIT_FILE} && systemctl daemon-reload && systemctl restart ${SERVICE_NAME}"
  exit 1
fi
ok "服务已重启"

# 4) 校验新名称确实生效
log "校验生效情况 ..."
effective=""
for _ in 1 2 3 4 5; do
  effective="$(journalctl -u "$SERVICE_NAME" --since "-40s" --no-pager 2>/dev/null \
    | sed -n 's/.*mDNS: Advertising .* (name: \(.*\))$/\1/p' | tail -1)"
  [ -n "$effective" ] && break
  sleep 2
done

if [ "$effective" = "$NEW_NAME" ]; then
  ok "客户端已以新名称广播: ${NEW_NAME}"
else
  warn "未能确认广播名（读到: ${effective:-空}），请查看: journalctl -u ${SERVICE_NAME} -n 30"
fi

echo
printf '%s\n' "----------------------------------------------------------------------"
cat <<EOF
客户端侧已完成。还有一步在 Music Assistant 那边：

  MA 的播放器对象（Universal Player）名称是创建时固定的，不会跟随客户端改名，
  所以 Home Assistant 里的 media_player 实体名不会跟着变（仍显示 MA 侧记住的名称）。

  要在 HA 里也换成新名，请在 Music Assistant 里改名：
  设置 → 播放器 → 找到该设备 → 重命名
  （或删除该播放器后重新添加，MA 会按新名称重建）

  如果不在意 HA 里的名字，就这样即可 —— 播放功能不受名称影响。
EOF
