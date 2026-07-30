# Port_Debian_for_capricorn

给 capricorn（小米 Mi 5s Plus）移植的 ARM64 Debian rootfs 构建流程。
GitHub Actions 产出底包，固件和内核用本地脚本注入。

## 下载

固定直链（每次构建自动更新）：

```
https://github.com/kschen202115/Port_Debian_for_capricorn/releases/download/ARM64_Debian_RootFS/rootfs.zip
```

需要锁定某个历史版本，到 [Releases](../../releases) 里取带版本号的 tag
（形如 `rootfs-trixie-13.1-20260730-1200`）。

## 默认账户

| | |
|---|---|
| 用户名 | `kschen` |
| 密码 | `1` |

自建镜像请在仓库里加 secret `ROOTFS_PASSWORD` 覆盖默认密码，别拿默认密码发公开包。

## 使用步骤

1. 把固件放进 `firmware/`（注意目录层级要对）。固件可以从其他包的 `lib/firmware` 里提取。
2. 内核配置见 `config` / `config6.12`，按需修改。
3. 上传一个可用的 `boot.img`，可以是其他系统移植的（pmOS 除外）或从安卓卡刷包里提取。
4. 在 Actions 里手动触发 **Build ARM64 Debian RootFS**。
5. 用 `mount_rootfs.sh` 和 `chroot_install_kernel.sh` 把固件、内核模块注入到底包里。

想换成 Mobian / Kali / Ubuntu，替换 workflow 里的 rootfs 下载源即可。
**强烈建议用官方 rootfs**，这些发行版官网都有现成的 ARM64 镜像。

## 已内置

- **自动扩容**：首次启动 `systemd-growfs-root` 自动把根文件系统扩到分区实际大小，
  不需要手动 `resize2fs`。
- **自动校时**：`systemd-timesyncd` 开机同步，不会再因为时钟不准导致
  `apt update` 报 Release 文件 `Valid-Until` 校验失败。
- **tty1 自动登录**：`agetty --autologin`。
- **USB 串口自动登录**：`serial-getty@ttyGS0`，插上数据线直接进 shell（需内核支持 gadget serial）。
- **SSH**：开机自启，允许密码登录，禁止 root 登录。
- **Wi-Fi**：NetworkManager + wpasupplicant，`nmcli` 可用。
- **电源键**：短按切换屏幕亮度，长按关机。
- **音量下键**：切换 `buffyboard` 虚拟键盘（tty 下打字用）。

## 关于中文显示

**系统 locale 默认是 `en_US.UTF-8`。**

内核 VT（也就是 tty1 那个控制台）的字体表上限 512 个字形，装不下 CJK，
所以在 tty 下中文一定显示成方块或乱码 —— 这是内核限制，改 locale 不能解决。

镜像里已经一并生成了 `zh_CN.UTF-8`。装了 fbterm 之类的用户态终端之后，
可以自己切：

```bash
sudo update-locale LANG=zh_CN.UTF-8
```

## 注意

这个包极度精简，很多常用软件都没有装，按需 `apt install`。

## 仓库结构

```
.github/workflows/build-rootfs.yml   构建流程
scripts/configure-rootfs.sh          在 chroot 内跑的配置脚本
overlay/                             直接镜像目标文件系统布局，最后拷贝，优先级最高
usr/bin/                             预编译二进制（hkdm、buffyboard）
eg/hkdm/                             hkdm 配置，装到 /etc/hkdm
firmware/  firmware-mido/            设备固件
patch/                               杂项补丁
config  config6.12                   内核配置
```

`overlay/` 是所有配置文件的唯一权威来源。往 `usr/bin/` 里放同名文件会造成
两个来源打架 —— 那个目录只放编译产物。
