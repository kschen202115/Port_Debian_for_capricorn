#!/bin/bash
# capricorn 相机抓拍helper
#   用法: capture.sh [rear|front] [帧数] [焦距]
#   例:   capture.sh rear 45 400
set -e

WHICH=${1:-rear}
FRAMES=${2:-45}
FOCUS=${3:-400}
OUT=${OUT:-/tmp/capture}

REAR_ID='/base/soc@0/cci@a0c000/i2c-bus@0/camera-sensor@10'
FRONT_ID='/base/soc@0/cci@a0c000/i2c-bus@1/camera-sensor@36'

case "$WHICH" in
  rear)  ID="$REAR_ID";  W=2028; H=1520 ;;
  front) ID="$FRONT_ID"; W=2688; H=1520 ;;
  *) echo "用法: $0 [rear|front] [帧数] [焦距]"; exit 1 ;;
esac

# ---- 传感器 subdev 有残留 streaming 状态时重新加载可以清掉 ----
reset_sensor() {
    local mod=$1
    if lsmod | grep -q "^$mod "; then
        rmmod "$mod" 2>/dev/null || true
        sleep 1
        modprobe "$mod"
        sleep 2
    fi
}

# ---- 按名字找 subdev，编号每次开机可能不一样 ----
find_subdev() {
    local want=$1
    for s in /sys/class/video4linux/v4l-subdev*/name; do
        if grep -q "$want" "$s"; then
            echo "/dev/$(basename "$(dirname "$s")")"
            return
        fi
    done
}

rm -f "$OUT"_*.bin
mkdir -p "$(dirname "$OUT")"

if [ "$WHICH" = rear ]; then
    VCM=$(find_subdev ak7375)
    if [ -z "$VCM" ]; then
        echo "警告: 找不到 ak7375 对焦马达，跳过对焦"
    else
        echo "对焦马达: $VCM  focus=$FOCUS"
        # 关键: 整个抓帧过程必须持有这个 fd，一松手镜头就被弹簧拉回原位
        exec 9<> "$VCM"
        v4l2-ctl -d "$VCM" --set-ctrl=focus_absolute="$FOCUS"
        sleep 0.5
    fi
fi

echo "抓 $FRAMES 帧 ($WHICH, ${W}x${H})，前十几帧 AE 还没收敛，取最后一张"
# 必须用完整 camera ID —— cam -c 的数字编号和 cam -l 的列表顺序对不上
cam -c "$ID" -C"$FRAMES" \
    -s role=viewfinder,pixelformat=RGB888,width=$W,height=$H \
    --file="${OUT}_#.bin" > /tmp/capture.log 2>&1 || true

[ -n "${VCM:-}" ] && exec 9<&- || true

LAST=$(ls ${OUT}_*.bin 2>/dev/null | tail -1)
if [ -z "$LAST" ]; then
    echo "抓帧失败，日志:"
    grep -viE 'Unsupported input format' /tmp/capture.log | tail -5
    echo
    echo "提示: 之前手动 media-ctl 玩过 pipeline 的话 subdev 会残留 streaming 状态，"
    echo "      试试 '$0 --reset' 或者直接重启"
    exit 1
fi

grep -E 'configuring streams' /tmp/capture.log | tail -1
echo "输出: $LAST ($(stat -c%s "$LAST") 字节)"
echo
echo "转 PNG:"
echo "  STRIDE=\$(( \$(stat -c%s $LAST) / $H ))"
echo "  ffmpeg -f rawvideo -pix_fmt bgr24 -s ${W}x${H} -i $LAST -frames:v 1 out.png"
echo "  # stride 有 padding 时 ffmpeg 会错位，用 README 里的 python 脚本更稳"
