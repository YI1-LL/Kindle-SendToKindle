#!/bin/sh
# bin/delete.sh - SendToKindle v1.5.0
# 删除"上次发送成功"的本地文件（含同名 .sdr 阅读记录），然后重建菜单
# 屏幕：FBInk 三行居中（与 send.sh 一致），不清屏、不退出 KUAL

DIR=$(cd "$(dirname "$0")/.." && pwd)
LAST="$DIR/last.txt"
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

target=$(head -n 1 "$LAST" 2>/dev/null)

if [ -z "$target" ] || [ ! -f "$target" ]; then
    show_msg "[ -- ] NOTHING" "No file to delete" ""
    log "delete: nothing (${target:-<empty>})"
    rm -f "$LAST"
    sh "$DIR/bin/scan.sh" -q >/dev/null 2>&1
    exit 0
fi

case "$target" in
    *.*) sdr="${target%.*}.sdr" ;;
    *)   sdr="$target.sdr" ;;
esac

name=$(basename "$target")

if rm -f "$target"; then
    if [ -d "$sdr" ]; then
        rm -rf "$sdr" 2>/dev/null
        log "delete: $target (+ $sdr)"
        show_msg "[ OK ] DELETED" "Book and progress removed" ""
    else
        log "delete: $target"
        show_msg "[ OK ] DELETED" "Book removed" ""
    fi
    rm -f "$LAST"
else
    log "delete FAILED: $target"
    show_msg "[ !! ] FAILED!" "Delete failed (read-only?)" ""
fi

sh "$DIR/bin/scan.sh" -q >/dev/null 2>&1
exit 0
