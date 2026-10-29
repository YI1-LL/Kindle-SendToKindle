#!/bin/sh
# bin/confirm.sh - SendToKindle v1.5.0
# 确认发送 pending 里的文件（取第一行），走 send.sh --force
# 屏幕：FBInk 三行居中，不清屏、不退出 KUAL（沿用 v1.3 已验证写法）

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

if [ ! -f "$PENDING" ]; then
    show_msg "[ -- ] CANCELED" "Back to book list" ""
    log "confirm: no pending"
    sh "$DIR/bin/scan.sh" -q >/dev/null 2>&1
    exit 1
fi

FILE=$(head -n 1 "$PENDING" 2>/dev/null)
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
    show_msg "[ !! ] FAILED!" "Pending file missing" ""
    log "confirm: pending file missing: ${FILE:-<empty>}"
    rm -f "$PENDING"
    sh "$DIR/bin/scan.sh" -q >/dev/null 2>&1
    exit 1
fi

log "confirm: send card for $FILE"

# 交给 send.sh 统一处理（--force 跳过 50MB 拦截）；send.sh 内部会重建菜单
"$DIR/bin/send.sh" "$FILE" "--force"
exit $?
