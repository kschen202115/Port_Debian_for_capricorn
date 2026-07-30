#!/usr/bin/env bash
# 把 fix/ 里的修复应用到 Port_Debian_for_capricorn 仓库。
#
# 用法：
#   ./apply.sh /path/to/Port_Debian_for_capricorn
#
# 幂等：可以重复跑。不会自动 commit，改完自己看 git diff。
set -euo pipefail

REPO="${1:-}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$REPO" ]; then
    echo "用法: $0 /path/to/Port_Debian_for_capricorn" >&2
    exit 1
fi
if [ ! -d "$REPO/.git" ]; then
    echo "$REPO 不是一个 git 仓库" >&2
    exit 1
fi

cd "$REPO"

echo "==> 1/4 删除会覆盖 overlay 的旧文件"
# usr/bin/power.sh 是旧版，而 workflow 原来在 overlay 之后才拷 usr/bin/，
# 导致 overlay/usr/bin/power.sh 每次都被它盖掉。
# 现在拷贝顺序已改成 overlay 最后，但这个文件本身也没有留存的理由。
for f in usr/bin/power.sh eg/auto_ttyGS0.sh; do
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        git rm -q "$f"
        echo "    已删除 $f"
    else
        echo "    跳过（不在版本控制中）：$f"
    fi
done

echo "==> 2/4 删除被 serial-getty 取代的串口登录实现"
for f in overlay/home/auto_ttyGS0.sh \
         overlay/etc/systemd/system/autottyGS0.service; do
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        git rm -q "$f"
        echo "    已删除 $f"
    else
        echo "    跳过（不在版本控制中）：$f"
    fi
done
# 目录空了就清掉
rmdir overlay/home 2>/dev/null || true

echo "==> 3/4 写入修复后的文件"
# 旧的 workflow 文件名未知，先把 .github/workflows 下引用了 debootstrap 的
# yml 列出来供人工确认，不自动删
mkdir -p .github/workflows
copy() {
    local rel="$1"
    mkdir -p "$(dirname "$rel")"
    cp -a "$SRC/$rel" "$rel"
    echo "    $rel"
}

copy .github/workflows/build-rootfs.yml
copy scripts/configure-rootfs.sh
copy overlay/usr/bin/power.sh
copy overlay/etc/default/console-setup
copy overlay/etc/modules-load.d/uinput.conf
copy overlay/etc/systemd/logind.conf.d/10-powerkey.conf
copy overlay/etc/systemd/system/hkdm.service
copy overlay/etc/systemd/system/buffyboard.service
copy overlay/etc/systemd/system/grow-rootfs.service
copy overlay/usr/local/sbin/grow-rootfs
copy "overlay/etc/systemd/system/serial-getty@ttyGS0.service.d/autologin.conf"
copy "overlay/etc/systemd/system/getty@tty1.service.d/override.conf"
copy eg/hkdm/config.d/power.toml
copy readme.md

chmod 755 scripts/configure-rootfs.sh overlay/usr/bin/power.sh overlay/usr/local/sbin/grow-rootfs

echo "==> 4/4 把可执行位记进 git（overlay 靠 cp -a 保留权限）"
git add -A
for f in scripts/configure-rootfs.sh overlay/usr/bin/power.sh overlay/usr/local/sbin/grow-rootfs; do
    git update-index --chmod=+x "$f" 2>/dev/null || true
done

echo
echo "完成。还需要人工确认两件事："
echo
echo "  1) .github/workflows/ 下是否有旧的 workflow 文件需要删除："
ls -1 .github/workflows/ | sed 's/^/       /'
echo "     新文件是 build-rootfs.yml，其余同功能的请手动 git rm。"
echo
echo "  2) usr/bin/ 里应当只剩预编译二进制："
ls -1 usr/bin/ 2>/dev/null | sed 's/^/       /' || echo "       (目录不存在)"
echo
echo "然后 git diff --cached 检查，满意再 commit。"
