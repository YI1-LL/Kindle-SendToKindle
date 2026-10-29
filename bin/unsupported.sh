#!/bin/sh
# bin/unsupported.sh - SendToKindle v1.5.0
# 灰名单（cbz / cbr / prc / pdb）点击后调用：
#   - 不发送、不写 pending、不走 50MB 拦截、不写 send.log 失败记录
#   - 只在屏幕底部两行提示，然后 exit 0
#
# 用底部两行（-y -6 / -y -5）而不是居中卡片：菜单项是 exitmenu:false，
# KUAL 会重绘菜单，居中卡片会被盖掉；底部两行是 KindleBTH「查看本机IP」验证过能留住的位置。

DIR=$(cd "$(dirname "$0")/.." && pwd)

FBINK=""
for d in /var/tmp /mnt/us/libkh/bin /mnt/us/koreader /mnt/us/linkss/bin /mnt/us/linkfonts/bin /mnt/us/usbnet/bin /usr/bin /usr/local/bin; do
    if [ -x "$d/fbink" ]; then
        FBINK="$d/fbink"
        break
    fi
done

if [ -n "$FBINK" ]; then
    "$FBINK" -qpm -y -6 "[ !! ] NOT SUPPORTED" >/dev/null 2>&1
    "$FBINK" -qpm -y -5 "Use epub/pdf instead" >/dev/null 2>&1
else
    # 没有 fbink 时退化为 KUAL 自己的输出（KUAL 会把 stdout 画到屏幕）
    echo "[ !! ] NOT SUPPORTED"
    echo "Use epub/pdf instead"
fi

# 正常退出：KUAL 自己回到上一级菜单，不跳转、不 sleep、不挂起
exit 0
