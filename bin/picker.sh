#!/bin/sh
# SendToKindle —— 列出 documents 下的电子书，选一本用 SMTP 推到 Kindle 邮箱
# 必须保持：UTF-8 无 BOM、LF 换行（用 Windows 记事本另存会变 CRLF 导致静默失败）
#
# 用法：
#   ./picker.sh                # 交互式：列出书目，输入序号
#   ./picker.sh 3              # 直接发送列表里的第 3 本
#   ./picker.sh /path/to/x.epub  # 直接发送指定文件
#   ./picker.sh -l             # 只列出书目（不发送），用于排查

PLUGIN_DIR="/mnt/us/extensions/SendToKindle"
DOC_DIR="/mnt/us/documents"
BIN="$PLUGIN_DIR/send_to_kindle"
CONFIG="$PLUGIN_DIR/config.ini"
LIST="$PLUGIN_DIR/books.txt"

# documents/Downloads/Items01/xxx.kfx 在第 3 层，所以默认扫到 4 层
MAXDEPTH=4
# 亚马逊个人文档附件上限约 50 MB
MAX_BYTES=52428800

# ---------------------------------------------------------------- 工具函数

size_of() {
    # $1 = 文件路径，输出 "12.3 MB" 之类的可读大小（只用 wc + shell 算术，避免为每个文件起 awk 进程）
    bytes=$(wc -c < "$1" 2>/dev/null)
    bytes=$(( ${bytes:-0} + 0 ))
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$((bytes / 1024)) KB"
    else
        mb10=$(( bytes / 104857 ))   # MB × 10，避免浮点
        echo "$((mb10 / 10)).$((mb10 % 10)) MB"
    fi
}

# 生成书目清单（每行一个绝对路径，按文件名排序）
build_list() {
    : > "$LIST" 2>/dev/null || {
        echo "❌ 无法写入 $LIST（插件目录只读？）"
        exit 1
    }

    find "$DOC_DIR" -maxdepth "$MAXDEPTH" -type f \
        \( -iname '*.epub' -o -iname '*.pdf' -o -iname '*.txt' \
           -o -iname '*.docx' -o -iname '*.mobi' -o -iname '*.azw3' \) \
        ! -name '.*' \
        ! -name 'My Clippings.txt' \
        ! -path "$DOC_DIR/dictionaries/*" \
        ! -path "$DOC_DIR/*.sdr/*" \
        2>/dev/null | sort >> "$LIST"

    # find 不支持 -maxdepth 时（极老机型）退化成全量查找
    if [ ! -s "$LIST" ]; then
        find "$DOC_DIR" -type f \
            \( -iname '*.epub' -o -iname '*.pdf' -o -iname '*.txt' \
               -o -iname '*.docx' -o -iname '*.mobi' -o -iname '*.azw3' \) \
            ! -name 'My Clippings.txt' 2>/dev/null | sort >> "$LIST"
    fi
}

show_list() {
    n=0
    while IFS= read -r f; do
        n=$((n + 1))
        printf '%3d) %10s  %s\n' "$n" "$(size_of "$f")" "$(basename "$f")"
    done < "$LIST"
}

count_of() {
    wc -l < "$LIST" | tr -d ' '
}

# 发送成功后询问是否删除；同时清理同名 .sdr 阅读数据目录
remove_book() {
    target="$1"
    case "$target" in
        *.*) sdr="${target%.*}.sdr" ;;
        *)   sdr="$target.sdr" ;;
    esac

    if rm -f "$target" 2>/dev/null; then
        if [ -d "$sdr" ]; then
            rm -rf "$sdr" 2>/dev/null && {
                echo "🗑  已删除: $(basename "$target")（连同 $(basename "$sdr") 阅读记录）"
                return 0
            }
        fi
        echo "🗑  已删除: $(basename "$target")"
    else
        echo "⚠️  删除失败: $target（文件系统只读？）"
    fi
}

