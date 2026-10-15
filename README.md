# AkuBox Sendspin Client

让 AkuBox（ARMv7 智能音箱）作为 **Music Assistant 官方附加组件**的原生播放器，由 MA 主动发现并连入 —— **不需要改动或升级 MA 服务端**。

本仓库包含在真机上验证通过的**源码编译流程**、**7 处协议兼容补丁**和**一键安装脚本**。

```
┌──────────────┐  mDNS _sendspin._tcp   ┌─────────────────────┐
│ Music        │ ─────────────────────▶ │ sendspin-client     │
│ Assistant    │ ◀─── Noise 加密通道 ── │ (本仓库, :8928)     │
│ (官方附加组件)│        PCM 音频流       │  └─▶ ALSA 声卡      │
└──────────────┘                        └─────────────────────┘
```

## 为什么需要这个仓库

上游 `TermeHansen/sendspin-client` 内嵌的 `sendspin-cpp` 是按 **aiosendspin 10.x** 的 wire shape 写的，而当前稳定版 Music Assistant **2.10.x 固定在 aiosendspin 9.1.1**。两者在 Noise 握手、`client/hello`、`client/state`、`server/command` 四个环节共 7 处不兼容，且 MA 每次只报最外层的 `InvalidFieldValue`，不指出具体字段 —— 逐个手工排查非常耗时。

另外上游预编译的 armhf Debian 包要求 `GLIBC_2.38` / `GLIBCXX_3.4.32`，而 AkuBox 是 Ubuntu 22.04（glibc 2.35），**必须源码编译**。本仓库的自编译产物只要求 `GLIBC_2.34`。

## 一键安装

在 AkuBox 上（root）：

```bash
git clone https://github.com/JochenZhou/akubox-sendspin.git /tmp/akubox-sendspin
sudo bash /tmp/akubox-sendspin/install.sh
```

### 交互式向导

不带参数直接运行时，脚本会引导你完成这几步：

```
[*] 环境检查
    架构 armv7l 受支持 / 系统 Ubuntu 22.04.5 LTS / 磁盘空间充足

[*] 设备名称
    当前: akubox
    这个名字会显示在 Music Assistant 与 Home Assistant 中；
    多台 AkuBox 请使用不同名称以便区分。
  输入新名称，直接回车保持不变: 客厅 AkuBox
[✓] 设备显示名已设为: 客厅 AkuBox

[*] 声卡占用检查
[*] 当前占用声卡的进程:
    PID 6965    sendspin-client         ← 本播放器自身（正常）
[*] 系统上存在以下可能争用声卡的服务:
    linux-voice-assistant.service      disabled
    showtime.service                   enabled / active
    akuapp.service                     disabled
  是否停止并禁用以上服务以释放声卡? [y/N]
```

**服务清单是动态探测的**：脚本只在系统上**确实存在**该单元时才列出它。"不是每台 AkuBox 都装了
`linux-voice-assistant`" —— 没装就完全不会出现，也不会因为脚本写死了名字而误报或误操作。

同时会列出**当前真正持有 `/dev/snd` 的进程**，并标注它归属哪个 systemd 单元；不是 systemd 服务
的进程会明确标记「未纳入自动处理」，不会被脚本乱动。本播放器自己占着声卡时会标为「正常」，
不会被当成冲突项。

### 全自动安装

```bash
sudo bash /tmp/akubox-sendspin/install.sh --name "卧室 AkuBox" -y
```

`-y` = 不改名、不询问、按参数执行。**`-y` 本身不会去动任何服务**；要释放声卡必须显式加
`--free-audio`。标准输入不是终端时（例如 `curl | bash`）也会自动转为全自动模式。

### 精确指定要释放的服务

```bash
# 只释放语音助手，保留 showtime
sudo bash /tmp/akubox-sendspin/install.sh --free-audio-services "linux-voice-assistant"
```

脚本会：环境检查 → 设备名 → 安装依赖 → 探测声卡 → **声卡占用检查与交互确认** → 克隆并锁定
上游提交 → 应用补丁 → 编译（单核约 30-40 分钟）→ 安装二进制 / 创建 `sendspin` 用户 /
写配置与 systemd → 启动并自检。

安装完成后，在 Music Assistant 里进入 **设置 → 提供商 → Sendspin**，即可发现该设备；HA 中会出现对应的 `media_player` 实体。

## 7 处协议兼容补丁

