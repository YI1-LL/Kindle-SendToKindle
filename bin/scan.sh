#!/bin/sh
# bin/scan.sh - SendToKindle v1.5.0
# 生成 KUAL menu.json：清理临时文件 -> 扫描 -> 最近阅读 / 全部书目 / 不支持列表
# 用法: sh bin/scan.sh [-q]      -q 静默（不往屏幕画字）

EXT_DIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
[ -n "$EXT_DIR" ] || EXT_DIR=$(pwd)

DOC_DIR="${DOC_DIR:-/mnt/us/documents}"
MENU_FILE="$EXT_DIR/menu.json"
PENDING_FILE="$EXT_DIR/pending"
LAST_FILE="$EXT_DIR/last.txt"
LOG="$EXT_DIR/scan.log"
MAX_RECENT=10

QUIET=0
[ "$1" = "-q" ] && QUIET=1

# ============ 前置清理（只清 /tmp 自己的残留，绝不动插件目录的 pending）============
rm -f /tmp/Too_Large_*.html 2>/dev/null

TMP_BOOKS="/tmp/stk_books_$$"
TMP_GREY="/tmp/stk_grey_$$"
TMP_RAW="/tmp/stk_raw_$$"
TMP_RECENT="/tmp/stk_recent_$$"
TMP_ALL="/tmp/stk_all_$$"
TMP_GREY_S="/tmp/stk_grey_s_$$"
TMP_TITLE="/tmp/stk_title_$$"
TMP_FOUND="/tmp/stk_found_$$"

cleanup() { rm -f "$TMP_BOOKS" "$TMP_GREY" "$TMP_RAW" "$TMP_RECENT" "$TMP_ALL" "$TMP_GREY_S" "$TMP_TITLE" "$TMP_FOUND"; }
trap cleanup 0 1 2 15

# ============ fbink（与 v1.3 一致：-qpm 底部一行，不清屏、不退出 KUAL）============
FBINK=""
for d in /var/tmp /mnt/us/libkh/bin /mnt/us/koreader /mnt/us/linkss/bin /mnt/us/linkfonts/bin /mnt/us/usbnet/bin /usr/bin /usr/local/bin; do
    if [ -x "$d/fbink" ]; then
        FBINK="$d/fbink"
        break
    fi
done

say() {
    [ "$QUIET" -eq 1 ] && return 0
    [ -n "$FBINK" ] || return 0
    "$FBINK" -qpm -y -5 "$1" >/dev/null 2>&1
}

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

# ============ JSON 转义：反斜杠、双引号、tab、CR ============
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' -e 's/\r/\\r/g'
}

# ============ mtime 多级兼容 ============
_file_mtime() {
    _p="$1"
    [ -e "$_p" ] || { echo 0; return; }
    if stat -c %Y "$_p" >/dev/null 2>&1; then
        stat -c %Y "$_p" 2>/dev/null | head -n 1
    elif stat -f %m "$_p" >/dev/null 2>&1; then
        stat -f %m "$_p" 2>/dev/null | head -n 1
    elif date -r "$_p" +%s >/dev/null 2>&1; then
        date -r "$_p" +%s 2>/dev/null
    elif find "$_p" -maxdepth 0 -printf '%T@\n' >/dev/null 2>&1; then
        find "$_p" -maxdepth 0 -printf '%T@\n' 2>/dev/null | cut -d. -f1
    else
        echo 0
    fi
}

# 原文件 mtime 与同名 .sdr 目录 mtime 的最大值（兼容 book.azw3.sdr / book.sdr）
get_latest_time() {
    _book="$1"
    _latest=$(_file_mtime "$_book")
    case "$_latest" in ''|*[!0-9]*) _latest=0 ;; esac
    for _sdr in "${_book}.sdr" "${_book%.*}.sdr"; do
        [ -d "$_sdr" ] || continue
        _t=$(_file_mtime "$_sdr")
        case "$_t" in ''|*[!0-9]*) _t=0 ;; esac
        [ "$_t" -gt "$_latest" ] && _latest=$_t
    done
    echo "$_latest"
}

