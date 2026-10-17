# 预编译 showtime 二进制放这里（可选）

把编译好的 `showtime` 二进制放成：

```
showtime/prebuilt/showtime.armv7
```

安装脚本会**自动发现并使用它**（模式 `bin`），跳过打补丁与编译，约 5 秒完成：

```bash
sudo bash showtime/install-showtime-nowplaying.sh -y          # 自动用 prebuilt/
sudo bash showtime/install-showtime-nowplaying.sh --bin /path/to/showtime.armv7 -y
sudo bash install.sh --display-bin /path/to/showtime.armv7    # 装播放器时一并
sudo bash showtime/install-showtime-nowplaying.sh --force-build   # 忽略它，走源码编译
```

## 这个二进制从哪来

任选其一：

1. **从另一台同型号 AkuBox 复制**（最快）
   ```bash
   scp root@<另一台>:/opt/aku/showtime/showtime /tmp/showtime.armv7
   ```
2. **自己在同型号设备上编译**（见 `../README.md` 的源码编译流程）
3. 你信任的第三方分发

## 适用条件（不满足就不要用预编译）

- **同型号设备**：`AKU R8-AkuBox`，屏为 `st7735sfb` 162×132 16bpp
- **glibc 与运行库匹配**：Ubuntu 22.04 armhf（jammy）、`libfreetype6` / `libpng16-16` / `libcurl4`
- 脚本安装前会校验：必须是 **ELF 32-bit ARM**，且 `ldd` 无 `not found`；不满足会直接拒绝

跨型号/跨发行版请走源码编译，不要在别的机器上复用。

## 本仓库不附带厂商二进制

`prebuilt/` 目录默认是空的。仓库只分发**补丁与脚本**，不重新分发厂商的 `showtime`
或其编译产物 —— 请自行准备并放到上面的路径（或通过 `--bin` 指定）。
