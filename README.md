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

**一条命令做四件事**：装播放器 → 关闭 WiFi 省电 → 装屏幕界面（黑胶播放页 + 时钟页）→ 启动并自检。

| 用法 | 效果 |
|---|---|
| `install.sh`（默认） | 播放器 + 关闭 WiFi 省电 + 黑胶屏幕界面 |
| `install.sh --no-display` | 只装播放器，不动屏幕 |
| `install.sh --no-powersave` | 不关闭 WiFi 省电 |

### 为什么要关 WiFi 省电

AkuBox 是纯 WiFi 设备。这颗 `brcmfmac` 网卡开着省电时会出现**间歇性「失联」**：

- 设备自己能上网（能 clone GitHub、能推流播放）
- 但局域网里别人 **ping 不通、SSH 连不上、MA 也发现不到它**
- PVE 上 `tcpdump -i vmbr0 -n -e arp` 能看到 `who-has <设备IP>` 请求发出，**零应答**（不回 ARP）

把该连接的 `802-11-wireless.powersave` 设为 `2 (disable)` 后，从有线主机
（容器 / PVE）与同为 WiFi 客户端的主机实测**全部可达**。

脚本会自动识别当前是否为 WiFi 连接（有线则跳过），写入设置并重连一次以生效。（会短暂断网，
所以这一步放在所有需要联网的步骤之后、编译之前执行。）

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
    akuapp.service                     disabled
  是否停止并禁用以上服务以释放声卡? [y/N]

[*] 关闭 WiFi 省电（避免设备间歇性不回 ARP、MA 发现不到）
    接口: wlan0  SSID: xxxx
[✓] 已设为 powersave=2(disable)

[*] 编译（单核 ARM 约需 30-40 分钟）
[*] mDNS（avahi）就绪检查
[✓] avahi 已就绪（客户端可正常注册服务）
[✓] 服务已启动: sendspin-client
[✓] mDNS 已广播「客厅 AkuBox」
[*] 安装屏幕界面（黑胶播放页 + 时钟页）
[✓] 屏幕界面已安装
[✓] 屏幕服务 showtime: enabled / active
```

**`showtime` 不在声卡争用名单里**：它只写 `/dev/fb0`、从不打开 `/dev/snd/*`。之前把它列进去，
导致安装时被误停用禁用、屏幕直接不亮（真机上踩过）。屏幕界面是默认安装项，装完会自动
`enable --now showtime`。

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
| 7 | 宣告的编码与位深 | 从 `supported_formats` 里挑一项（**按流的需求选，不一定取第一个**） | 原本宣告 PCM + FLAC + OPUS × 16/24/32-bit | **只宣告 16-bit PCM**（见下） |

### 第 6 处：自己宣告的能力，自己解析不了

补丁 5 让客户端在 `client/state` 里宣告支持 `set_static_delay`（9.x 的校验只允许这个值）。MA 收到后**会真的把这条命令发回来**用于同步播放延迟 —— 但上游解析器只认 10.x 的 `set_output_delay`，于是每次连接都报一条：

```
W sendspin.protocol: Ignoring field 'command': unknown value 'set_static_delay'
E sendspin.protocol: Invalid server player command
```

**症状很轻（播放与音量都正常），但它是真缺陷**：MA 永远无法同步该设备的输出延迟，多房间分组时对不齐。修法是把旧拼写映射到同一个命令、并补读 `static_delay_ms` 字段。

> 教训：打「兼容旧服务端」的补丁时，要一并处理**旧服务端据此回发**的消息 —— 宣告一个能力就必须能解析对它的调用。

### 第 7 处是最隐蔽的坑：宣告了做不到的能力

`supported_formats` 是我们告诉服务端「我能解什么」。**宣告了却解不了，等于给服务端留了一条通往静音的合法路径。**
实测撞到两次，症状完全一样：协议层全通、连接 `ESTABLISHED`、没有任何连接错误，但**喇叭全程无声**。

**7a. FLAC 排在 PCM 前**

```
>>> Stream started
E sendspin.decoder: Error decoding FLAC frame: -2     # FLAC__ERROR_FRAME_NUMBER，chunk 全部被丢弃
>>> Stream ended                                       # 流跑完，一个字节都没出声
```

**7b. 宣告了 24/32-bit，服务端在同步组下选了 32-bit**

```
I sendspin.sync_task: Processed new codec header: pcm, 48000 Hz, 2 ch, 32-bit
E sendspin.decoder: PCM chunk of 9596 bytes is not whole frames    ← 每个 chunk 都这样，累计 5 万多次
E sendspin.sync_task: Failed to decode audio chunk
```

解码器要求一个 chunk 必须是**整数帧**：32-bit 立体声 = 8 字节/帧，而服务端的分块是 9596 字节，
`9596 % 8 = 4` → 判定非法直接 `return false`；而调用方是**「全有或全无」**语义（整块音频一起丢弃），
所以表现不是断续、不是噪声，而是**彻底静默**。任何分块尺寸对不齐的位深（24-bit 同理）都会这样。

**最终处理：只宣告 16-bit PCM。** `16-bit 立体声 = 4 字节/帧`，而服务端的分块尺寸始终是 4 的整数倍
（实测 4404 与 9596 都是），因此必然对齐；同时不再宣告 FLAC（本构建解不开）与 OPUS（未验证）。
代价是放弃 24/32-bit —— 对这类小音箱没有实际损失，换来的是「不可能再因编码选择而静音」。

启动日志里加了一行 `Advertising : N formats (pcm=N flac=N opus=N)`，方便把服务端的编码选择与宣告列表对起来。

> **教训：声明能力要保守。** 只宣告已经被验证能解的东西。宣告了做不到的格式，服务端选中它时你只会得到静音，
> 而日志看起来像解码器故障，很容易把方向查偏。
>
> 排查提示：**「MA 显示 playing 但没声音」先看 `codec header` 那行和 decoder 报错，不要先怀疑连接。**
> 另外「重启客户端后声音回来了」往往只是服务端重新协商到了另一个格式，**那是绕过，不是修复** ——
> 本文档记录的这一例就是这样：重启让它从 32-bit 换到了 16-bit，问题依旧潜伏。

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

## 安装后改名（无需重新编译）

```bash
sudo bash rename.sh                    # 查看当前名称
sudo bash rename.sh "卧室 AkuBox"       # 改成新名称
```

传名称给 `rename.sh` 会：更新配置 → 同步 systemd 单元参数 → 重启服务 → 校验新名称确实生效
（读回客户端实际广播的名字，不是只看命令有没有报错），并先把配置和单元备份到
`/root/sendspin-rename-backup.<时间戳>/`。

也可以手动做这一步：

```bash
# 改这一行即可 —— systemd 单元里那个命令行参数其实是摆设（见下）
sudo sed -i 's/^FRIENDLY_NAME=.*/FRIENDLY_NAME="卧室 AkuBox"/' \
    /etc/sendspin-client/sendspin-client.conf
