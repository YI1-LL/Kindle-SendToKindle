#!/bin/sh
# cancel.sh —— 取消大文件发送：清掉 pending，菜单回到普通书籍列表
# 由 KUAL 菜单项「[x] 取消发送 (返回选书)」调用，不需要 chmod

PLUGIN_DIR="/mnt/us/extensions/SendToKindle"
LOG="$PLUGIN_DIR/send.log"
PENDING="/tmp/stk_pending.txt"

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

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

draw_card() {
    if [ -n "$FBINK" ]; then
        "$FBINK" -qpmM -y 0 "$1
$2
$3" >/dev/null 2>&1
        rc=$?
        log "fbink rc=$rc"
        if [ "$rc" -ne 0 ]; then
            "$FBINK" -qpm -y -5 "$1" >/dev/null 2>&1
        fi
    elif [ -n "$EIPS" ]; then
        "$EIPS" 8 3 "$1" >/dev/null 2>&1
    fi
}

target=$(head -n 1 "$PENDING" 2>/dev/null)
log "---- cancel: ${target:-<empty>}"

rm -f "$PENDING"

draw_card "CANCELED" "nothing was sent" "book kept on device"

sh "$PLUGIN_DIR/bin/scan.sh" -q >/dev/null 2>&1
exit 0