do_send() {
    target="$1"

    if [ ! -f "$target" ]; then
        echo "❌ 文件不存在: $target"
        return 1
    fi
    if [ ! -f "$BIN" ]; then
        echo "❌ 找不到发送程序: $BIN"
        echo "   请确认已把交叉编译好的 send_to_kindle 放进插件目录并 chmod +x。"
        return 1
    fi
    if [ ! -f "$CONFIG" ]; then
        echo "❌ 找不到配置文件: $CONFIG"
        return 1
    fi

    bytes=$(wc -c < "$target" 2>/dev/null)
    bytes=$(( ${bytes:-0} + 0 ))
    if [ "$bytes" -gt "$MAX_BYTES" ]; then
        echo "⚠️  文件 $(size_of "$target") 超过 50 MB：将改为发送一份说明 TXT，原文件保留在本地。"
    fi

    echo ""
    echo "📤 正在发送: $(basename "$target")  ($(size_of "$target"))"
    echo "   收件人: $(grep -i '^ *to *=' "$CONFIG" | tail -n 1 | cut -d= -f2- | tr -d ' \r')"
    echo ""

    "$BIN" -config "$CONFIG" -file "$target"
    rc=$?

    if [ "$rc" -ne 0 ]; then
        echo ""
        echo "❌ 发送失败（退出码 $rc），本地文件已保留。"
        echo "   排查：直接运行下面这行看完整报错"
        echo "   $BIN -config \"$CONFIG\" -file \"$target\""
        return 1
    fi

    echo ""
    printf '发送成功。是否删除本地文件？(y/N): '
    if ! IFS= read -r ans; then
        ans=""
    fi
    case "$ans" in
        y|Y|yes|YES) remove_book "$target" ;;
        *) echo "📚 已保留: $(basename "$target")" ;;
    esac
    return 0
}

# ---------------------------------------------------------------- 主流程

if [ ! -d "$DOC_DIR" ]; then
    echo "❌ 找不到 $DOC_DIR"
    exit 1
fi

# 直接指定文件
if [ $# -ge 1 ] && [ "$1" != "-l" ] && [ -f "$1" ]; then
    do_send "$1"
    exit $?
fi

build_list

total=$(count_of)
if [ "$total" -eq 0 ]; then
    echo "📭 $DOC_DIR 下没有可发送的电子书"
    echo "   支持格式: epub / pdf / txt / docx / mobi / azw3"
    echo "   已扫描: $DOC_DIR （最多 $MAXDEPTH 层）"
    exit 1
fi

echo "=============================================="
echo "  Send to Kindle   ——  找到 $total 本电子书"
echo "=============================================="
show_list
echo "=============================================="

if [ "$1" = "-l" ]; then
    exit 0
fi

# 数字序号参数：非交互，供 KUAL 直接调用或批量脚本使用
if [ $# -ge 1 ]; then
    case "$1" in
        *[!0-9]*)
            echo "❌ 参数既不是存在的文件，也不是序号: $1"
            exit 1
            ;;
    esac
    if [ "$1" -lt 1 ] || [ "$1" -gt "$total" ]; then
        echo "❌ 序号超出范围（1-$total）"
        exit 1
    fi
    SELECTED=$(sed -n "${1}p" "$LIST")
    if [ -z "$SELECTED" ]; then
        echo "❌ 取不到第 $1 项，请重新运行"
        exit 1
    fi
    do_send "$SELECTED"
    exit $?
fi

printf '请输入序号 (q 退出): '
if ! IFS= read -r choice; then
    echo ""
    echo "⚠️  当前环境读不到键盘输入（KUAL 执行脚本时没有终端 stdin）。"
    echo "   书目已列在上面，请任选一种方式发送："
    echo ""
    echo "   方式 1：在 kterm / SSH 里运行"
    echo "     sh $PLUGIN_DIR/bin/picker.sh"
    echo ""
    echo "   方式 2：带上序号直接发送（不需要输入）"
    echo "     sh $PLUGIN_DIR/bin/picker.sh 3"
    echo ""
    echo "   方式 3：指定文件发送"
    echo "     $BIN -config \"$CONFIG\" -file \"/mnt/us/documents/xxx.epub\""
    echo ""
    echo "   书目清单已存到: $LIST"
    exit 1
fi

case "$choice" in
    q|Q|"")
        echo "已取消。"
        exit 0
        ;;
    *[!0-9]*)
        echo "❌ 请输入数字序号（1-$total）"
        exit 1
        ;;
esac

if [ "$choice" -lt 1 ] || [ "$choice" -gt "$total" ]; then
    echo "❌ 序号超出范围（1-$total）"
    exit 1
fi

SELECTED=$(sed -n "${choice}p" "$LIST")
if [ -z "$SELECTED" ]; then
    echo "❌ 取不到第 $choice 项，请重新运行"
    exit 1
fi

do_send "$SELECTED"