| # | 位置 | MA 2.10.x（aiosendspin 9.1.1）要的 | 上游 cpp 0.9.4 发的 | 处理 |
|---|---|---|---|---|
| 1 | Noise `msg1` | 只带 `psk_id`，**无** `psk_category` | 强制要求 category，缺失即握手失败 | 缺失时按 `lt → pr → sn` 顺序解析 PSK |
| 2 | `client/hello` → `supported_pair_methods` | **list**，每项含 `method` 字段 | dict `{名称: {}}` | 改为输出数组 |
| 3 | `client/hello` → `player@v1_support.supported_commands` | **必填**，值限 `volume`/`mute` | 省略（10.x 才可选） | 补 `["volume","mute"]` |
| 4 | `client/state` → `player` 延迟字段名 | `static_delay_ms` | `output_delay_ms`（后续版本改名） | **两个键都写**，旧服务端忽略多余键 |
| 5 | `client/state` → `player.supported_commands` | **只允许 `set_static_delay`** | `["volume","mute"]` | 改为只发 `set_static_delay` |
| 6 | `server/command` → `player.command` | 命令名 `set_static_delay`，值在 `static_delay_ms` | 只认 `set_output_delay` / `output_delay_ms` | **两种拼写都接受**（见下） |
| 7 | 编码偏好顺序 | 取 `supported_formats` 列表中**第一个**匹配项 | FLAC 排在 PCM 前 | **PCM 提前**（见下） |

### 第 6 处：自己宣告的能力，自己解析不了

补丁 5 让客户端在 `client/state` 里宣告支持 `set_static_delay`（9.x 的校验只允许这个值）。MA 收到后**会真的把这条命令发回来**用于同步播放延迟 —— 但上游解析器只认 10.x 的 `set_output_delay`，于是每次连接都报一条：

```
W sendspin.protocol: Ignoring field 'command': unknown value 'set_static_delay'
E sendspin.protocol: Invalid server player command
```

**症状很轻（播放与音量都正常），但它是真缺陷**：MA 永远无法同步该设备的输出延迟，多房间分组时对不齐。修法是把旧拼写映射到同一个命令、并补读 `static_delay_ms` 字段。

> 教训：打「兼容旧服务端」的补丁时，要一并处理**旧服务端据此回发**的消息 —— 宣告一个能力就必须能解析对它的调用。

### 第 7 处是最隐蔽的坑

协议层全通、连接 `ESTABLISHED`、日志无任何连接错误，但**喇叭全程无声**：

```
>>> Stream started
E sendspin.decoder: Error decoding FLAC frame: -2     # FLAC__ERROR_FRAME_NUMBER，chunk 全部被丢弃
>>> Stream ended                                       # 流跑完了，但一个字节都没出声
```

根因是 `supported_formats` 是**有序偏好列表**，MA 取第一个匹配的编码；该构建解不开 MA 发来的 FLAC 流。把 PCM 提到最前之后：

```
I sendspin.sync_task: Processed new codec header: pcm, 44100 Hz, 2 ch, 16-bit
```

零错误播完。**所以「MA 显示 playing 但没声音」先查 codec header 行和 decoder 报错，不要先怀疑连接。**

## 版本锁定

为保证可复现，脚本锁定的是本仓库验证过的提交：

| 组件 | 版本 | 提交 |
|---|---|---|
| `TermeHansen/sendspin-client` | v0.5.2 | `b3d209f93bdd2f6e88174963dc2aeda36c2baf63` |
| `sendspin-cpp`（子模块） | v0.9.4 | `81216ba634d5b396862de2ef545fc1b17ffeb3f3` |

补丁以 `git apply` 方式应用；若上游代码变动导致补丁无法干净应用，脚本会**明确报错退出**，不会静默产出错误二进制。

## 已验证环境

| 项目 | 值 |
|---|---|
| 设备 | AkuBox（ARMv7 单核、494 MB RAM、UBI rootfs） |
| 系统 | Ubuntu 22.04.5 LTS |
| 声卡 | `sun4icodec` → `plughw:0,0`，混音器 `0:Power Amplifier` |
| 服务端 | Music Assistant **2.10.6**（官方附加组件，未修改） |
| 实际播放验证 | 播完 372 秒整曲，零解码错误 |
| 音量控制验证 | HA `volume_set 0.6` → 硬件混音器 12→50（0-63）正确跟随 |
| 日志洁净度 | 连接/播放期间无任何 protocol / decoder 报错 |