# 按 UTF-8 字符边界截断（长书名会把 KUAL 一行撑出屏幕）
trunc_title() {
    printf '%s' "$1" > "$TMP_TITLE"
    _len=$(wc -c < "$TMP_TITLE" | tr -d ' ')
    if [ "$_len" -le "$2" ]; then
        cat "$TMP_TITLE"
        return
    fi
    if command -v od >/dev/null 2>&1; then
        _cut="$2"
        while [ "$_cut" -lt "$_len" ]; do
            _b=$(dd bs=1 skip="$_cut" count=1 < "$TMP_TITLE" 2>/dev/null | od -An -tu1 | tr -d ' \n')
            case "$_b" in
                12[89]|1[3-8][0-9]|19[01]) _cut=$((_cut + 1)) ;;
                *) break ;;
            esac
        done
        dd bs=1 count="$_cut" < "$TMP_TITLE" 2>/dev/null
        printf '…'
        return
    fi
    _head=$(printf '%s' "$1" | head -c "$2")
    _nice=$(printf '%s' "$_head" | sed -e 's/[[:space:]_-][^[:space:]_-]*$//')
    if [ -n "$_nice" ]; then
        printf '%s…' "$_nice"
    else
        printf '书名过长…'
    fi
}

# ============ 扫描书目 ============
# 正常列表：epub pdf txt docx mobi azw3 azw（能推送成功）
# 灰名单：cbz cbr prc pdb（亚马逊不支持邮件推送）
find "$DOC_DIR" -type f 2>/dev/null > "$TMP_FOUND"

: > "$TMP_BOOKS"
: > "$TMP_GREY"
while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    _ext=$(printf '%s' "${_f##*.}" | tr 'A-Z' 'a-z')
    case "$_ext" in
        cbz|cbr|prc|pdb) printf '%s\n' "$_f" >> "$TMP_GREY" ;;
        epub|pdf|txt|docx|mobi|azw3|azw) printf '%s\n' "$_f" >> "$TMP_BOOKS" ;;
    esac
done < "$TMP_FOUND"

BOOK_COUNT=$(wc -l < "$TMP_BOOKS" | tr -d ' ')
[ -n "$BOOK_COUNT" ] || BOOK_COUNT=0
GREY_COUNT=$(wc -l < "$TMP_GREY" | tr -d ' ')
[ -n "$GREY_COUNT" ] || GREY_COUNT=0

# ============ 最近阅读（活动时间降序 + 稳定排序）============
: > "$TMP_RAW"
_seq=0
while IFS= read -r _book; do
    [ -n "$_book" ] || continue
    _seq=$((_seq + 1))
    _t=$(get_latest_time "$_book")
    printf '%s\t%s\t%s\n' "$_t" "$_seq" "$_book" >> "$TMP_RAW"
done < "$TMP_BOOKS"

TAB=$(printf '\t')
if sort -t "$TAB" -k1,1nr -k2,2n "$TMP_RAW" > "$TMP_RAW.sorted" 2>/dev/null; then
    head -n "$MAX_RECENT" "$TMP_RAW.sorted" | cut -f3- > "$TMP_RECENT"
elif sort -nr "$TMP_RAW" > "$TMP_RAW.sorted" 2>/dev/null; then
    head -n "$MAX_RECENT" "$TMP_RAW.sorted" | cut -f3- > "$TMP_RECENT"
else
    head -n "$MAX_RECENT" "$TMP_BOOKS" > "$TMP_RECENT"
fi
rm -f "$TMP_RAW.sorted"
RECENT_COUNT=$(wc -l < "$TMP_RECENT" | tr -d ' ')
[ -n "$RECENT_COUNT" ] || RECENT_COUNT=0

# ============ 全部书目 / 灰名单（A-Z）============
LC_ALL=C sort "$TMP_BOOKS" > "$TMP_ALL" 2>/dev/null || sort "$TMP_BOOKS" > "$TMP_ALL"
LC_ALL=C sort "$TMP_GREY" > "$TMP_GREY_S" 2>/dev/null || sort "$TMP_GREY" > "$TMP_GREY_S"

# ============ pending / last ============
PENDING=""
if [ -f "$PENDING_FILE" ]; then
    PENDING=$(head -n 1 "$PENDING_FILE" 2>/dev/null)
    if [ -n "$PENDING" ] && [ ! -f "$PENDING" ]; then
        PENDING=""
        rm -f "$PENDING_FILE"
    fi
fi
LAST=""
[ -f "$LAST_FILE" ] && LAST=$(head -n 1 "$LAST_FILE" 2>/dev/null)

