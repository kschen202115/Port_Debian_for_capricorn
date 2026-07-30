#!/bin/bash
# 等 USB gadget serial 设备出现后自动登录。
# 原版只重定向了 stdin，依赖 systemd 的 TTYPath 提供 stdout；
# 这里显式用 <> 读写方式打开，systemd 侧就不必在设备还不存在时去 open 它了。
set -u

TTY_DEV=/dev/ttyGS0
LOGIN_USER="${1:-kschen}"

while [ ! -c "$TTY_DEV" ]; do
    sleep 5
done

exec setsid login -f "$LOGIN_USER" <> "$TTY_DEV" >&0 2>&1
