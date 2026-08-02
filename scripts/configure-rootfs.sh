#!/bin/bash
# 在 chroot 内执行的 rootfs 配置脚本。
# 作为真实文件存在 = 没有 YAML / bash -c / heredoc 三层引号嵌套的问题。
set -euo pipefail

USERNAME="${USERNAME:-kschen}"
USER_PASSWORD="${USER_PASSWORD:-1}"
LOCALE="${LOCALE:-en_US.UTF-8}"
EXTRA_LOCALE="${EXTRA_LOCALE:-zh_CN.UTF-8}"
APT_MIRROR="${APT_MIRROR:-mirrors.ustc.edu.cn}"

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

# 出错时报出行号，chroot 内的失败最难定位
trap 'echo "configure-rootfs.sh: 第 $LINENO 行失败" >&2' ERR

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

# 必须存在的文件，不存在就报清楚原因（overlay 漏拷是最常见的故障）
require_file() {
    if [ ! -f "$1" ]; then
        echo "缺少 $1 —— 检查 overlay/ 是否完整以及 workflow 的拷贝顺序" >&2
        exit 1
    fi
}

# 就地替换并断言真的改到了。裸 sed -i 匹配不到时静默成功，
# 结果是「配置看起来写了但其实没生效」，这类 bug 最难查
sed_assert() {
    local pattern="$1" file="$2" expect="$3"
    require_file "$file"
    sed -i -E "$pattern" "$file"
    if ! grep -qF -- "$expect" "$file"; then
        echo "改写 $file 失败：预期出现 '$expect'，实际内容：" >&2
        cat "$file" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
echo "=============== 安装软件包 ==============="
# ---------------------------------------------------------------------------
apt-get update
# 用 --no-install-recommends 控制体积，但被砍掉的 Recommends 里有几个是这台
# 机器的刚需，必须显式列出：
#   wpasupplicant   NetworkManager 的 Recommends，没它完全没有 Wi-Fi
#   wireless-regdb  没它 Wi-Fi 被锁在最保守的信道和功率
#   libpam-systemd  没它 agetty --autologin 不建立 logind session
#   libinput10 / libxkbcommon0  buffyboard（buffybox 系）的运行时依赖
#   libevdev2       hkdm 的运行时依赖（原来靠 libevdev-dev 间接带进来）
#   busybox         initramfs-tools 的 Recommends，没它 initramfs 里没 shell
#   openssh-client  原来只装了 server，镜像里没有 ssh 命令
apt-get install -y --no-install-recommends \
    locales \
    console-setup kbd fonts-dejavu \
    sudo vim nano less \
    curl ca-certificates \
    openssh-server openssh-client \
    net-tools ethtool ifupdown iputils-ping \
    network-manager wpasupplicant wireless-regdb rfkill iw \
    libpam-systemd \
    systemd-timesyncd \
    htop kmod usbutils i2c-tools fdisk \
    make zram-tools git \
    libevdev2 libinput10 libxkbcommon0 \
    initramfs-tools busybox \
    ncurses-term \
    libinih1

# ---------------------------------------------------------------------------
echo "=============== locale ==============="
# ---------------------------------------------------------------------------
# locale.gen 里的格式是 "# en_US.UTF-8 UTF-8"，把目标行取消注释。
# 同时生成 zh_CN.UTF-8 备用：内核 VT 字体表上限 512 字形装不下 CJK，
# 所以默认仍是英文；装了 fbterm 之类的用户态终端后可自行
#   sudo update-locale LANG=zh_CN.UTF-8
enable_locale() {
    local loc="$1" esc
    esc=$(printf '%s' "$loc" | sed 's/[.[\*^$]/\\&/g')
    sed -i -E "s/^# *(${esc}[[:space:]]+[^[:space:]]+)/\1/" /etc/locale.gen
    grep -qE "^${esc}[[:space:]]" /etc/locale.gen || echo "${loc} UTF-8" >> /etc/locale.gen
}
enable_locale "$LOCALE"
[ -n "$EXTRA_LOCALE" ] && enable_locale "$EXTRA_LOCALE"
locale-gen
update-locale LANG="$LOCALE"

# ---------------------------------------------------------------------------
echo "=============== 控制台字体 ==============="
# ---------------------------------------------------------------------------
require_file /etc/default/console-setup
# chroot 里没有真 tty，必须 --save-only，否则 setupcon 报错
setupcon --save-only || echo "setupcon 在 chroot 内失败属正常，配置已落盘"

# ---------------------------------------------------------------------------
echo "=============== 用户 ==============="
# ---------------------------------------------------------------------------
if ! id "$USERNAME" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$USERNAME"
fi
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
# 刻意不做 passwd -e（强制首次改密）：那会让 tty1 自动登录一进去就撞改密提示。
# 公开发布的镜像请用仓库 secret ROOTFS_PASSWORD 覆盖默认密码。

# video/input 是操作 backlight 和读 evdev 需要的（power.sh / buffyboard / hkdm）。
# 逐个判断存在性：usermod -aG a,b,c 是原子的，input 组由 udev postinst 创建，
# 任一组缺失整条就失败，进而 set -e 让整个构建挂掉
for g in sudo video input audio dialout plugdev; do
    if getent group "$g" >/dev/null; then
        usermod -aG "$g" "$USERNAME"
    else
        echo "跳过不存在的组：$g"
    fi
done

# ---------------------------------------------------------------------------
echo "=============== 用户名同步到 unit 文件 ==============="
# ---------------------------------------------------------------------------
# overlay 里写的是默认名，这里以 $USERNAME 为唯一来源改掉。
# 用 sed_assert 而不是裸 sed：匹配不到时必须炸，不能静默通过
sed_assert "s/--autologin [^ ]+/--autologin ${USERNAME}/" \
    /etc/systemd/system/getty@tty1.service.d/override.conf \
    "--autologin ${USERNAME}"

sed_assert "s/--autologin [^ ]+/--autologin ${USERNAME}/" \
    "/etc/systemd/system/serial-getty@ttyGS0.service.d/autologin.conf" \
    "--autologin ${USERNAME}"

# ---------------------------------------------------------------------------
echo "=============== SSH ==============="
# ---------------------------------------------------------------------------
install -d -m 700 -o "$USERNAME" -g "$USERNAME" "/home/${USERNAME}/.ssh"
install -m 600 -o "$USERNAME" -g "$USERNAME" /dev/null "/home/${USERNAME}/.ssh/authorized_keys"

# drop-in 而不是 sed 主配置：升级不冲突，也不依赖某行长什么样
# （sed '^PasswordAuthentication no' 在现代 Debian 上匹配不到任何东西）
install -d /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-local.conf <<'SSHCONF'
PasswordAuthentication yes
PermitRootLogin no
SSHCONF

# ---------------------------------------------------------------------------
echo "=============== 主机名 ==============="
# ---------------------------------------------------------------------------
echo "$USERNAME" > /etc/hostname
grep -q "127.0.1.1" /etc/hosts || echo "127.0.1.1 ${USERNAME}" >> /etc/hosts

# ---------------------------------------------------------------------------
echo "=============== 时区 ==============="
# ---------------------------------------------------------------------------
# 构建时间戳用的是 CST，镜像本身也对齐到东八区，否则日志时间对不上
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

# ---------------------------------------------------------------------------
echo "=============== 脚本权限 ==============="
# ---------------------------------------------------------------------------
# git 只跟踪可执行位，这里兜个底
for f in /usr/bin/power.sh /usr/bin/hkdm /usr/bin/buffyboard /usr/local/sbin/grow-rootfs; do
    if [ -e "$f" ]; then
        chmod 755 "$f"
    else
        echo "警告：$f 不存在" >&2
    fi
done
[ -d /etc/hkdm ] && chmod -R a+rX /etc/hkdm

# ---------------------------------------------------------------------------
echo "=============== systemd 服务 ==============="
# ---------------------------------------------------------------------------
systemctl enable ssh
systemctl enable NetworkManager
# 开机自动校时。这台机器时钟不准会导致 apt 校验 Release 的 Valid-Until 失败，

systemctl enable systemd-timesyncd

# tty1 自动登录（Debian 通常已通过 getty.target.wants 静态启用，这条兜底）
systemctl enable getty@tty1.service

# USB 串口自动登录。用 systemd 自带的 serial-getty@ 模板 + agetty，

systemctl enable serial-getty@ttyGS0.service

# 开机自动扩容根文件系统到分区实际大小。

require_file /usr/local/sbin/grow-rootfs
systemctl enable grow-rootfs.service

#启用zram
systemctl enable zramswap

chown root:root /etc/hkdm
chown root:root /etc/hkdm/config.d
chown root:root /etc/hkdm/config.d/power.toml

chmod 755 /etc/hkdm
chmod 755 /etc/hkdm/config.d
chmod 644 /etc/hkdm/config.d/power.toml

chmod 755 /usr/local/bin/*
chmod 755 /usr/local/libexec/*
chmod 755 /usr/local/sbin/*

systemctl enable console-keys.service

# hkdm / buffyboard。判断的是二进制而不是 unit 文件 —— unit 来自 overlay，
# 必然存在，拿它做条件等于没判断；二进制来自 usr/bin/，才是真会缺的那个
if [ -x /usr/bin/hkdm ]; then
    systemctl enable hkdm.service
else
    echo "警告：/usr/bin/hkdm 不存在，跳过 hkdm.service" >&2
fi
# buffyboard 不 enable —— 它由 power.sh 按需 start/stop，不开机自启

# ---------------------------------------------------------------------------
echo "=============== initramfs ==============="
# ---------------------------------------------------------------------------
# 重新生成，让 console-setup 的字体设置在启动早期就生效。
# 这台机器可能用不带 initramfs 的 Android 内核，失败不阻塞构建
update-initramfs -u || echo "update-initramfs 失败（无内核时属正常）"

# ---------------------------------------------------------------------------
echo "=============== APT 换源 ==============="
# ---------------------------------------------------------------------------
# trixie 起 apt 推 deb822 格式，debootstrap 写哪个文件取决于版本，两个都处理
for f in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; do
    if [ -f "$f" ]; then
        sed -i "s|deb\.debian\.org|${APT_MIRROR}|g" "$f"
        # security 走独立域名，ustc 也有镜像，一并换掉，否则国内更新极慢
        sed -i "s|security\.debian\.org|${APT_MIRROR}|g" "$f"
        echo "已改写 $f"
    fi
done

# ---------------------------------------------------------------------------
echo "=============== DNS ==============="
# ---------------------------------------------------------------------------
# NetworkManager 启动后会接管 resolv.conf，这里只是首次启动前的兜底。
# 8.8.8.8 在国内基本不可用
if [ ! -L /etc/resolv.conf ]; then
    cat > /etc/resolv.conf <<'RESOLV'
nameserver 223.5.5.5
nameserver 119.29.29.29
RESOLV
fi

echo 'Debian ARM64 base rootfs' > /etc/motd

# ---------------------------------------------------------------------------
echo "=============== 清理 ==============="
# ---------------------------------------------------------------------------
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "=============== 完成 ==============="
