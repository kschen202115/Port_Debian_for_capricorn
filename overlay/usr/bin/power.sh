#!/bin/bash
# 亮度切换 + buffyboard（虚拟键盘）开关，由 hkdm 触发。
#
# 原版被 YAML -> bash -c "..." -> heredoc 三层引号毁掉了，生成出来是：
#   BRIGHTNESS_PATH=/sys/class/backlight/*/brightness   引号丢失
#   CURRENT_BRIGHTNESS=                                 $(...) 在 runner 上就被展开了
#   if [  == power ]; then                              $1 消失，运行时语法错误
# 这里是重写版。

set -uo pipefail

# ---- 定位 backlight 设备 ----
# glob 只在这里展开一次，后面全部用引号安全引用
BL_DIR=""
for d in /sys/class/backlight/*/; do
    if [ -w "${d}brightness" ] || [ -r "${d}brightness" ]; then
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
if [ -r "$MAX_FILE" ]; then
    MAX_LEVEL="$(cat "$MAX_FILE")"
else
    MAX_LEVEL=100
fi

# ---- 工具函数 ----
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

get_brightness() {
    cat "$BRIGHTNESS_FILE" 2>/dev/null || echo 0
}

set_brightness() {
    echo "$1" | as_root tee "$BRIGHTNESS_FILE" >/dev/null
}

kb_running() {
    pgrep -x buffyboard >/dev/null 2>&1
}

kb_stop() {
    kb_running && as_root pkill -x buffyboard
}

kb_start() {
    as_root buffyboard >/dev/null 2>&1 &
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
