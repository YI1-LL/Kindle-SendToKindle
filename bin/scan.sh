#!/bin/sh
# scan.sh —— 扫描 documents 下的电子书，生成 KUAL 菜单（menu.json）
# 用法：sh /mnt/us/extensions/SendToKindle/bin/scan.sh
# 生成后要退出 KUAL 再进一次才看得到新菜单（KUAL 只在启动时读 menu.json）

PLUGIN_DIR="/mnt/us/extensions/SendToKindle"
DOCS_DIR="/mnt/us/documents"
MENU_FILE="$PLUGIN_DIR/menu.json"
TMP_LIST="/tmp/stk_books.txt"
BODY="/tmp/stk_body.txt"
LOG="$PLUGIN_DIR/scan.log"

MAXDEPTH=4        # documents/Downloads/Items01/xxx.epub 在第 3 层，留一层余量
MAX_ITEMS=150     # 单次最多列多少本，太多 KUAL 会卡

# ---------------------------------------------------------------- 屏幕提示
FBINK=""
for d in /var/tmp /mnt/us/libkh/bin /mnt/us/koreader /mnt/us/linkss/bin /mnt/us/linkfonts/bin /mnt/us/usbnet/bin; do
    if [ -x "$d/fbink" ]; then
        FBINK="$d/fbink"
        break
    fi
done

# 屏幕文字只用 ASCII：Kindle 默认字体没有中文/emoji
# 传 -q 时静默（send.sh / delete.sh 自己已经画过结果了，别覆盖）
QUIET=0
[ "$1" = "-q" ] && QUIET=1

say() {
    [ "$QUIET" -eq 1 ] && return 0
    if [ -n "$FBINK" ]; then
        "$FBINK" -qpm -y -5 "$1" >/dev/null 2>&1
    fi
}

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

# JSON 字符串转义：反斜杠、双引号，并去掉换行回车
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n'
}

# ---------------------------------------------------------------- 收集书目
find_books() {
    : > "$TMP_LIST"

    find "$DOCS_DIR" -maxdepth "$MAXDEPTH" -type f \
        \( -iname '*.epub' -o -iname '*.pdf' -o -iname '*.txt' \
           -o -iname '*.docx' -o -iname '*.mobi' -o -iname '*.azw3' \) \
        ! -name 'My Clippings.txt' \
        ! -path "$DOCS_DIR/dictionaries/*" \
        2>/dev/null >> "$TMP_LIST"

    # 老机型 find 不支持 -maxdepth 时退化重试
    if [ ! -s "$TMP_LIST" ]; then
        find "$DOCS_DIR" -type f \
            \( -iname '*.epub' -o -iname '*.pdf' -o -iname '*.txt' \
               -o -iname '*.docx' -o -iname '*.mobi' -o -iname '*.azw3' \) \
            ! -name 'My Clippings.txt' 2>/dev/null >> "$TMP_LIST"
    fi

    # 再退化：纯 shell 通配，只覆盖 documents 根目录
    if [ ! -s "$TMP_LIST" ]; then
        for f in "$DOCS_DIR"/*.epub "$DOCS_DIR"/*.pdf "$DOCS_DIR"/*.txt \
                 "$DOCS_DIR"/*.docx "$DOCS_DIR"/*.mobi "$DOCS_DIR"/*.azw3; do
            [ -f "$f" ] && printf '%s\n' "$f" >> "$TMP_LIST"
        done
    fi

    sort "$TMP_LIST" > "$TMP_LIST.sorted" 2>/dev/null && mv "$TMP_LIST.sorted" "$TMP_LIST"
}

# ---------------------------------------------------------------- 生成菜单
build_menu() {
    : > "$BODY"
    count=0
    skipped=0

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # 这些字符会破坏 KUAL 的命令行解析，跳过并记日志
        case "$f" in
            *'"'*|*'$'*|*'`'*)
                log "skip (unsafe chars): $f"
                skipped=$((skipped + 1))
                continue
                ;;
        esac
        if [ "$count" -ge "$MAX_ITEMS" ]; then
            break
        fi

        # 刻意不做截断：busybox 的 cut -c 按字节切，中文会被切成半个字符，
        # 生成非法 UTF-8 会让 KUAL 解析 menu.json 失败。
        base=$(basename "$f")
        action="sh $PLUGIN_DIR/bin/send.sh \"$f\""

        if [ "$count" -gt 0 ]; then
            printf ',\n' >> "$BODY"
        fi
        printf '        {"name": "%s", "action": "%s", "exitmenu": true}' \
            "$(json_escape "$base")" "$(json_escape "$action")" >> "$BODY"

        count=$((count + 1))
    done < "$TMP_LIST"

    total=$(wc -l < "$TMP_LIST" | tr -d ' ')
    [ -n "$total" ] || total=0

    {
        printf '{\n'
        printf '  "items": [\n'
        printf '    {\n'
        printf '      "name": "Send to Kindle",\n'
        printf '      "items": [\n'
        printf '        {"name": "[1] 刷新书目 (当前 %s 本)", "action": "sh %s/bin/scan.sh", "exitmenu": true}' \
            "$total" "$PLUGIN_DIR"

        if [ -f "$PLUGIN_DIR/last.txt" ]; then
            lastpath=$(head -n 1 "$PLUGIN_DIR/last.txt" 2>/dev/null)
            if [ -n "$lastpath" ] && [ -f "$lastpath" ]; then
                lastname=$(basename "$lastpath")
                printf ',\n        {"name": "[2] 删除上次发送: %s", "action": "sh %s/bin/delete.sh", "exitmenu": true}' \
                    "$(json_escape "$lastname")" "$PLUGIN_DIR"
            fi
        fi

        printf ',\n'
        printf '        {"name": "[3] 选书发送 (%s/%s 本)", "items": [\n' "$count" "$total"
        if [ "$count" -gt 0 ]; then
            cat "$BODY"
        fi
        printf '\n        ]}\n'
        printf '      ]\n'
        printf '    }\n'
        printf '  ]\n'
        printf '}\n'
    } > "$MENU_FILE"

    log "menu rebuilt: total=$total shown=$count skipped=$skipped"
    say "LIST UPDATED: $count book(s) - reopen KUAL"
    echo "✅ 已重建菜单：共扫描到 $total 本，列出 $count 本，跳过 $skipped 本"
    echo "   菜单文件: $MENU_FILE"
    echo "   退出 KUAL 再重新进入，即可看到书目。"
}

if [ ! -d "$DOCS_DIR" ]; then
    say "ERROR: documents dir not found"
    echo "❌ 找不到 $DOCS_DIR"
    exit 1
fi

find_books

if [ ! -s "$TMP_LIST" ]; then
    say "NO BOOKS FOUND in documents"
    echo "📭 $DOCS_DIR 下没有可发送的电子书（epub/pdf/txt/docx/mobi/azw3）"
    log "no books found"
    exit 1
fi

build_menu