sudo systemctl restart sendspin-client
```

**为什么改配置就够了**：上游 `main.cpp` 的取值顺序是

```cpp
std::string friendly_name = "Basic Client";
if (config_parser.has_key("FRIENDLY_NAME")) {
    friendly_name = config_parser.get_string("FRIENDLY_NAME", "Basic Client");
} else if (optind < argc) {
    friendly_name = argv[optind];   // 仅当配置里没有 FRIENDLY_NAME 时才用命令行参数
}
```

配置**优先于**命令行参数。systemd 单元里的 `ExecStart=... "客厅 AkuBox"` 因此不生效，
`rename.sh` 会顺手把它改成一致，只是为了以后看文件时不被误导。

### 改名后 HA 里的实体名不会自动跟着变

客户端侧改名会立刻生效（mDNS 广播名 + `client/hello` 上报名），MA 也会用新名字重新注册协议
播放器。但 MA 的 **Universal Player 对象名称是创建时固定的**，不会跟随改名，所以 Home Assistant
里的 `media_player` 实体名仍是 MA 侧记住的名称（`rename.sh` 结束时也会提示这一点）。

要在 HA 里也换成新名，需在 Music Assistant 里改名：**设置 → 播放器 → 该设备 → 重命名**，
或删除该播放器后重新添加（MA 会按新名称重建）。**不影响播放功能。**

## 屏幕显示：黑胶播放页 + 时钟页（可选）

AkuBox 有一块 162×132 的 SPI 小屏，默认只显示时钟。加上屏幕补丁后变成两种界面：

| 播放中 | 停止 5 秒后 |
|---|---|
| ![黑胶播放页](showtime/screenshots/player-vinyl.png) | ![时钟页](showtime/screenshots/clock.png) |
| **圆形旋转封面**（黑胶唱片，不显示歌名） | **大号白色时间** + 顶部状态行 |

（均为真机 `/dev/fb0` 抓帧，6 倍最近邻放大）

- **播放页**：专辑封面逆时针旋转，130px 直径、24°/秒（约 15 秒一圈）、30fps 双线性采样。
  暂停/结束时**立即停转并停在当前角度**（不清零），恢复播放接着转。
- **时钟页**：时间用大字号撑高、再用 FreeType 水平变换压窄（非等比、瘦高，实测 141×91），
  颜色**白色**；日期与星期已移除；顶部保留 `vol:NN%` / 充电图标 / 电量。

```bash
# 默认就装屏幕界面；只装播放器用 --no-display
sudo bash install.sh

