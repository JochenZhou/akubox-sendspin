# 预编译二进制放这里（可选，能省掉 30-40 分钟编译）

```
prebuilt/sendspin-client.armv7     # 播放器（含 7 处兼容补丁）
```

放好后安装脚本会**自动发现并使用**，跳过 clone / 打补丁 / 编译：

```bash
sudo bash install.sh -y                                    # 自动用 prebuilt/
sudo bash install.sh --client-bin /path/to/sendspin-client.armv7 -y
sudo bash install.sh --build-only                          # 强制源码编译（--client-bin 与它冲突）
```

全自动安装从 **30-40 分钟压到约 1 分钟**（剩下的时间主要是装依赖与 mDNS 校验）。

## 这个二进制从哪来

**必须是在同类设备上自己编译、且打过补丁的产物**：

```bash
# 从另一台已装好的同型号 AkuBox 取
scp root@<另一台>:/usr/bin/sendspin-client /tmp/sendspin-client.armv7
```

❌ **不要用上游官方 armhf 发布包** —— 它要求 glibc 2.38 / GLIBCXX 3.4.32，
Ubuntu 22.04（glibc 2.35）根本加载不了。

## 为什么两台设备能用同一个文件

真机实测（两台 `AKU R8-AkuBox`，同为 Ubuntu 22.04.5 armhf、Kernel 6.1.9、gcc 11.4.0）：

| 项目 | 结果 |
|---|---|
| 大小 | 两台都是 1161764 字节 |
| 字节差异 | **仅 27 字节** |
| 差异位置 | 全部落在两处 ELF BuildID note 区（`f6dfafb8…` vs `fc5b936a…`） |
| 动态库依赖 | 完全相同的 16 个库，`ldd` 无缺失 |
| 补丁标记 | `(legacy server); trying all` / `Advertising   : %zu formats` / `/nowplaying` 全部存在 |

也就是：**代码区逐字节一致**，差异只是链接器生成的唯一 ID，功能上是同一个程序。

## 安装前的校验（不满足直接拒绝）

1. 必须是 **ELF 32-bit ARM**
2. `ldd` 不能有 `not found`（glibc/发行版不匹配会在这里失败）
3. 三个补丁标记必须齐全 —— 防止把**未打补丁**的构建装上去（那种连 MA 2.10 会握手失败或静默无声）

## 本仓库不附带二进制

`prebuilt/` 默认是空的，只放这份说明。仓库只分发**补丁与脚本**，不重新分发上游客户端
或其编译产物 —— 二进制请自行准备（从你自己另一台设备复制，或本地编译）。
