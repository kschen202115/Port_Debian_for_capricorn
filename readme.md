Port_Debian_for_capricorn

默认账户kschen
密码1

将固件添加到firmware文件中（记得位置放对）

至于固件来源，我是从其他包里面提取出来的lib/firmware

内核配置为config文件，请自行修改

如果要自定义其他包，例如mobian，kail，ubuntu，可以自己替换rootfs文件的

这个包是基于Debian12，自带串口登录（内核支持），tty键盘（音量键开关），电源键开关屏幕长按关机

注意这个包极度精简，很多基本软件都没有，第一次登录请执行 sudo resize2fs <分区> 不然大小只有5g