# 播放器已装好，也可单独装/更新屏幕部分
sudo bash showtime/install-showtime-nowplaying.sh
```

> **注意**：屏幕改造需要厂商源码 `/opt/aku/showtime/showtime.c`。部分固件批次只发编译好的
> 二进制（例如 MQTT 版，没有消息时屏幕全黑、也不带源码）。这种设备上脚本会给出提示并跳过；
> 从同型号设备复制源码后重跑即可：
>
> ```bash
> scp root@<另一台 AkuBox>:/opt/aku/showtime/showtime.c.pre-nowplaying /opt/aku/showtime/showtime.c
> sudo bash /tmp/akubox-sendspin/showtime/install-showtime-nowplaying.sh
> ```

实现方式与 MQTT / HA 自动化无关 —— sendspin 协议本身就把元数据送到了设备，客户端补丁 `0003`
把 `title / artist / album / artwork_url` 写成一个 `key=value` 小文件
（`/var/lib/sendspin-client/nowplaying`），屏幕程序每秒读一次。

封面走 MA 的 imageproxy，统一请求 `size=160&fmt=png`（**该接口只接受 80/160/256/512**，
且本机链接的是 libpng 而非 libjpeg），下载后按 URL 哈希缓存在
`/tmp/showtime-cover-cache/`，面积平均缩放到 130×130；失败则降级为深灰圆盘。

**性能**：这块屏在单核 1GHz 的 ARMv7 上很容易吃掉整个 CPU。实测踩过两个坑 ——
厂商代码每帧 `popen("amixer|grep|awk")`（一次 fork 4 个进程，提到 30fps 后变 64 次/秒，
白烧 ~60% 单核），以及逐像素浮点在这颗 CPU 的 VFP 上的串行高延迟。
修复后 30fps 下 showtime 占 **16-17%**、整机 21-23%（修前分别是 57% / 96%）。
实现细节、参数表与验证方法见 [`showtime/README.md`](showtime/README.md)。

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
├── install.sh                               # 一键安装脚本（--with-display 含屏幕部分）
├── rename.sh                                # 安装后改名（无需重新编译）
├── uninstall.sh                             # 卸载脚本
├── patches/
│   ├── 0001-sendspin-cpp-legacy-ma-compat.patch   # 差异 1-6（Noise / hello / state / server 命令）
│   ├── 0002-sendspin-client-16bit-pcm-only.patch  # 差异 7（只宣告 16-bit PCM）
│   └── 0003-sendspin-client-nowplaying-bridge.patch # 曲目信息落盘（供屏幕显示）
├── showtime/                                # 屏幕界面：黑胶播放页 + 时钟页（可选）
│   ├── README.md
│   ├── install-showtime-nowplaying.sh
│   ├── screenshots/                         # 真机抓帧（README 用图）
│   │   ├── player-vinyl.png
│   │   └── clock.png
│   └── patches/showtime-nowplaying.patch    # 对厂商 showtime.c 的改动
├── config/sendspin-client.conf.example      # 配置样例
└── systemd/sendspin-client.service          # systemd 单元参考
```

## 许可

本仓库的脚本与补丁以 **MIT** 许可发布。上游 `sendspin-client` / `sendspin-cpp` 为 **Apache-2.0**，本仓库不重新分发其源码，安装脚本在使用时通过 `git clone` 获取并打补丁。

## 致谢

- [TermeHansen/sendspin-client](https://github.com/TermeHansen/sendspin-client)
- [Sendspin](https://github.com/Sendspin) 协议与 `sendspin-cpp`
- [Music Assistant](https://github.com/music-assistant/server)
