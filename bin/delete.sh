#!/bin/sh
# delete.sh —— 删除上次发送成功的那本书（含同名 .sdr 阅读记录），并重建菜单
# 用法：sh /mnt/us/extensions/SendToKindle/bin/delete.sh

PLUGIN_DIR="/mnt/us/extensions/SendToKindle"
LAST="$PLUGIN_DIR/last.txt"

FBINK=""
for d in /var/tmp /mnt/us/libkh/bin /mnt/us/koreader /mnt/us/linkss/bin /mnt/us/linkfonts/bin /mnt/us/usbnet/bin; do
    if [ -x "$d/fbink" ]; then
        FBINK="$d/fbink"
        break
    fi
done

say() {
    if [ -n "$FBINK" ]; then
        "$FBINK" -qpm -y -5 "$1" >/dev/null 2>&1
    fi
}

target=$(head -n 1 "$LAST" 2>/dev/null)

if [ -z "$target" ] || [ ! -f "$target" ]; then
    say "NOTHING TO DELETE"
    echo "ℹ️  没有可删除的文件（可能已经删过了）"
    rm -f "$LAST"
    sh "$PLUGIN_DIR/bin/scan.sh" -q >/dev/null 2>&1
    exit 0
fi

case "$target" in
    *.*) sdr="${target%.*}.sdr" ;;
    *)   sdr="$target.sdr" ;;
esac

name=$(basename "$target")

if rm -f "$target"; then
    if [ -d "$sdr" ]; then
        rm -rf "$sdr"
        echo "🗑  已删除: $name（连同 $(basename "$sdr") 阅读记录）"
    else
        echo "🗑  已删除: $name"
    fi
    say "DELETED: local file removed"
    rm -f "$LAST"
else
    echo "⚠️  删除失败（文件系统只读？）: $target"
    say "DELETE FAILED - filesystem read-only?"
fi

sh "$PLUGIN_DIR/bin/scan.sh" -q >/dev/null 2>&1
exit 0