## 配置

配置文件 `/etc/sendspin-client/sendspin-client.conf`：

```ini
FRIENDLY_NAME="客厅 AkuBox"
AUDIO_DEVICE="plughw:0,0"
ALSA_MIXER_SPEC="0:Power Amplifier"
LOG_LEVEL="info"
IDLE_TIMEOUT=0
LIVENESS_TIMEOUT=60
RECONNECT_ON_LOSS=true
UNPAIRED_ACCESS=true
```

> **不要设置 `CONNECT_URL`。** 本客户端以**监听模式**运行（默认 8928）并通过 mDNS 广播 `_sendspin._tcp`，由 MA 主动连入。设置 `CONNECT_URL` 会变成「客户端出站连 MA」的反向流程，握手必然失败。

修改配置后：`systemctl restart sendspin-client`

## 常用命令

```bash
journalctl -u sendspin-client -f          # 实时日志
systemctl restart sendspin-client         # 重启
sudo -u sendspin /usr/bin/sendspin-client -T   # 显示配对码
ss -tlnp | grep 8928                      # 确认监听
```

## 卸载

```bash
sudo bash uninstall.sh
```

## 排障要点

**服务起来但 MA 发现不了设备**
检查 8928 是否监听、`avahi-daemon` 是否运行。MA 通过 mDNS 发现，avahi 挂了就发现不了。

**MA 显示 playing 但没声音**
看客户端日志里有没有 `Error decoding FLAC frame`。有就是编码偏好问题；也确认声卡没被别的服务占用：
```bash
fuser -v /dev/snd/*
```

**日志里 `Malformed client/hello` 或 `InvalidFieldValue`**
说明补丁没生效或被跳过（例如误加了 `--skip-legacy-ma-patch`）。重新运行安装脚本即可。

**`scp` 传文件到 AkuBox 会 Connection closed**
该设备 sftp 子系统不可用，用管道替代：
```bash
ssh root@<设备> 'base64 -d > /tmp/file' < <(base64 -w0 ./file)
```

**设备突然「连不上」但另一台机器能连**
很可能是 **WiFi 站点的广播 ARP 应答间歇失效**，不是设备宕机。先确认：
```bash
# 在设备上
uptime                        # 没重启说明它一直活着
# 在连不上的主机上，手工写邻居表后若能立刻 ping 通
ip neigh replace <设备IP> dev <网卡> lladdr <设备MAC> nud permanent
```
能通即证明链路无损、只是 ARP 解析断，属 AP 侧广播投递问题。缓解办法是关闭设备 WiFi 省电：
```bash
nmcli con mod <连接UUID> 802-11-wireless.powersave 2
nmcli con up <连接UUID>
```

## 已知限制

- **状态级音量命令**：补丁 5 让 `client/state` 只声明 `set_static_delay`（9.x 的硬性要求），因此音量/静音通过 **hello 层**声明，在 MA 2.10.x 下工作正常。若将来升级到 aiosendspin 10.x 的 MA，可能需要改用 `--skip-legacy-ma-patch` 重新编译以恢复 10.x 原生的状态级音量控制。
- 仅在上述 AkuBox / Ubuntu 22.04 / MA 2.10.6 组合上做过真机验证。其它设备理论可行（脚本会自动探测声卡与混音器），但需自行确认。

## 目录结构

```
.
├── install.sh                               # 一键安装脚本
├── uninstall.sh                             # 卸载脚本
├── patches/
│   ├── 0001-sendspin-cpp-legacy-ma-compat.patch   # 差异 1-6（Noise / hello / state / server 命令）
│   └── 0002-sendspin-client-pcm-first.patch       # 差异 7（PCM 优先）
├── config/sendspin-client.conf.example      # 配置样例
└── systemd/sendspin-client.service          # systemd 单元参考
```

## 许可

本仓库的脚本与补丁以 **MIT** 许可发布。上游 `sendspin-client` / `sendspin-cpp` 为 **Apache-2.0**，本仓库不重新分发其源码，安装脚本在使用时通过 `git clone` 获取并打补丁。

## 致谢

- [TermeHansen/sendspin-client](https://github.com/TermeHansen/sendspin-client)
- [Sendspin](https://github.com/Sendspin) 协议与 `sendspin-cpp`
- [Music Assistant](https://github.com/music-assistant/server)
