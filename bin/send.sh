#!/bin/sh
# send.sh —— KUAL 里点了某本书之后执行：发送 + 全屏结果提示 + 写日志
# 用法：sh /mnt/us/extensions/SendToKindle/bin/send.sh "/mnt/us/documents/xxx.epub"
#
# 反馈机制（两层，保证看得见）：
#   1) eips 全屏白底大字 —— 已在真机验证可用（左上角的 Sending ... 就是它画的）
#   2) lipc-set-prop com.lab126.pillow pillowAlert 系统弹窗 —— 部分机型不出，仍保留
# eips 画不出中文（默认字体无 CJK），所以屏幕大字用 ASCII，弹窗用中文。

PLUGIN_DIR="/mnt/us/extensions/SendToKindle"
BIN="$PLUGIN_DIR/send_to_kindle"
CONFIG="$PLUGIN_DIR/config.ini"
LOG="$PLUGIN_DIR/send.log"
OUT="/tmp/stk_send_out.txt"

# ---------------------------------------------------------------- 工具函数

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n'
}

make_alert() {
    t=$(json_escape "$1")
    x=$(json_escape "$2")
    printf '%s' '{"clientParams":{"alertId":"stkAlert","show":true,"customStrings":[{"matchStr":"alertTitle","replaceStr":"'"$t"'"},{"matchStr":"alertText","replaceStr":"'"$x"'"}]}}'
}

# ---------------------------------------------------------------- 屏幕输出
# KPW6 上的坑（实测过）：
#   * eips 在这代固件是废弃的兼容层，连续多次调用只有最后一次生效 → 只能显示一行
#   * 固定行号（-y 4）遇到换行就会顶出屏幕，而且 -c 清屏会把整个界面刷白
#   * 后台延时重绘会被 KUAL 杀掉，停在"清屏之后"→ 全白
# 现在的做法（自适应、不清屏、不重叠）：
#   -M 垂直居中（整块永远在屏幕内，不管几行）、-m 水平居中、-p 每行补底色
#   不加 -c，所以界面保持原样，只是中间盖一块结果
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

# 结果卡片（ASCII，每行 ≤ 28 字符，不会触发换行）
#   $1 = 主标题   $2 = 副标题   $3 = 第三行
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

# 结果提示：屏幕卡片 + 尝试系统弹窗（只画一次，不留后台进程）
report() {
    json=$(make_alert "$2" "$3")
    lipc-set-prop com.lab126.pillow pillowAlert "$json" 2>/dev/null
    draw_card "$1" "$4" "$5"
}

status() {
    if [ -n "$EIPS" ]; then
        "$EIPS" 1 1 "$1" >/dev/null 2>&1
    fi
}

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

# ---------------------------------------------------------------- 前置检查

target="$1"

if [ -z "$target" ]; then
    echo "❌ 没有指定文件"
    report "NO FILE GIVEN" "缺少参数" "没有指定文件" "no file given" "run in kterm"
    exit 1
fi

if [ ! -f "$target" ]; then
    echo "❌ 文件不存在: $target"
    log "missing: $target"
    report "FILE NOT FOUND" "文件不存在" "选中的文件已被删除或移动" "file not found" "check documents"
    exit 1
fi

if [ ! -f "$BIN" ]; then
    echo "❌ 找不到 $BIN"
    log "binary missing"
    report "NO BINARY" "缺少程序" "缺少 send_to_kindle" "binary missing" "re-copy it"
    exit 1
fi

if [ ! -f "$CONFIG" ]; then
    echo "❌ 找不到 $CONFIG"
    log "config missing"
    report "NO CONFIG" "缺少配置" "缺少 config.ini" "config.ini missing" "re-copy it"
    exit 1
fi

# ---------------------------------------------------------------- 发送

bytes=$(wc -c < "$target" 2>/dev/null)
bytes=$(( ${bytes:-0} + 0 ))
mb=$(( bytes / 1048576 ))

status "Sending ... ($mb MB)"
log "---- send start: $target (${mb} MB)"

"$BIN" -config "$CONFIG" -file "$target" > "$OUT" 2>&1
rc=$?

cat "$OUT"
cat "$OUT" >> "$LOG"
log "---- send end: rc=$rc"

if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$target" > "$PLUGIN_DIR/last.txt"
    log "success: $target"
    if [ "$bytes" -gt 52428800 ]; then
        report "SENT (TXT ONLY)" "已发送说明文件" "原文件超过 50 MB，只推送了说明 TXT" "file > 50MB" "notice txt sent"
    else
        report "SEND OK" "发送成功" "已推送到 Kindle 邮箱，几分钟后自动同步" "check kindle mailbox" "log: SendToKindle"
    fi
else
    log "failed: $target rc=$rc"
    case "$rc" in
        2) reason="SMTP 认证失败：授权码失效或命中风控，详见 send.log" ;;
        *) reason="发送失败，详见 send.log" ;;
    esac
    report "SEND FAILED" "发送失败" "$reason" "rc=$rc  see send.log" "log: SendToKindle"
fi

# 重建菜单（成功后出现 [2] 删除上次发送）；-q 静默
sh "$PLUGIN_DIR/bin/scan.sh" -q >/dev/null 2>&1

exit $rc
