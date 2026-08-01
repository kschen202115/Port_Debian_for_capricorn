#!/bin/bash
# 屏幕开关 + buffyboard（虚拟键盘）开关，由 hkdm 触发。
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
#
# 变更四（本次）：关屏不再是「把背光写 0」，而是真正下电面板。
# 背光写 0 时 DSI 控制器和面板仍在持续刷像素，只是不发光。现在统一交给
# screenctl，它走 fb0/blank(FB_BLANK_POWERDOWN)，DRM fbdev 模拟会转成
# DPMS off -> panel unprepare（display off + 进 sleep + reset 拉低），
# 背光由 drm_panel_disable 一并关掉。亮度值会被记住并在开屏时还原。

set -uo pipefail

SCREENCTL=/usr/local/bin/screenctl
KB_UNIT=buffyboard.service
BLANK=/sys/class/graphics/fb0/blank

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

screen_is_off() {
    local v
    v="$(cat "$BLANK" 2>/dev/null)"
    case "$v" in ''|0) return 1 ;; *) return 0 ;; esac
}

kb_running() { systemctl is-active --quiet "$KB_UNIT"; }
kb_stop()    { kb_running && as_root systemctl stop "$KB_UNIT"; }
kb_start()   { as_root systemctl start "$KB_UNIT"; }

# ---- 主逻辑 ----
ACTION="${1:-}"

case "$ACTION" in
    power)
        if [ -x "$SCREENCTL" ]; then
            as_root "$SCREENCTL" toggle
        else
            echo "power.sh: 找不到 $SCREENCTL" >&2
            exit 1
        fi
        ;;
    kb)
        if kb_running; then
            kb_stop;  echo "buffyboard 已关闭"
        else
            kb_start; echo "buffyboard 已启动"
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
if screen_is_off; then
    kb_stop
fi

exit 0
