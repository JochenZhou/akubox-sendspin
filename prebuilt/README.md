# 预编译产物（仓库自带，新设备免编译）

```
prebuilt/
├── sendspin-client.armv7     # 播放器守护进程（含本仓库 7 处兼容补丁）
├── showtime.armv7            # 屏幕界面（黑胶播放页 + 时钟页）
├── fonts/wwDigital.ttf       # 屏幕数字字体（showtime 用相对路径 ./wwDigital.ttf 加载）
└── SHA256SUMS                # 三个文件的校验和
```

有这些文件时，一键脚本**默认就用它们**，全程不需要编译：

```bash
git clone https://github.com/JochenZhou/akubox-sendspin.git /tmp/akubox-sendspin && \
sudo bash /tmp/akubox-sendspin/install.sh --name "客厅 AkuBox" -y
```

正常情况**1-2 分钟**装完（对比源码编译的 30-40 分钟 + 屏幕 1-3 分钟）。

## 产物信息

| 文件 | 大小 | md5 | 说明 |
|---|---|---|---|
| `sendspin-client.armv7` | 1161764 | `343a7a4a9094` | 上游 v0.5.2（`b3d209f9`）+ sendspin-cpp v0.9.4（`81216ba6`）打上 `patches/0001~0003` |
| `showtime.armv7` | 29496 | `189993a416bd` | 厂商 `showtime.c`（27219 字节，md5 `275fc485…`）打上 `showtime/patches/showtime-nowplaying.patch` |
| `fonts/wwDigital.ttf` | 59612 | `a3e85aa95ea2` | 设备自带的显示字体 |

在 `AKU R8-AkuBox`（Ubuntu 22.04.5 armhf / Kernel 6.1.9 / gcc 11.4.0）上编译，
并**在该型号的两台不同设备上实测**：产物的代码区逐字节一致（`sendspin-client` 两者仅差
27 字节，全部落在 ELF BuildID note 区）。

## 适用条件

- 型号：`AKU R8-AkuBox`，屏 `st7735sfb` 162×132 16bpp
- 系统：Ubuntu 22.04 armhf（glibc 2.35），运行库 `libfreetype6` / `libpng16-16` / `libcurl4`
- `showtime` 还要求把字体放在 `/opt/aku/showtime/wwDigital.ttf`（脚本会自动补）
  且服务的**工作目录**是 `/opt/aku/showtime`（脚本会用 systemd drop-in 固定）

不满足就去源码编译：`install.sh --build-only`（播放器）或
`showtime/install-showtime-nowplaying.sh --force-build`（屏幕）。

## 校验

安装脚本会依次检查，任一不过直接拒绝：

1. `ELF 32-bit ARM`
2. `ldd` 无 `not found`
3. 播放器额外检查三个补丁标记：`(legacy server); trying all`、`Advertising   : %zu formats`、`/nowplaying`

手动核对：

```bash
cd prebuilt && sha256sum -c SHA256SUMS
```

## 关于许可

- `sendspin-client.armv7` 来自 Apache-2.0 的上游 `TermeHansen/sendspin-client` 与
  `Sendspin/sendspin-cpp`，本仓库的补丁以 MIT 发布；二进制随附上游许可（见仓库 `LICENSE`
  与上游仓库）。上游版权归其作者所有。
- `showtime.armv7` 与 `wwDigital.ttf` 是 **AkuBox 厂商随设备提供的程序/字体的编译产物**，
  并非开源软件。此处仅作**互操作性用途**提供给同型号设备的机主，用于恢复/替换本机界面。
  权利人如有异议，请开 issue，会立即移除。
- 本目录不含厂商源码（`showtime.c` 不随仓库分发）。
