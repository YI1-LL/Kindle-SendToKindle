#!/bin/sh
# bin/send.sh - SendToKindle v1.5.0
# 用法: send.sh <file> [--force]
#
# 行为：
#   < 50MB          → 直接调用 send_to_kindle 发送
#   > 50MB 无 --force → 只写 $DIR/pending，提示回 KUAL 确认（不发信）
#   有 --force       → 跳过 50MB 拦截（confirm.sh 用）
#
# 屏幕：FBInk 三行居中（-qpmM -y 0），不清屏、不退出 KUAL。这是 v1.3 在 KPW6 上验证过的写法，
#       绝不用 fbink -t "$T" / -B 1（那是 TrueType 字体参数，会静默失败变白屏）。

DIR=$(cd "$(dirname "$0")/.." && pwd)
LOG="$DIR/send.log"
PENDING="$DIR/pending"
LAST="$DIR/last.txt"
CONFIG="$DIR/config.ini"
MAX=52428800

# 二进制：优先插件根目录，其次 bin/（两种放法都能跑）
BIN="$DIR/send_to_kindle"
[ -f "$BIN" ] || BIN="$DIR/bin/send_to_kindle"

# ---------------------------------------------------------------- fbink
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

# 三行结果卡：$1 主标题  $2 副标题  $3 第三行（可为空）
show_msg() {
    [ -n "$FBINK" ] || {
        if [ -n "$EIPS" ]; then
            "$EIPS" 8 3 "$1" >/dev/null 2>&1
        fi
        return 0
    }
    "$FBINK" -qpmM -y 0 "$1
$2
$3" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        # 个别 FBInk 不认 -M 时退化为底部一行
        "$FBINK" -qpm -y -5 "$1" >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------- 日志（>500 行截断到 200 行）
write_log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG" 2>/dev/null
    _l=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
    case "$_l" in ''|*[!0-9]*) return ;; esac
    if [ "$_l" -gt 500 ]; then
        tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
        echo "--- log trimmed ---" >> "$LOG"
    fi
}

# ---------------------------------------------------------------- 文件大小（老机型兼容）
get_file_size() {
    _f="$1"
    if stat -c %s "$_f" >/dev/null 2>&1; then
        stat -c %s "$_f" 2>/dev/null | head -n 1
    elif stat -f %z "$_f" >/dev/null 2>&1; then
        stat -f %z "$_f" 2>/dev/null | head -n 1
    elif wc -c < "$_f" >/dev/null 2>&1; then
        wc -c < "$_f" | tr -d ' '
    else
        echo 0
    fi
}

# ---------------------------------------------------------------- 网络自检
# 返回：0 通 / 1 不通 / 2 无法判断（工具不支持，放行）
net_ok() {
    if command -v ping >/dev/null 2>&1; then
        ping -c 1 -W 2 "$1" >/dev/null 2>&1
        _rc=$?
        [ "$_rc" -eq 0 ] && return 0
        ping -c 1 -w 2 "$1" >/dev/null 2>&1
        _rc2=$?
        [ "$_rc2" -eq 0 ] && return 0
    else
        _rc=2
        _rc2=2
    fi

    # ping 不通时，再用 TCP 探一次（有些路由屏蔽 ICMP）
    if command -v nc >/dev/null 2>&1; then
        nc -w 3 "$1" 465 </dev/null >/dev/null 2>&1 && return 0
        return 1
    fi

    # ping 完全没有/选项不支持 → 不拦，让发送自己去报错
    if [ "$_rc" -ge 2 ] || [ "$_rc2" -ge 2 ]; then
        return 2
    fi
    return 1
}

# ================================================================ 主流程
FILE="$1"
FORCE="$2"

if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
    show_msg "[ !! ] FAILED!" "File not found" ""
    write_log "FAILED file not found: ${FILE:-<empty>}"
    exit 1
fi

if [ ! -f "$BIN" ]; then
    show_msg "[ !! ] FAILED!" "Binary missing" ""
    write_log "FAILED binary missing: $BIN"
    exit 1
fi

if [ ! -f "$CONFIG" ]; then
    show_msg "[ !! ] FAILED!" "config.ini missing" ""
    write_log "FAILED config missing: $CONFIG"
    exit 1
fi

# 网络自检
net_ok smtp.qq.com
_net=$?
if [ "$_net" -eq 1 ]; then
    show_msg "[ !! ] NO WIFI" "Check connection" ""
    write_log "NO WIFI: $FILE"
    exit 1
fi

# 大文件拦截
SIZE=$(get_file_size "$FILE")
case "$SIZE" in ''|*[!0-9]*) SIZE=0 ;; esac

if [ "$FORCE" != "--force" ] && [ "$SIZE" -gt "$MAX" ]; then
    printf '%s\n' "$FILE" > "$PENDING"
    show_msg "[ ?? ] > 50MB" "Reopen KUAL to confirm" ""
    write_log "PENDING large file: $FILE ($SIZE bytes)"
    sh "$DIR/bin/scan.sh" -q >/dev/null 2>&1
    exit 0
fi

# 发送
show_msg "[ > > ] SENDING..." "Please wait." ""
write_log "SEND start: $FILE ($SIZE bytes)"

cd "$DIR" || exit 1
OUT=$("$BIN" -config "$CONFIG" -file "$FILE" 2>&1)
RC=$?

LASTLINE=$(printf '%s\n' "$OUT" | tail -n 1)
write_log "RC=$RC | $LASTLINE"

if [ "$RC" -ne 0 ]; then
    case "$LASTLINE" in
        *535*) show_msg "[ !! ] FAILED!" "Error: 535 Auth" "" ;;
        *550*) show_msg "[ !! ] FAILED!" "Error: 550 Mailbox" "" ;;
        *)     show_msg "[ !! ] FAILED!" "Check send.log" "" ;;
    esac
    sh "$DIR/bin/scan.sh" -q >/dev/null 2>&1
    exit 1
fi

# 成功：清 pending、记 last、提示（不跳转、不 sleep）
rm -f "$PENDING"
printf '%s\n' "$FILE" > "$LAST"
show_msg "[ OK ] SENT!" "Check your mailbox." ""
write_log "SENT: $FILE"

sh "$DIR/bin/scan.sh" -q >/dev/null 2>&1
exit 0
