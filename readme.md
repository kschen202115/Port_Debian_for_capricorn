# Port_Debian_for_capricorn

在小米 5s Plus（capricorn / msm8996pro，骁龙 821）上跑 mainline 内核 + Debian。

RootFS 由 GitHub Actions 自动构建，**跟随 Debian stable 滚动**，不锁版本。

## 下载

| 入口 | 说明 |
|---|---|
| [Releases 列表](../../releases) | 每次构建一个版本化 tag，形如 `rootfs-trixie-13.6-20260730-1114` |
| tag `ARM64_Debian_RootFS` | 固定入口，URL 不变，内容始终是最新构建 |

## 默认配置

- 用户名 `kschen`，密码 `1`（构建时若设了仓库 secret `ROOTFS_PASSWORD` 则为该值）
- **tty1 自动登录**
- 串口登录（USB gadget，`/dev/ttyGS0`，需内核支持）
- 音量键切换 tty 虚拟键盘（buffyboard）
- 电源键切换屏幕亮度，长按关机
- **首次启动自动扩容根文件系统到分区实际大小**，不需要手动 `resize2fs`
- 开机自动校时（systemd-timesyncd）
- locale 默认 `en_US.UTF-8`

## 自己构建

到 Actions 里手动触发 `Build ARM64 Debian RootFS` 即可。

**这个流程只产底包** —— 一个装好基础软件、配好登录和快捷键的 Debian rootfs。固件和内核模块不在里面，由本地脚本在刷入前后注入：

```bash
./mount_rootfs.sh            # 挂载下载来的 rootfs.img
./chroot_install_kernel.sh   # 注入内核模块 / 固件
```

固件放进 `firmware/`，目录结构对应 `/lib/firmware`，可以从其他 ROM 包里提取。

boot.img 放到仓库根目录，可以是其他系统的移植版（pmOS 除外）或从安卓卡刷包提取。内核配置见 `config`，改完用 `mkboot.sh` 打包。

### 改构建参数

都在 workflow 的 `env:` 段，一处改完全局生效：

| 变量 | 默认 | 说明 |
|---|---|---|
| `IMG_SIZE` | `2G` | 镜像大小。首次启动会自动扩容，这里只要够装完包 |
| `LOCALE` | `en_US.UTF-8` | 系统 locale，见下方关于 tty 中文的说明 |
| `USERNAME` | `kschen` | 会同步到 tty1 自动登录和串口登录 |
| `APT_MIRROR` | `mirrors.ustc.edu.cn` | 镜像站 |

### 换成别的发行版

把 `debootstrap` 那一步换成对应发行版的 rootfs 获取方式即可，mobian / Kali / Ubuntu 官方都提供 arm64 rootfs 压缩包，比 debootstrap 出来的更完整。**强烈建议这么做** —— 本仓库构建的包极度精简，很多基本软件都没有。

## 仓库结构

```
.github/workflows/   构建流程
scripts/             chroot 内执行的配置脚本
overlay/             直接铺到 rootfs 的配置文件，目录即目标路径
usr/bin/             预编译二进制（hkdm、buffyboard）
eg/hkdm/             hkdm 配置
firmware/            设备固件（需自行提供，由本地脚本注入，不进底包）
patch/               内核补丁
config, config6.12   内核配置
```

改配置文件请直接改 `overlay/` 下的真实文件，不要往 workflow 里塞 heredoc。

## 已知问题

**tty 下显示不了中文。** 这个改 locale 或换 console 字体都解决不了 —— 内核 VT 的字体表上限是 512 个字形，物理上装不下 CJK。要在本地终端看中文只能上 fbterm、zhcon 这类直接画 framebuffer 的用户态终端。SSH 进来则不受影响。

**apt 报证书或 Release 过期。** 通常是时钟不对。已经装了 systemd-timesyncd 会自动校时，但首次启动如果网络起得比 apt 慢，可以手动来一次：

```bash
sudo systemctl restart systemd-timesyncd
# 或
sudo ntpdate cn.pool.ntp.org
```

**没有 Vulkan。** Adreno 530 属于 a5xx，Mesa 的 turnip 明确不支持 a5xx 且没有计划（架构上缺 bindless descriptors）；高通的闭源驱动只认 KGSL，跟 mainline 的 drm/msm 不兼容。OpenGL / GLES 走 freedreno 是正常的。需要 Vulkan API 的话只有 lavapipe（CPU 软件渲染）。GPU 通用计算可以试 Mesa 的 rusticl（`RUSTICL_ENABLE=freedreno`，a5xx 未经官方验证）。
