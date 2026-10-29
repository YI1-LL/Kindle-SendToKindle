#!/bin/sh
# scan.sh —— 扫描 documents 下的电子书，生成 KUAL 菜单（menu.json）
# 用法：sh /mnt/us/extensions/SendToKindle/bin/scan.sh [-q]
#   -q 静默（不写屏幕），供 send.sh / confirm.sh / cancel.sh 调用
# 生成后要退出 KUAL 再进一次才看得到新菜单（KUAL 只在启动时读 menu.json）

PLUGIN_DIR="/mnt/us/extensions/SendToKindle"
DOCS_DIR="/mnt/us/documents"
MENU_FILE="$PLUGIN_DIR/menu.json"
TMP_LIST="/tmp/stk_books.txt"
BODY="/tmp/stk_body.txt"
LOG="$PLUGIN_DIR/scan.log"
PENDING="/tmp/stk_pending.txt"

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

QUIET=0
[ "$1" = "-q" ] && QUIET=1

# 屏幕文字只用 ASCII：Kindle 默认字体没有中文/emoji
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

# 从文件名里洗掉下载站后缀，得到一个像样的书名（只做 ASCII 安全的部分）
pending_title() {
    b=$(basename "$1")
    b=$(printf '%s' "$b" | sed -e 's/\.[A-Za-z0-9]\{1,5\}$//')
    b=$(printf '%s' "$b" | sed -e 's/[-_ ]*cdeKey[_-]*[0-9A-Fa-f]*//g')
    b=$(printf '%s' "$b" | sed -e 's/_[0-9A-F]\{16,\}//g')
    b=$(printf '%s' "$b" | sed -e 's/[[:space:]]*([^)]*[Zz]-[Ll]ibrary[^)]*)//g')
    b=$(printf '%s' "$b" | sed -e 's/[[:space:]]*([^)]*1lib[^)]*)//g')
    b=$(printf '%s' "$b" | sed -e 's/[[:space:]]*-\{0,1\}[[:space:]]*副本//g')
    b=$(printf '%s' "$b" | sed -e 's/^[[:space:]_-]*//' -e 's/[[:space:]_-]*$//')
    printf '%s' "$b"
}

# 按「字符边界」截断，绝不切坏中文（busybox 的 cut -c 是按字节切的，会把中文切成半个）
# 参数：$1 文本，$2 最大字节数（48 字节 ≈ 16 个汉字，KUAL 一行放得下）
# 优先用 od 精确判断续字节；没有 od 时退化为「在 ASCII 分隔符处断开」，同样不会切坏中文
trunc_title() {
    tfile="/tmp/stk_title.raw"
    printf '%s' "$1" > "$tfile"
    tlen=$(wc -c < "$tfile" | tr -d ' ')
    if [ "$tlen" -le "$2" ]; then
        cat "$tfile"
        return
    fi

    if command -v od >/dev/null 2>&1; then
        cut="$2"
        while [ "$cut" -lt "$tlen" ]; do
            b=$(dd bs=1 skip="$cut" count=1 < "$tfile" 2>/dev/null | od -An -tu1 | tr -d ' \n')
            case "$b" in
                12[89]|1[3-8][0-9]|19[01]) cut=$((cut + 1)) ;;   # 128-191 = UTF-8 续字节
                *) break ;;
            esac
        done
        dd bs=1 count="$cut" < "$tfile" 2>/dev/null
        printf '…'
        return
    fi

    # 没有 od：切在空格/下划线/连字符之后（这些都是单字节，断开处一定在字符边界）
    head_part=$(printf '%s' "$1" | head -c "$2")
    nice_part=$(printf '%s' "$head_part" | sed -e 's/[[:space:]_-][^[:space:]_-]*$//')
    if [ -n "$nice_part" ]; then
        printf '%s…' "$nice_part"
    else
        printf '书名过长…'
    fi
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

    # 二次确认：send.sh 把 >50MB 的书写进 PENDING，这里就多出两个菜单项
    pending_ok=0
    pending_name=""
    if [ -f "$PENDING" ]; then
        pending_file=$(head -n 1 "$PENDING" 2>/dev/null)
        if [ -n "$pending_file" ] && [ -f "$pending_file" ]; then
            pending_ok=1
            pending_name=$(pending_title "$pending_file")
            [ -n "$pending_name" ] || pending_name="(no name)"
        else
            # 文件已经没了，清掉脏 pending
            rm -f "$PENDING"
        fi
    fi

    {
        printf '{\n'
        printf '  "items": [\n'
        printf '    {\n'
        printf '      "name": "Send to Kindle",\n'
        printf '      "items": [\n'
        printf '        {"name": "[1] 刷新书目 (当前 %s 本)", "action": "sh %s/bin/scan.sh", "exitmenu": true}' \
            "$total" "$PLUGIN_DIR"

        if [ "$pending_ok" -eq 1 ]; then
            # 书名压到 48 字节（≈16 汉字），保证一行放得下、不越界
            short_name=$(trunc_title "$pending_name" 48)
            printf ',\n        {"name": "[!] 确认发送名片: %s", "action": "sh %s/bin/confirm.sh", "exitmenu": true}' \
                "$(json_escape "$short_name")" "$PLUGIN_DIR"
            printf ',\n        {"name": "[x] 取消发送 (返回选书)", "action": "sh %s/bin/cancel.sh", "exitmenu": true}' \
                "$PLUGIN_DIR"
        fi

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

    log "menu rebuilt: total=$total shown=$count skipped=$skipped pending=$pending_ok"
    say "LIST UPDATED: $count book(s) - reopen KUAL"
    echo "✅ 已重建菜单：共扫描到 $total 本，列出 $count 本，跳过 $skipped 本"
    if [ "$pending_ok" -eq 1 ]; then
        echo "   ⚠️ 有待确认的大文件：$pending_name（菜单里已出现确认/取消项）"
    fi
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
    # 没有书也要把 pending 的确认项保留下来，否则用户没法确认/取消
    build_menu
    exit 0
fi

build_menu
