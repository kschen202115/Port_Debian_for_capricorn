#!/bin/bash

# 亮度调节路径
BRIGHTNESS_PATH="/sys/class/backlight/*/brightness"

# 亮度设置
DIM_BRIGHTNESS_LEVEL=0
MAX_BRIGHTNESS_LEVEL=100

# 获取当前亮度
CURRENT_BRIGHTNESS=$(cat $BRIGHTNESS_PATH)

# 函数：设置屏幕亮度
set_brightness() {
  echo $1 | sudo tee $BRIGHTNESS_PATH > /dev/null
}



# 检查是否提供了 power 参数
if [ "$1" == "power" ]; then
  if [ "$CURRENT_BRIGHTNESS" -eq "$DIM_BRIGHTNESS_LEVEL" ]; then
    set_brightness $MAX_BRIGHTNESS_LEVEL
    echo "屏幕亮度已设置为最大值"
  else
    set_brightness $DIM_BRIGHTNESS_LEVEL
    echo "屏幕亮度已调暗"
  fi
fi

CURRENT_BRIGHTNESS=$(cat $BRIGHTNESS_PATH)

# 管理 buffyboard
if [ -z "$1" ] || [ "$1" == "power" ]; then
  if [ "$CURRENT_BRIGHTNESS" -eq "$DIM_BRIGHTNESS_LEVEL" ]; then
    if pidof buffyboard > /dev/null; then
	    sudo kill $(pidof buffyboard)
	  fi
  fi
fi

# 检查是否提供了 kb 参数
if [ "$1" == "kb" ]; then
  if pidof buffyboard > /dev/null; then
    sudo kill $(pgrep -x buffyboard)
  else
    sudo buffyboard &
  fi
fi

