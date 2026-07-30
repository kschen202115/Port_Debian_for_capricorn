#!/bin/bash
# 亮度切换 + buffyboard（虚拟键盘）开关，由 hkdm 触发。
#
# 历史问题一：原版被 YAML -> bash -c "..." -> heredoc 三层引号毁掉了，生成出来是
#   BRIGHTNESS_PATH=/sys/class/backlight/*/brightness   引号丢失
#   CURRENT_BRIGHTNESS=                                 $(...) 在 runner 上就被展开了
#   if [  == power ]; then                              $1 消失，运行时语法错误
#
# 历史问题二：重写版放进 overlay/ 之后，workflow 却在 overlay 之后才拷 usr/bin/，
# 仓库里残留的旧 usr/bin/power.sh 又把它盖回去了。现在 overlay 最后拷，且
# workflow 里有一条 grep 断言确认落盘的是本文件。
#
# 历史问题三：原版用 `sudo buffyboard &` 起虚拟键盘。power.sh 是 hkdm 的子进程，
# 那个后台 buffyboard 就落在 hkdm.service 的 cgroup 里，hkdm 一重启
# （Restart=on-failure）默认 KillMode=control-group 会连带把键盘杀掉。
# 现在交给独立的 buffyboard.service 管，生命周期和 hkdm 解耦。

set -uo pipefail

# ---- 定位 backlight 设备 ----
# glob 只在这里展开一次，后面全部用引号安全引用
BL_DIR=""
for d in /sys/class/backlight/*/; do
    if [ -r "${d}brightness" ]; then
        BL_DIR="$d"
        break
    fi
done

if [ -z "$BL_DIR" ]; then
    echo "power.sh: 找不到 backlight 设备" >&2
    exit 1
fi

BRIGHTNESS_FILE="${BL_DIR}brightness"
MAX_FILE="${BL_DIR}max_brightness"

DIM_LEVEL=0
# 原版硬编码 100，但各面板 max_brightness 可能是 255 / 1023 / 4095，
# 写死会导致「最亮」其实很暗。这里从 sysfs 读真实值
MAX_LEVEL=100
if [ -r "$MAX_FILE" ]; then
    v="$(cat "$MAX_FILE" 2>/dev/null)"
    # 必须是纯数字，否则退回默认值；空值会让后面的 -eq 直接报语法错误
    case "$v" in
        ''|*[!0-9]*) : ;;
        *) MAX_LEVEL="$v" ;;
    esac
fi

KB_UNIT=buffyboard.service

# ---- 工具函数 ----
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

get_brightness() {
    local v
    v="$(cat "$BRIGHTNESS_FILE" 2>/dev/null)"
    case "$v" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$v" ;;
    esac
}

set_brightness() {
    echo "$1" | as_root tee "$BRIGHTNESS_FILE" >/dev/null
}

kb_running() {
    systemctl is-active --quiet "$KB_UNIT"
}

kb_stop() {
    kb_running && as_root systemctl stop "$KB_UNIT"
}

kb_start() {
    as_root systemctl start "$KB_UNIT"
}

# ---- 主逻辑 ----
ACTION="${1:-}"

case "$ACTION" in
    power)
        if [ "$(get_brightness)" -eq "$DIM_LEVEL" ]; then
            set_brightness "$MAX_LEVEL"
            echo "屏幕已点亮 (${MAX_LEVEL})"
        else
            set_brightness "$DIM_LEVEL"
            echo "屏幕已调暗"
        fi
        ;;
    kb)
        if kb_running; then
            kb_stop
            echo "buffyboard 已关闭"
        else
            kb_start
            echo "buffyboard 已启动"
        fi
        exit 0
        ;;
    "")
        # 无参数：只做下面的状态同步
        ;;
    *)
        echo "用法: $(basename "$0") [power|kb]" >&2
        exit 1
        ;;
esac

# 息屏后顺手收掉虚拟键盘（保持原版行为）
if [ "$(get_brightness)" -eq "$DIM_LEVEL" ]; then
    kb_stop
fi

exit 0
