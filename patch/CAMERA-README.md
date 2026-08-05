# Xiaomi Mi 5s (capricorn) 摄像头使用说明

mainline 6.19 + camss。两颗传感器和对焦马达都已可用，出的是**裸 Bayer RAW**，
没有 ISP 处理——白平衡、去马赛克、镜头阴影校正都要自己做或交给 libcamera。

---

## 1. 硬件与节点对照

| 部件 | 型号 | i2c | 驱动 | subdev |
|---|---|---|---|---|
| 后摄 | Sony IMX378 | `3-0010` (CCI master 0) | `imx378` | `/dev/v4l-subdev18` |
| 后摄对焦马达 | AKM AK7371 | `3-000c` | `ak7375` | `/dev/v4l-subdev19` |
| 前摄 | OmniVision OV4688 | `4-0036` (CCI master 1) | `ov4689` | `/dev/v4l-subdev17` |

> subdev 编号不是固定的，开机顺序变了会变。稳妥做法是按名字查：
> ```bash
> for s in /sys/class/video4linux/v4l-subdev*/name; do
>     echo "$(basename $(dirname $s)): $(cat $s)"
> done
> ```

**camss 视频节点**（`/dev/media0`）：

```
video0  msm_vfe0_video0     video3  msm_vfe1_video0
video1  msm_vfe0_video1     video4  msm_vfe1_video1
video2  msm_vfe0_video2     video5  msm_vfe1_video2
video6  qcom-venus-decoder  video7  qcom-venus-encoder   ← 这两个是编解码器，不是相机
```

**pipeline 走向**：`传感器 → csiphy → csid → ispif → vfe_rdi → video 节点`

- 后摄接 CSIPHY0，前摄接 CSIPHY2（这两条是 IMMUTABLE 链路，DT 定死的）
- csiphy → csid → ispif → vfe 之间是交叉开关，**每次开机都要手动连**

---

## 2. 内核配置

```
CONFIG_VIDEO_QCOM_CAMSS=m
CONFIG_I2C_QCOM_CCI=m
CONFIG_VIDEO_IMX378=m        # 本地补丁引入
CONFIG_VIDEO_OV4689=m        # 前摄，chip id 0x4688 就是 OV4688
CONFIG_VIDEO_AK7375=m        # 对焦马达，AK7371 与 AK7375 寄存器兼容
CONFIG_V4L2_CCI_I2C=y        # 被上面几个 select 自动带上
```

用到的工具：

```bash
sudo apt install v4l-utils        # v4l2-ctl, media-ctl
```

---

## 3. 前摄拍一张

```bash
#!/bin/bash
M=/dev/media0

# 连 pipeline: ov4689 -> csiphy2 -> csid0 -> ispif0 -> vfe0_rdi0 -> video0
media-ctl -d $M -l '"msm_csiphy2":1->"msm_csid0":0[1]'
media-ctl -d $M -l '"msm_csid0":1->"msm_ispif0":0[1]'
media-ctl -d $M -l '"msm_ispif0":1->"msm_vfe0_rdi0":0[1]'

# 整条链路格式必须一致，否则 STREAMON 报 -EPIPE
FMT='fmt:SBGGR10_1X10/2688x1520'
for e in "ov4689 4-0036" msm_csiphy2 msm_csid0 msm_ispif0 msm_vfe0_rdi0; do
    media-ctl -d $M -V "\"$e\":0[$FMT]"
done

v4l2-ctl -d /dev/video0 \
    --set-fmt-video=width=2688,height=1520,pixelformat=pBAA \
    --stream-mmap=4 --stream-count=3 --stream-to=front.raw
```

- Bayer 排列 **BGGR**，`pBAA` = MIPI RAW10 packed
- 分辨率只有 2688x1520 一档（驱动里就一个 mode）
- stride = 2688 × 1.25 = **3360** 字节，正好没有 padding

---

## 4. 后摄拍一张（含对焦）

