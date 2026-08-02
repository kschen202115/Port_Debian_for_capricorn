# Port_Debian_for_capricorn

把 **Debian 13 (trixie) + 主线 Linux 6.19** 移植到 **Xiaomi Mi 5s（capricorn / MSM8996 Pro）**。

仓库同时提供构建流水线（GitHub Actions）、设备树与面板补丁、以及一套跑在设备上的控制台工具。

| 项目 | 当前基线 |
|---|---|
| 设备 | Xiaomi Mi 5s，代号 `capricorn` |
| SoC | Qualcomm MSM8996 Pro（Kryo，**ARMv8.0-A**，4 核 2+2） |
| 屏幕 | LGD TD4722，1080×1920 DSI 命令模式 |
| 内核 | 主线 6.19.y（[msm8996-mainline/linux](https://gitlab.com/msm8996-mainline/linux)，分支 `msm8996-stable-6.19.y`） |
| 编译器 | clang 19 + LLD（`LLVM=1`） |
| 发行版 | Debian 13 (trixie)，systemd 257 |
| 存储 | UFS，rootfs 为 ext4 |
| 显示栈 | DRM/MSM MDP5 + fbcon（无图形桌面） |

---

## 目录

- [一、待提交清单](#一待提交清单)
- [二、快速上手（刷机用户）](#二快速上手刷机用户)
- [三、构建流程](#三构建流程)
- [四、补丁说明](#四补丁说明)
- [五、内核配置](#五内核配置)
- [六、设备端工具集](#六设备端工具集)
- [七、移植记录与踩坑](#七移植记录与踩坑)
- [八、仓库结构](#八仓库结构)

---

## 一、待提交清单

暂无

## 二、快速上手（刷机用户）

### 你需要准备什么

1. **一个可用的 `boot.img` 模板**（仓库根目录已有一个）。可以来自其他系统的移植（pmOS 除外），或者从安卓卡刷包里提取。流水线只借用它的头部结构，内核和 ramdisk 会被替换。
2. **固件**。放进仓库的 `firmware/` 目录，注意保持相对路径结构（会被原样拷到 `/lib/firmware/`）。固件可以从其他发行版包里提取 `lib/firmware`。
3. 想换发行版的话，替换工作流输入里的 `rootfs_url` 即可（mobian / Kali / Ubuntu 都能用）。

### 刷入

从 Releases 下载对应的 `boot.img` 和 `root.zip`：

```bash
# 解压 root.zip 得到 rootfs.img（sparse 格式）
fastboot flash boot boot.img
fastboot flash userdata rootfs.img
```

### 首次启动必做

**默认账户 `kschen`，密码 `1`。**（自用移植，建议第一时间改掉。）

```bash
# 1. 扩容 —— 不做的话可用空间只有 5G
sudo resize2fs /dev/<你的 userdata 分区>

# 2. 校时 —— 时间不对会导致 apt update / 安装软件失败
sudo apt install ntpdate
sudo ntpdate cn.pool.ntp.org
```

镜像极度精简，很多基本软件都没有。想要更完整的环境，强烈建议自己去 mobian / Kali / Ubuntu 官网拿 rootfs，用 `rootfs_url` 替换。

### 硬件按键

Mi 5s 只有三个物理键。**没有实体 Home 键** —— 它用的是玻璃下超声波指纹，设备树里的 `key-dome` 是参考设计沿袭下来的幽灵节点（引脚配置正常，但 IRQ 计数恒为 0，按压没有任何 evdev 事件）。

| 键 | keycode | 默认行为 |
|---|---|---|
| 音量 + | 115 | 打开屏上菜单（`volmenu`） |
| 音量 − | 114 | 切换虚拟键盘（buffyboard） |
| 电源 短按 | 116 | 开关屏幕（面板下电） |
| 电源 长按 | 116 | 关机（systemd-logind 负责） |


### 中文显示

内核已打 **CJKTTY** 补丁（工作流输入 `apply_cjktty_patch` 默认为 `true`），tty 下应当能正常显示中文。不打这个补丁则会乱码。

验证：

```bash
echo "中文测试" > /dev/tty1
cat /sys/class/graphics/fbcon/font_name
```

### 其他

- **串口登录**：内核已支持，通过 USB gadget serial（`/dev/ttyGS0`）。注意 `serial-getty@ttyGS0` 默认不自启，见 [第七节](#七移植记录与踩坑)。
- **USB**：Type-C 口只有 USB 2.0，且**没有 PD 控制器**（TUSB320L 只做 CC 逻辑）。因此不能一边充电一边接外设，除非用带独立供电的 Y 型转接方案。

---

## 三、构建流程

### GitHub Actions：`mi5s.yml`

`workflow_dispatch` 手动触发，输入参数：

| 输入 | 默认值 | 说明 |
|---|---|---|
| `kernel_repo` | `https://gitlab.com/msm8996-mainline/linux.git` | 内核源 |
| `kernel_branch` | `msm8996-stable-6.19.y` | 分支 |
| `device_code` | `capricorn` | 决定 defconfig 名和 DTB 名 |
| `apply_cjktty_patch` | `true` | 打 CJKTTY 中文控制台补丁 |
| `add_firmware` | `true` | 把 `firmware/` 拷进 rootfs |
| `use_clang` | `true` | clang 19 + LLD；`false` 走 GCC |
| `rootfs_url` | 仓库 Release 里的 `rootfs.zip` | 换发行版就改这里 |

### 流水线做了什么

```
初始化环境        ubuntu-22.04，加 arm64 架构，装交叉工具链 + abootimg/mkbootimg
   ↓
下载源码          apt.llvm.org 装 clang 19；浅克隆内核
   ↓
打补丁            config6.12 → arch/arm64/configs/<device>_defconfig
                  git apply 0002-capricorn-td4722-panel-support.patch
                  awk 裁剪 dts/qcom/Makefile，只留本机型 DTB
                  git apply cjktty-6.19.patch + cjktty-add-cjk32x32-font-data.patch
   ↓
编译              make <device>_defconfig && make bindeb-pkg  (LLVM=1)
   ↓
准备 rootfs       下载 rootfs.zip → simg2img → mount → 拷固件
   ↓
chroot 装内核     卸掉旧 linux-image/headers，清 /lib/modules，dpkg -i 新包
   ↓
打包 boot.img     Image.gz + DTB 拼成 kernel-dtb
                  abootimg -x 拆模板，写入实际 rootfs UUID，
                  按内核+ramdisk 实际大小重算 bootsize（+1MB 余量），重新打包
   ↓
发布 Release      tag = debian_for_<device>_<时间戳>
```

### 产物

| 文件 | 说明 |
|---|---|
| `boot.img` | 可直接 fastboot 刷入 |
| `root.zip` | 内含 `rootfs.img`（sparse） |
| `linux-image-*.deb` / `linux-headers-*.deb` | 内核包，rootfs 里已装好，单独提供便于手动升级 |
| `Image.gz` | 裸内核 |
| `dtb.tar.gz` | 编好的 DTB |
| `modules.tar.gz` | 内核模块 |



### 本地构建脚本

仓库里几个 `.sh` 是流水线的手工版本，本地调试时用：

| 脚本 | 用途 |
|---|---|
| `mount_rootfs.sh` | 挂 `root.img` 到 `/mnt/chroot`，bind mount /proc /dev /sys，拷 deb 进去，进 chroot |
| `chroot_install_kernel.sh` | 在 chroot 里卸旧内核包、清 `/lib/modules`、装新 deb |
| `get_kernel_files.sh` | 从 chroot 里取出 initrd |
| `mkboot.sh` | `mkbootimg` 版打包（流水线走的是 `abootimg` 版）。**注意里面的 `root=UUID=` 是写死的**，直接用之前先改成自己 rootfs 的 UUID |

---

## 四、补丁说明

### `patch/0002-capricorn-td4722-panel-support.patch`

本仓库的主补丁，六个部分：

**① USB —— 这是开机 USB 不工作的根因**

```dts
&hsusb_phy1 {
	qcom,tcsr-syscon = <&tcsr_2>;
};
```

QUSB2 PHY 需要读 TCSR 里的 `PHY_CLK_SCHEME` 寄存器来判断参考时钟是单端还是差分。没有这个 phandle，PHY 选错时钟方案，USB 在冷启动时完全不工作，只有事后 unbind/bind dwc3 才能救回来。加上之后开机即可用。

> 走过的弯路：一度以为是 `vdd-supply` 的问题，加了 `vreg_l28a_0p925` —— 那是 SS PHY 的供电轨，和 HS PHY 无关，没有任何作用，已移除。

**② 背光（PMI8994 WLED）—— 黑屏的根因**

```dts
&pmi8994_wled {
	status = "okay";
	interrupts = <0x3 0xd8 0x2 IRQ_TYPE_EDGE_RISING>;
	interrupt-names = "short";

	qcom,current-boost-limit = <970>;
	qcom,current-limit-microamp = <20000>;
	qcom,ovp-millivolt = <29500>;
	qcom,switching-freq = <600>;
};
```

坑在于主线 `qcom-wled.c` 对 PMI8994 用的是 **WLED4 的 boost-limit 表**，但 OVP 用的是**专属的 `pmi8994_wled_ovp_values` 表**。

中断只能有 `short` 一个。加上 `ovp` 会触发 `WARNING: Unbalanced enable for IRQ`

**③ 触摸屏**

```dts
interrupts = <125 IRQ_TYPE_EDGE_FALLING>;
```

**④~⑥ 面板驱动**

新增 `drivers/gpu/drm/panel/panel-lgd-td4722.c`（213 行）及对应的 Kconfig / Makefile 条目，以及独立的 `msm8996pro-xiaomi-capricorn-td4722.dts`。


### CJKTTY

`patch/cjktty-6.19.patch` + `patch/cjktty-add-cjk32x32-font-data.patch`。

让 fbcon 能显示中字符，对应 `CONFIG_FONT_CJK_16x16` / `CONFIG_FONT_CJK_32x32`。由 `apply_cjktty_patch` 输入控制，默认开启。

### DTB 裁剪

`CONFIG_ARCH_QCOM` 会把所有高通 DTB 都编一遍。流水线用 awk 把 `dts/qcom/Makefile` 里除本机型外的 `dtb-$(CONFIG_ARCH_QCOM) +=` 行全删掉，只留 `msm8996pro-xiaomi-capricorn-td4722.dtb`，省掉大量构建时间。

### 可以顺带清理的

`key-dome` 在 capricorn 上是幽灵节点。它定义在 `msm8996-xiaomi-common.dtsi`（同系列有实体 Home 键的机型如 Mi 5/gemini 需要它）：

```dts
&gpio_keys {
	/* Mi 5s 用玻璃下超声波指纹，无实体 Home 键 */
	key-dome {
		status = "disabled";
	};
};
```

---

## 五、内核配置

特殊调整

**性能**

| 改动 | 理由 |
|---|---|
| `# CONFIG_ARM64_PTR_AUTH is not set`<br>`# CONFIG_ARM64_BTI is not set` | Kryo 是 ARMv8.0，没有 PAC(v8.3) 和 BTI(v8.5)。但 `-mbranch-protection=pac-ret+bti` 仍会给每个函数序言和每个间接跳转目标插指令，在 v8.0 上执行为 NOP。零收益的全内核 icache 浪费 |
| `CONFIG_ARM64_VA_BITS_39=y` | 48 位 VA = 4 级页表 → 39 位 = 3 级。TLB miss 时少走一级 |
| `# CONFIG_NUMA is not set` | 单节点设备上 NUMA balancing 会周期性把页表项改成 PROT_NONE 来采样，无处可迁却照付成本 |
| `CONFIG_NR_CPUS=4` | 原值 256。cpumask 从 32 字节缩到 8 字节 |
| `# CONFIG_LIST_HARDENED is not set` | 每个链表操作加校验，链表操作无处不在 |
| `# CONFIG_HARDENED_USERCOPY is not set` | 每次用户态拷贝查 slab/page 边界 |
| `# CONFIG_AUDIT is not set` | 每个 syscall 进出走钩子，即使无规则加载 |
| `# CONFIG_SCHED_CORE is not set` | core scheduling 是给 SMT 侧信道用的，本机无 SMT |
| 其余 ARMv8.1+ 特性 | MTE/SVE/POE/GCS/HAFT/BRBE/AMU/TLB_RANGE/CNP/E0PD/EPAN/RAS 全部关掉。这些走 alternatives 运行时打补丁，纯省体积 |

**内存**

| 改动 | 理由 |
|---|---|
| `# CONFIG_ZSWAP_DEFAULT_ON is not set` | swap 设备是 zram 时，zswap 挡在前面等于**压缩两遍** |
| `# CONFIG_ZRAM_MEMORY_TRACKING is not set` | 它会给**每个压缩条目**加时间戳，直接吃掉想省的内存 |
| `CONFIG_LRU_GEN=y` + `CONFIG_LRU_GEN_ENABLED=y` | 多代 LRU，内存紧张 + 有 swap 时回收决策明显更准 |
| `CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y` | always 在小内存机器上易膨胀 + compaction 卡顿 |

**功耗**

| 改动 | 理由 |
|---|---|
| `CONFIG_CPU_IDLE_GOV_TEO=y` | TEO 对 idle 状态预测比 menu 准。**注意 menu 的 rating(20) 比 teo(19) 高，光开选项不生效**，需要 cmdline 加 `cpuidle.governor=teo`（未测试） |
| `# CONFIG_PM_AUTOSLEEP is not set`<br>`# CONFIG_PM_WAKELOCKS is not set` | Android 机制，Debian 上没人用 |

**构建时间 / 体积**

| 改动 | 理由 |
|---|---|
| `# CONFIG_MODVERSIONS is not set` | 内核和模块是同一次构建出来的，版本永远匹配，genksyms 那一趟纯浪费 |
| 关整块子系统 | XEN / HIBERNATION / KEXEC / CRASH_DUMP / VFIO / ANDROID_BINDER / IP_VS / NFC / RC_CORE / SCSI_SAS / MTD_RAW_NAND 等 |

### 其他配置

| 选项 | 谁在依赖 |
|---|---|
| `CONFIG_LEGACY_TIOCSTI` | `volmenu` 退出后恢复 shell 提示符 |
| `CONFIG_DEBUG_FS_ALLOW_ALL` | `usbpwr` 读 `/sys/kernel/debug/usb/*/mode` |
| `CONFIG_IKCONFIG_PROC` | `/proc/config.gz` |
| `CONFIG_KALLSYMS_ALL` | oops 回溯里的函数名（和 `DEBUG_INFO` 无关，关了 DEBUG_INFO 不影响它） |
| `CONFIG_DRM_MSM_KMS_FBDEV`<br>`CONFIG_DRM_CLIENT_DEFAULT_FBDEV` | tty1 上的 fbcon |
| `CONFIG_ARM_QCOM_CPUFREQ_NVMEM` | MSM8996 Pro 的 speedbin，没它频率表是错的 |
| `CONFIG_QCOM_CPR` | 电压自适应，关了反而更费电 |
| `CONFIG_EXTCON_USBC_TUSB320` | Type-C CC 检测 |
| `CONFIG_FRAME_POINTER` | arm64 栈回溯 |
| `CONFIG_FUNCTION_TRACER` | bringup 阶段排查驱动问题的主力工具，建议一直留着 |

`ARM64_PAN` / `ARM64_HW_AFDBM` / `ARM64_LSE_ATOMICS` Kryo 没有就自动 fallback，成本约等于零。

### 关于 LTO

`CONFIG_HAS_LTO_CLANG=y`，技术上可用。但 ThinLTO 的链接阶段会把编译期拉长 2~3 倍，同时让 panic 回溯的行号失真。



## 六、设备端工具与服务

### 6.1 镜像自带的服务


| Unit | 默认状态 | 作用 |
|---|---|---|
| `hkdm.service` | enabled | **按键守护进程**。从 `/dev/input/event*` 读 evdev 事件并执行绑定动作。整套硬件键交互都由它驱动 |
| `buffyboard.service` | 按需启停 | 屏上虚拟键盘。由 `volmenu` 或 VOL− 直接切换 |
| `getty@tty1.service` | enabled | agetty **autologin `kschen`**，前台是 bash。屏幕上看到的就是它 |
| `serial-getty@ttyGS0.service` | **默认不自启** | USB gadget serial（`/dev/ttyGS0`）登录。禁用原因见下 |

**为什么 `serial-getty@ttyGS0` 不自启**

systemd 257 的回归 [#37854](https://github.com/systemd/systemd/issues/37854)：`exec_context_tty_reset()` 里的 `lock_dev_console()` 会阻塞所有 TTY 类服务。开机自启会把整个启动流程拖住。

如果需要启用串口登陆，执行

```bash
sudo usbconsole
sudo systemctl start serial-getty@ttyGS0
```

### 6.2 overlay 


**systemd 单元与配置**

| 路径 | 类型 | 作用 |
|---|---|---|
| `etc/hkdm/config.d/power.toml` | 配置 | 按键绑定：VOL+ 开菜单、VOL− 切键盘、POWER 短按开关屏 |
| `etc/systemd/system/hkdm.service.d/50-cpuquota.conf` | drop-in | 给 hkdm 加 `CPUQuota=`，兜住它偶发跑满一个核的问题 |
| `etc/systemd/system/console-keys.service` | 新增 unit | 开机把 VOL±/POWER 从控制台键表里摘掉，交给 hkdm 独占 |
| `etc/console-keys.kmap` | 数据 | 三行 `VoidSymbol` |
| `etc/systemd/system/dwc3-rebind.service` | 新增 unit | USB 兜底，见下 |

**脚本**

| 路径 | 用途 |
|---|---|
| `/usr/local/bin/volmenu` | 屏上菜单。三个硬件键驱动，覆盖 USB 模式 / 充电限流 / 电池 / 亮度 / 虚拟键盘 / CPU 频率与调度器 / 网络 / 电源 |
| `/usr/local/bin/usbpwr` | 命令行版：`status\|watch\|mode\|limit\|5v2a\|help`。显示连接模式、电量、充电电流、预计充满时间；可切 USB 模式和调充电限流。切 `host` 时会拒绝在插着充电器的情况下执行 |
| `/usr/local/bin/screenctl` | 开关屏。走 `/sys/class/graphics/fb0/blank`（`4` = FB_BLANK_POWERDOWN，真正给面板下电），不是调背光。原亮度存在 `/run/screenctl.brightness` |
| `/usr/local/bin/usbconsole` | USB gadget serial 控制台的启停封装 |
| `/usr/local/sbin/console-keys` | 应用键表 + 断言生效。幂等 |
| `/usr/local/sbin/dwc3-rebind` | unbind/bind dwc3 控制器 |
| `/usr/local/libexec/tty-nudge` | 用 TIOCSTI 往 tty 注入一个换行，让 `volmenu` 退出后 shell 提示符重新画出来。依赖 `CONFIG_LEGACY_TIOCSTI` 和 `dev.tty.legacy_tiocsti` |
| `/usr/bin/power.sh` | hkdm 调用的电源键处理 |

**`dwc3-rebind.service` 说明**

这是 USB 根因没找到之前的兜底措施：开机后 unbind 再 bind 一次 dwc3 控制器，把没初始化好的 PHY 救回来。

设备树补上 `qcom,tcsr-syscon` 之后已经不需要了，**默认不启用**。保留在仓库里有两个用处：一是换新内核 / 新设备树时可以临时拉起来验证 USB 问题是不是同一类；二是它在开机日志里是 SKIPPED 状态，本身就是「USB 一开始就是好的」的一个旁证。

### volmenu 的设计取舍

- **无专用 VT**，在哪触发就在哪显示，行为类似 nmtui
- **输入全部由 hkdm 从 evdev 读**，脚本只往 tty 写、从不读 tty。因此不需要停 getty、不需要抢终端、不需要改键表
- **界面纯 ASCII，不画右边框** —— 免掉宽度计算，既避免对不齐也省掉每行两次命令替换。单次按键响应约 43~46 ms
- **不用组合键** —— hkdm 处理组合键时会 spin 到 100% CPU

---

## 七、移植记录与踩坑

### USB 冷启动不工作

**根因**：`hsusb_phy1` 缺 `qcom,tcsr-syscon`，QUSB2 PHY 读不到 `PHY_CLK_SCHEME`，参考时钟方案选错。

**验证方式**：加上之后，原先用来救场的 `dwc3-rebind.service` 在开机时变成 SKIPPED 状态，说明 USB 一开始就是好的。

### 开机黑屏

**根因**：PMI8994 WLED 的 `boost-limit` / `ovp` 值没有精确落在驱动的查表项上。详见[第四节](#四补丁说明)。

### serial-getty / 控制台死锁

systemd 257 的[回归 #37854](https://github.com/systemd/systemd/issues/37854)：`exec_context_tty_reset()` 里的 `lock_dev_console()` 会阻塞所有 TTY 服务。

**缓解**：禁用 `serial-getty@ttyGS0` 自启，改用 `ConditionPathExists` 加 drop-in 手动控制。

> 相关教训：不要在没想清楚后果时直接 `systemctl restart getty@tty1`。这个操作会让 systemd-logind 卡住、SSH 连接一起挂掉，只能重启。

### Type-C 没有 PD

TUSB320L 只做 CC 逻辑（Try.SNK），设备树里没有 `usb-c-connector` 节点，也没有 PD 控制器。
### 其他

| 现象 | 结论 |
|---|---|
| Home 键无反应 | 硬件不存在。gpio34 引脚配置正常但 IRQ 91 计数恒为 0 |
| `/sys/class/udc/*/state` 拔线不更新 | 未深入 |
| CPU 频率 | policy0（小核 cpu0-1）最高 1996800 kHz；policy2（大核 cpu2-3）最高 2150400 kHz。由 `ARM_QCOM_CPUFREQ_NVMEM` 读 speedbin 决定 |

---

## 八、仓库结构

```
.
├── .github/workflows/
│   └── mi5s.yml                内核构建 + rootfs 集成 + 打包 + 发布
├── patch/
│   ├── 0002-capricorn-td4722-panel-support.patch    主补丁（USB/背光/触摸/面板）
│   ├── cjktty-6.19.patch                            中文控制台
│   └── cjktty-add-cjk32x32-font-data.patch          32x32 CJK 字模
├── firmware/                   放这里的东西会被拷进 rootfs 的 /lib/firmware/
├── boot.img                    boot 镜像模板，流水线借用其头部结构
├── capricorn_defconfig         内核配置，**流水线实际读的是这个**。
├── mkboot.sh                   本地打包 boot.img（mkbootimg 版，UUID 写死）
├── mount_rootfs.sh             本地挂 rootfs 进 chroot
├── chroot_install_kernel.sh    chroot 内装内核包
├── get_kernel_files.sh         从 chroot 取 initrd
└── readme.md
```

---

## 致谢

- 内核源：[msm8996-mainline/linux](https://gitlab.com/msm8996-mainline/linux)
- CJKTTY 补丁作者

移植过程中的很多结论来自实机反复试错，如果你在别的 MSM8996 机型上复用，注意面板、背光参数和触摸屏中断都是机型相关的，需要重新确认。
