#!/bin/sh
# bin/cancel.sh - SendToKindle v1.5.0
# 取消大文件发送：删掉 pending，提示后回到书目列表
# 屏幕：FBInk 三行居中，不清屏、不退出 KUAL

DIR=$(cd "$(dirname "$0")/.." && pwd)
PENDING="$DIR/pending"
LOG="$DIR/send.log"

FBINK=""
for d in /var/tmp /mnt/us/libkh/bin /mnt/us/koreader /mnt/us/linkss/bin /mnt/us/linkfonts/bin /mnt/us/usbnet/bin /usr/bin /usr/local/bin; do
    if [ -x "$d/fbink" ]; then
        FBINK="$d/fbink"
        break
    fi
done

EIPS=""
for c in /usr/sbin/eips /usr/bin/eips /bin/eips /sbin/eips; do
    if [ -x "$c" ]; then
        EIPS="$c"
        break
    fi
done

show_msg() {
    if [ -n "$FBINK" ]; then
        "$FBINK" -qpmM -y 0 "$1
$2
$3" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            "$FBINK" -qpm -y -5 "$1" >/dev/null 2>&1
        fi
    elif [ -n "$EIPS" ]; then
        "$EIPS" 8 3 "$1" >/dev/null 2>&1
    fi
}

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

_target=$(head -n 1 "$PENDING" 2>/dev/null)
rm -f "$PENDING"
log "cancel: ${_target:-<empty>}"

show_msg "[ -- ] CANCELED" "Back to book list" ""

sh "$DIR/bin/scan.sh" -q >/dev/null 2>&1
exit 0