```bash
#!/bin/bash
M=/dev/media0

# ⚠️ 关键：全程持有 VCM 的 subdev fd，否则一关闭镜头就被弹簧拉回原位
exec 9<> /dev/v4l-subdev19

# 连 pipeline: imx378 -> csiphy0 -> csid0 -> ispif0 -> vfe0_rdi0 -> video0
media-ctl -d $M -l '"msm_csiphy0":1->"msm_csid0":0[1]'
media-ctl -d $M -l '"msm_csid0":1->"msm_ispif0":0[1]'
media-ctl -d $M -l '"msm_ispif0":1->"msm_vfe0_rdi0":0[1]'

W=2028; H=1520                      # 想要全分辨率就用 4056 3040
FMT="fmt:SRGGB10_1X10/${W}x${H}"
for e in "imx378 3-0010" msm_csiphy0 msm_csid0 msm_ispif0 msm_vfe0_rdi0; do
    media-ctl -d $M -V "\"$e\":0[$FMT]"
done

# 曝光 / 增益（没有自动曝光，全靠手调）
v4l2-ctl -d /dev/v4l-subdev18 \
    --set-ctrl=exposure=1200 \
    --set-ctrl=analogue_gain=300 \
    --set-ctrl=digital_gain=1024

# 对焦：0 = 无穷远侧，4095 = 微距侧
v4l2-ctl -d /dev/v4l-subdev19 --set-ctrl=focus_absolute=400
sleep 0.5

v4l2-ctl -d /dev/video0 \
    --set-fmt-video=width=$W,height=$H,pixelformat=pRAA \
    --stream-mmap=4 --stream-count=5 --stream-to=rear.raw

exec 9<&-
```

- Bayer 排列 **RGGB**，`pRAA` = MIPI RAW10 packed
- 支持的分辨率：`4056x3040` `4056x2160` `2028x1520` `2028x1080` `1332x990`
- 传感器也能出 12 位（`SRGGB12_1X12` / `pRCC`），本地只验过 10 位

**stride 有 padding，别按 width×1.25 算**，用 v4l2 报的值：

```bash
v4l2-ctl -d /dev/video0 --get-fmt-video | grep -E 'Bytes per Line|Size Image'
```

| 分辨率 | Bytes per Line | Size Image |
|---|---|---|
| 2028x1520 | 2536（有效 2535） | 3,854,720 |
| 4056x3040 | 5072（有效 5070） | 15,418,880 |

---

## 5. 控件范围

| 控件 | subdev | 范围 | 默认 |
|---|---|---|---|
| `exposure` | imx378 | 4 – 1550 | 1536 |
| `analogue_gain` | imx378 | 0 – 2047 | 128 |
| `digital_gain` | imx378 | 1 – 32767 | 2048 |
| `focus_absolute` | ak7375 | 0 – 4095 | 0 |

亮度大致关系：室内灯光下 `exposure=1200 / analogue_gain=300 / digital_gain=1024`
出来的绿通道均值约 280/1023，比较合适。默认值在室内会**过曝到 1022**。

---

## 6. 解 RAW10 并出图

MIPI RAW10 打包格式：**每 5 字节存 4 个像素**——前 4 字节是 4 个像素的高 8 位，
第 5 字节按 2 位一组存它们的低 2 位（像素 0 在 bit[1:0]，像素 3 在 bit[7:6]）。

```python
#!/usr/bin/env python3
import numpy as np
from PIL import Image

W, H, STRIDE = 2028, 1520, 2536      # 后摄 binning 模式
BAYER = 'RGGB'                       # 后摄 RGGB，前摄 BGGR
FRAME = STRIDE * H

d = open('rear.raw', 'rb').read()
raw = np.frombuffer(d[-FRAME:], dtype=np.uint8).reshape(H, STRIDE)   # 取最后一帧

use = (W * 5) // 4                   # 有效字节数，尾部是对齐 padding
g   = raw[:, :use].reshape(H, use // 5, 5)
hi  = g[:, :, :4].astype(np.uint16)
lo  = g[:, :, 4].astype(np.uint16)
px  = np.empty((H, (use // 5) * 4), dtype=np.uint16)
for i in range(4):
    px[:, i::4] = (hi[:, :, i] << 2) | ((lo >> (2 * i)) & 3)
px = px[:, :W].astype(np.float32)

px = np.clip(px - 64.0, 0, None)     # 减黑电平，Sony pedestal = 64

if BAYER == 'RGGB':
    R = px[0::2, 0::2]; G1 = px[0::2, 1::2]; G2 = px[1::2, 0::2]; B = px[1::2, 1::2]
else:                                # BGGR
    B = px[0::2, 0::2]; G1 = px[0::2, 1::2]; G2 = px[1::2, 0::2]; R = px[1::2, 1::2]
G = (G1 + G2) / 2

# 灰世界白平衡（有强光源时会偏，正经做法要 AWB）
mr, mg, mb = R.mean(), G.mean(), B.mean()
R *= mg / mr
B *= mg / mb

rgb = np.stack([R, G, B], -1)
rgb = np.clip(rgb / np.percentile(rgb, 99.0), 0, 1) ** (1 / 2.2)
Image.fromarray((rgb * 255).astype(np.uint8)).save('out.png')
```

