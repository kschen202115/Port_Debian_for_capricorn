#!/bin/bash
# 在 chroot 内执行的 rootfs 配置脚本。
# 作为真实文件存在 = 没有 YAML / bash -c / heredoc 三层引号嵌套的问题。
set -euo pipefail

USERNAME="${USERNAME:-kschen}"
USER_PASSWORD="${USER_PASSWORD:-1}"
LOCALE="${LOCALE:-en_US.UTF-8}"
APT_MIRROR="${APT_MIRROR:-mirrors.ustc.edu.cn}"

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

echo "=============== 安装软件包 ==============="
apt-get update
apt-get install -y --no-install-recommends \
    locales \
    console-setup kbd fonts-dejavu \
    sudo vim nano \
    curl ca-certificates \
    openssh-server \
    net-tools ethtool ifupdown iputils-ping \
    network-manager \
    systemd-timesyncd \
    htop kmod usbutils fdisk \
    make git \
    libevdev-dev

echo "=============== locale ($LOCALE) ==============="
# locale.gen 里的格式是 "# en_US.UTF-8 UTF-8"，把目标行取消注释
LOCALE_ESC=$(printf '%s' "$LOCALE" | sed 's/[.[\*^$]/\\&/g')
sed -i -E "s/^# *(${LOCALE_ESC}[[:space:]]+[^[:space:]]+)/\1/" /etc/locale.gen
grep -qE "^${LOCALE_ESC}[[:space:]]" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
update-locale LANG="$LOCALE"

echo "=============== 控制台字体 ==============="
# 配置由 overlay/etc/default/console-setup 提供。
# chroot 里没有真 tty，必须 --save-only，否则 setupcon 报错
setupcon --save-only || echo "setupcon 在 chroot 内失败属正常，配置已落盘"

echo "=============== 用户 ==============="
if ! id "$USERNAME" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$USERNAME"
fi
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
# 刻意不做 passwd -e（强制首次改密）：那会让 tty1 自动登录一进去就撞改密提示。
# 公开发布的镜像请用仓库 secret ROOTFS_PASSWORD 覆盖默认密码。

# video/input 是操作 backlight 和读 evdev 需要的（power.sh / buffyboard / hkdm）
usermod -aG sudo,video,input,audio,dialout,plugdev "$USERNAME"

echo "=============== 用户名同步到 unit 文件 ==============="
# overlay 里写的是默认名，这里以 $USERNAME 为唯一来源改掉
sed -i "s/--autologin [^ ]*/--autologin ${USERNAME}/" \
    /etc/systemd/system/getty@tty1.service.d/override.conf
sed -i "s|auto_ttyGS0.sh .*|auto_ttyGS0.sh ${USERNAME}|" \
    /etc/systemd/system/autottyGS0.service

echo "=============== SSH ==============="
install -d -m 700 -o "$USERNAME" -g "$USERNAME" "/home/${USERNAME}/.ssh"
install -m 600 -o "$USERNAME" -g "$USERNAME" /dev/null "/home/${USERNAME}/.ssh/authorized_keys"

# drop-in 而不是 sed 主配置：升级不冲突，也不依赖某行长什么样
# （sed '^PasswordAuthentication no' 在现代 Debian 上匹配不到任何东西）
install -d /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-local.conf <<'SSHCONF'
PasswordAuthentication yes
PermitRootLogin no
SSHCONF

echo "=============== 主机名 ==============="
echo "$USERNAME" > /etc/hostname
grep -q "127.0.1.1" /etc/hosts || echo "127.0.1.1 ${USERNAME}" >> /etc/hosts

echo "=============== 脚本权限 ==============="
# git 只跟踪可执行位，这里兜个底
for f in /usr/bin/power.sh /usr/bin/hkdm /usr/bin/buffyboard /home/auto_ttyGS0.sh; do
    [ -e "$f" ] && chmod 755 "$f"
done
[ -d /etc/hkdm ] && chmod -R a+rX /etc/hkdm

echo "=============== systemd 服务 ==============="
systemctl enable ssh
systemctl enable NetworkManager
# 开机自动校时。这台机器时钟不准会导致 apt 校验 Release 的 Valid-Until 失败，
# 治本，替代手动 ntpdate
systemctl enable systemd-timesyncd
# tty1 自动登录（Debian 通常已通过 getty.target.wants 静态启用，这条兜底）
systemctl enable getty@tty1.service
# 开机自动扩容根文件系统到分区实际大小。systemd-growfs-root 是 systemd 自带的
# 静态单元，走 ext4 在线扩容 ioctl，幂等。它没有 [Install] 段，平时靠 fstab 的
# x-systemd.growfs 被 generator 拉起；我们没有 fstab，所以用 add-wants 手挂
systemctl add-wants local-fs.target systemd-growfs-root.service
[ -f /etc/systemd/system/autottyGS0.service ] && systemctl enable autottyGS0.service
[ -f /etc/systemd/system/hkdm.service ] && systemctl enable hkdm.service

echo "=============== APT 换源 ==============="
# trixie 起 apt 推 deb822 格式，debootstrap 写哪个文件取决于版本，两个都处理
for f in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; do
    if [ -f "$f" ]; then
        sed -i "s|deb\.debian\.org|${APT_MIRROR}|g" "$f"
        echo "已改写 $f"
    fi
done

echo "=============== DNS ==============="
# NetworkManager 启动后会接管 resolv.conf，这里只是首次启动前的兜底。
# 8.8.8.8 在国内基本不可用
if [ ! -L /etc/resolv.conf ]; then
    cat > /etc/resolv.conf <<'RESOLV'
nameserver 223.5.5.5
nameserver 119.29.29.29
RESOLV
fi

echo 'Debian ARM64 base rootfs' > /etc/motd

echo "=============== 清理 ==============="
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "=============== 完成 ==============="
