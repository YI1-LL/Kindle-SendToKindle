#!/bin/sh
# confirm.sh —— 大文件（>50MB）二次确认后，发送 HTML 试读名片
# 由 KUAL 菜单项「[!] 确认发送名片: 书名」调用，不需要 chmod（菜单里用 sh 调用）
#
# 屏幕反馈与 send.sh 一致：FBInk -M 垂直居中 + -m 水平居中 + -p 补底色，不清屏、不退出 KUAL

PLUGIN_DIR="/mnt/us/extensions/SendToKindle"
BIN="$PLUGIN_DIR/send_to_kindle"
CONFIG="$PLUGIN_DIR/config.ini"
LOG="$PLUGIN_DIR/send.log"
OUT="/tmp/stk_send_out.txt"
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

# 三行短文本，垂直居中，不清屏
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

if [ -z "$target" ] || [ ! -f "$target" ]; then
    echo "❌ 没有待发送的文件（pending 为空或文件已删除）"
    log "confirm: no pending file"
    rm -f "$PENDING"
    draw_card "NO PENDING FILE" "nothing to send" "menu refreshed"
    sh "$PLUGIN_DIR/bin/scan.sh" -q >/dev/null 2>&1
    exit 1
fi

if [ ! -f "$BIN" ] || [ ! -f "$CONFIG" ]; then
    echo "❌ 缺少 send_to_kindle 或 config.ini"
    log "confirm: binary/config missing"
    draw_card "SEND FAILED" "binary or config missing" "log: SendToKindle"
    exit 1
fi

log "---- confirm card start: $target"
"$BIN" -config "$CONFIG" -file "$target" > "$OUT" 2>&1
rc=$?

cat "$OUT"
cat "$OUT" >> "$LOG"
log "---- confirm card end: rc=$rc"

if [ "$rc" -eq 0 ]; then
    rm -f "$PENDING"
    draw_card "SEND OK" "preview card sent" "log: SendToKindle"
else
    # 失败时保留 pending，方便用户改完 config 再点一次确认
    draw_card "SEND FAILED" "card not sent, pending kept" "log: SendToKindle"
fi

sh "$PLUGIN_DIR/bin/scan.sh" -q >/dev/null 2>&1
exit $rc