这个脚本是 **2x2 合并**（每个 Bayer 单元出一个 RGB 像素），所以输出分辨率减半。
要全分辨率就得真做去马赛克（双线性 / Malvar），或者交给 libcamera。

---

## 7. 简易自动对焦

没有 AF 算法，但可以扫一遍取锐度最高的位置。用绿通道的梯度能量做指标：

```bash
#!/bin/bash
exec 9<> /dev/v4l-subdev19           # 整个扫描期间不能松手
for P in 0 400 800 1200 1600 2000 2400 2800 3200 3600 4000; do
    v4l2-ctl -d /dev/v4l-subdev19 --set-ctrl=focus_absolute=$P
    sleep 0.4
    v4l2-ctl -d /dev/video0 --set-fmt-video=width=2028,height=1520,pixelformat=pRAA \
        --stream-mmap=4 --stream-count=4 --stream-to=/tmp/f$P.raw >/dev/null 2>&1
done
exec 9<&-
# 然后对每个文件算 sum(dx^2 + dy^2)，取最大的那个位置
```

实测（室内中景）：

```
focus    锐度   相对
    0   116.4   93%
  400   125.5  100%   ← 峰值
  800   122.0   97%
 2000   111.1   89%
 4000   109.3   87%   ← 最模糊
```

DAC 越大镜头越往微距推。拍远景就用小值，拍近物往大了调。

---

## 8. 坑

**VCM 一断电镜头就弹回去。** `ak7375_close()` 会 `pm_runtime_put`，
regulator 一关镜头就被弹簧拉回原位。所以**设焦距和抓帧必须在同一个
持有 subdev fd 的进程/脚本里**。分成两条 `v4l2-ctl` 命令跑是没用的——
我第一次就是这么测的，扫了 8 个焦距位置结果一模一样。

**pipeline 链路开机后是断的。** camss 的 csid/ispif/vfe 是交叉开关，
每次开机都要 `media-ctl -l` 重新连。写进开机脚本比较省事。

**整条链路格式必须逐级一致。** 任何一级对不上，`STREAMON` 会返回
`-EPIPE`。camss 有详细的校验日志，打开就能看到卡在哪一级：

```bash
echo 'module qcom_camss +p' | sudo tee /sys/kernel/debug/dynamic_debug/control
```

**前后摄同时用要走不同的 VFE。** 一个用 `csid0→ispif0→vfe0_rdi0→video0`，
另一个用 `csid1→ispif1→vfe1_rdi0→video3`。没实测过双路同开。

**没有自动曝光。** 默认曝光在室内会过曝到 1022（10 位满量程 1023），
必须手动调。

---

## 9. libcamera + SoftISP（推荐，已验证可用）

比手搓解 RAW 省事得多——自动曝光、自动白平衡、真正的去马赛克，
输出直接就是 RGB。

```bash
sudo apt install libcamera-tools libcamera-ipa
```

Debian 13 里是 libcamera 0.4.0，`simple` pipeline handler 已经支持
qcom-camss，装完直接就能认到两颗：

```console
$ cam -l
Available cameras:
1: Internal front camera (/base/soc@0/cci@a0c000/i2c-bus@1/camera-sensor@36)
2: Internal back camera (/base/soc@0/cci@a0c000/i2c-bus@0/camera-sensor@10)
```

（前/后是从 DT 里的 `orientation` 属性来的）

### ⚠️ `cam -c` 的数字编号和 `cam -l` 的列表顺序对不上

这是个很容易中招的坑。`cam -l` 列出来是 `1: front / 2: back`，但
**`-c 1` 实际选中的是 back，`-c 2` 是 front**——正好反的。我就是这么
拿前摄拍了一张还以为是后摄。

**永远用完整 camera ID，别用数字：**

```bash
# 后摄 IMX378
cam -c '/base/soc@0/cci@a0c000/i2c-bus@0/camera-sensor@10' ...
# 前摄 OV4688
cam -c '/base/soc@0/cci@a0c000/i2c-bus@1/camera-sensor@36' ...
```

日志里的 `Using camera ...` 那一行会明确告诉你实际选中了谁，拍完核对一下。