# ============ 生成 menu.json ============
{
    printf '{\n  "items": [\n'
    printf '    {\n      "name": "Send to Kindle",\n      "items": [\n'

    # [1] 刷新
    printf '        {"name": "%s", "action": "sh %s/bin/scan.sh", "exitmenu": true}' \
        "$(json_escape "[1] 刷新书目 (当前 $BOOK_COUNT 本)")" "$EXT_DIR"

    # [!] / [x] 大文件二次确认
    if [ -n "$PENDING" ]; then
        _pn=$(trunc_title "$(basename "$PENDING")" 48)
        printf ',\n        {"name": "%s", "action": "sh %s/bin/confirm.sh", "exitmenu": true}' \
            "$(json_escape "[!] 确认发送名片: $_pn")" "$EXT_DIR"
        printf ',\n        {"name": "%s", "action": "sh %s/bin/cancel.sh", "exitmenu": true}' \
            "$(json_escape "[x] 取消发送")" "$EXT_DIR"
    fi

    # [2] 删除上次发送
    if [ -n "$LAST" ] && [ -f "$LAST" ]; then
        _ln=$(basename "$LAST")
        printf ',\n        {"name": "%s", "action": "sh %s/bin/delete.sh", "exitmenu": true}' \
            "$(json_escape "[2] 删除上次发送: $_ln")" "$EXT_DIR"
    fi

    # [3] 最近阅读（空则不显示）
    if [ "$RECENT_COUNT" -gt 0 ]; then
        printf ',\n        {"name": "%s", "items": [' \
            "$(json_escape "[3] 最近阅读 (最多 $MAX_RECENT 本)")"
        _first=1
        while IFS= read -r _book; do
            [ -n "$_book" ] || continue
            _n=$(json_escape "$(basename "$_book")")
            _a=$(json_escape "sh $EXT_DIR/bin/send.sh \"$_book\"")
            if [ "$_first" -eq 1 ]; then _first=0; printf '\n'; else printf ',\n'; fi
            printf '          {"name": "%s", "action": "%s", "exitmenu": true}' "$_n" "$_a"
        done < "$TMP_RECENT"
        printf '\n        ]}'
    fi

    # [4] 全部书目
    if [ "$BOOK_COUNT" -gt 0 ]; then
        printf ',\n        {"name": "%s", "items": [' \
            "$(json_escape "[4] 全部书目 (A-Z, $BOOK_COUNT 本)")"
        _first=1
        while IFS= read -r _book; do
            [ -n "$_book" ] || continue
            _n=$(json_escape "$(basename "$_book")")
            _a=$(json_escape "sh $EXT_DIR/bin/send.sh \"$_book\"")
            if [ "$_first" -eq 1 ]; then _first=0; printf '\n'; else printf ',\n'; fi
            printf '          {"name": "%s", "action": "%s", "exitmenu": true}' "$_n" "$_a"
        done < "$TMP_ALL"
        printf '\n        ]}'
    fi

    # [5] 不支持推送（灰名单非空才显示）；子项 exitmenu:false，KUAL 留在菜单里
    if [ "$GREY_COUNT" -gt 0 ]; then
        printf ',\n        {"name": "%s", "items": [' \
            "$(json_escape "[5] 不支持推送 (cbz/cbr/prc/pdb, $GREY_COUNT 本)")"
        _first=1
        while IFS= read -r _book; do
            [ -n "$_book" ] || continue
            _n=$(json_escape "$(basename "$_book")")
            _a=$(json_escape "sh $EXT_DIR/bin/unsupported.sh")
            if [ "$_first" -eq 1 ]; then _first=0; printf '\n'; else printf ',\n'; fi
            printf '          {"name": "%s", "action": "%s", "exitmenu": false}' "$_n" "$_a"
        done < "$TMP_GREY_S"
        printf '\n        ]}'
    fi

    printf '\n      ]\n    }\n  ]\n}\n'
} > "$MENU_FILE"

log "menu: books=$BOOK_COUNT recent=$RECENT_COUNT grey=$GREY_COUNT"
say "LIST UPDATED: $BOOK_COUNT book(s)"
echo "✅ 菜单已重建：正常 $BOOK_COUNT 本 / 最近 $RECENT_COUNT 本 / 不支持 $GREY_COUNT 本"
exit 0