### 抓帧

```bash
REAR='/base/soc@0/cci@a0c000/i2c-bus@0/camera-sensor@10'
cam -c "$REAR" -C45 -s role=viewfinder,pixelformat=RGB888,width=2028,height=1520 \
    --file=/tmp/shot_#.bin
```

**必须显式要 `pixelformat=RGB888`。** 不指定的话后摄会被配成
`1332x990-SRGGB12_CSI2P`——12 位裸 Bayer，SoftISP 不支持，一帧都不会输出，
只会刷屏 `Unsupported input format SRGGB12_CSI2P`。

输出的 stride 有 padding，别按 `width×3` 算：

| 请求 | 实际配置 | 每帧字节 | stride |
|---|---|---|---|
| 后摄 2028x1520 | 2020x1520-RGB888 | 9,217,280 | 6064（W×3=6060） |
| 前摄 2688x1520 | 2680x1520-ABGR8888 | 16,294,400 | 10720 |

实测帧率能到 90 fps（SoftISP 多线程去马赛克）。

### 其它注意事项

- **前十几帧很暗**，AE 要时间收敛，抓 40+ 帧取最后一张
- **libcamera 不管对焦**，VCM 还是要自己控，而且同样要全程持有
  ak7375 的 subdev fd（见第 7 节）
- 剩下这两条 warning 是编译期的事，配置文件解决不了，不影响使用：
  ```
  No static properties available for 'imx378'
  Failed to create camera sensor helper for imx378
  ```
  前者在 `camera_sensor_properties.cpp`，后者在 `camera_sensor_helper.cpp`，
  都要给 libcamera 打补丁注册型号才能消掉。后者会让 AGC 的增益换算
  不够线性，曝光调节没那么跟手

### ⚠️ 手动玩过 pipeline 之后要重启

用 `media-ctl -l` 手动连过链路、或者有过失败的 `STREAMON` 之后，
camss 的 subdev 会残留 streaming 状态，之后 libcamera 会报：

```
Failed to setup link 'msm_csiphy0'[1] -> 'msm_csid0'[0]: Device or resource busy
WARNING: v4l2-subdev.c:484 at call_s_stream    (s_stream_enabled 没复位)
```

`rmmod imx378 ov4689 ak7375 qcom_camss` 再 modprobe 有时能救，
**但最可靠的是直接重启**。干净启动后第一次跑 libcamera 一次就过。

## 10. 配置文件

### SoftISP tuning file

装到 `/usr/share/libcamera/ipa/simple/`：

```yaml
# imx378.yaml —— 后摄
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
      blackLevel: 4096
  - Awb:
  - Lut:
  - Agc:
```

`ov4689.yaml` 内容相同（两颗的黑电平基准都是 10 位下的 64）。

`blackLevel` 是 **16 位刻度**：10 位的 64 换算过来是 `64 << 6 = 4096`。
不给这个值的话 BLC 算法要自己估基准，暗场景下容易估低，AWB 和 AGC
会跟着一起偏。装好之后 `Configuration file 'imx378.yaml' not found`
那条 warning 就没了。

这只是最小可用版本。要真正把颜色做准还需要色彩矩阵（CCM）和镜头阴影
校正，素材是 vendor.img 里那 95 个 `libchromatix_imx378_*.so`。

### capture.sh

`camera-config/capture.sh`，装到 `/usr/local/bin/`。把上面所有坑都包好了：
按名字找 subdev（编号会漂）、用完整 ID 选相机、持有 VCM fd、显式要
RGB888、抓够帧数等 AE 收敛。

```bash
sudo capture.sh rear 45 400      # 后摄，45 帧，焦距 400
sudo capture.sh front 45         # 前摄
```

## 11. 还没做的

- **完整 tuning file** —— 现在只有 blackLevel，还缺 CCM 和镜头阴影校正
- **镜头阴影 / AWB 标定** —— 后摄 i2c `3-0050` 上那颗 EEPROM 里存着出厂标定
  数据，厂商 HAL 里 `libmmcamera_ov4688_eeprom.so` 有解析逻辑
- **调优参数** —— vendor.img 里有 95 个 `libchromatix_imx378_*.so`，
  是做 libcamera tuning file 的原始素材
- **PDAF 相位对焦** —— 后摄支持（`libSonyIMX378PdafLibrary.so`），
  mainline 基本没有这块支持
- **12 位模式** —— 传感器和 camss 都支持，没验过
