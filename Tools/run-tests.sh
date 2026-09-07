#!/bin/bash
# Exercises the disk image layer against the images in sample_images/ and
# against freshly formatted D64 / D71 / D81 / T64 containers.
#
# libopenmpt is 150 C++ files and takes minutes to compile, so its objects are
# built once into build/libopenmpt and reused. Delete that folder to rebuild it.
set -e
cd "$(dirname "$0")/.."

MPT="CommodoreFileBrowser/Audio/libopenmpt"
OBJDIR="build/libopenmpt"
MPTFLAGS=(-std=c++20 -O2 -w -I"$MPT" -I"$MPT/common" -I"$MPT/src" -DLIBOPENMPT_BUILD)

mkdir -p "$OBJDIR"
missing=0
while IFS= read -r src; do
    obj="$OBJDIR/$(echo "${src#$MPT/}" | tr '/' '_' | sed 's/\.cpp$/.o/')"
    if [ ! -f "$obj" ] || [ "$src" -nt "$obj" ]; then
        printf '%s\t%s\n' "$src" "$obj"
        missing=$((missing + 1))
    fi
done < <(find "$MPT" -name '*.cpp' | sort) > /tmp/cfb-mpt-todo.txt

if [ -s /tmp/cfb-mpt-todo.txt ]; then
    echo "building libopenmpt ($(wc -l < /tmp/cfb-mpt-todo.txt) files, once)..."
    while IFS=$'\t' read -r src obj; do
        echo "$obj: $src"
        printf '\tcc %s -c -o $@ $<\n' "${MPTFLAGS[*]}"
    done < /tmp/cfb-mpt-todo.txt > /tmp/cfb-mpt.mk
    echo "all: $(cut -f2 /tmp/cfb-mpt-todo.txt | tr '\n' ' ')" | cat - /tmp/cfb-mpt.mk > /tmp/cfb-mpt-all.mk
    make -f /tmp/cfb-mpt-all.mk -j8 >/dev/null
fi

# The two engine shims are C, and swiftc will not take .c and .o together.
cc -O2 -w -Wno-logical-not-parentheses -c -o "$OBJDIR/csid.o" CommodoreFileBrowser/Audio/csid.c
cc -O2 -w -I"$MPT" -I"$MPT/common" -I"$MPT/src" -c -o "$OBJDIR/cmod.o" CommodoreFileBrowser/Audio/cmod.c

OUT="${TMPDIR:-/tmp}/cfb-disktests"
swiftc -O -o "$OUT" \
    -import-objc-header CommodoreFileBrowser/CommodoreFileBrowser-Bridging-Header.h \
    -Xcc -Wno-logical-not-parentheses \
    -Xcc -I"$MPT" -Xcc -I"$MPT/common" -Xcc -I"$MPT/src" \
    CommodoreFileBrowser/Core/*.swift \
    CommodoreFileBrowser/Disk/*.swift \
    CommodoreFileBrowser/Model/PanelModel.swift \
    Tools/DiskTests/main.swift \
    -Xlinker -lc++ $(printf -- '%s ' "$OBJDIR"/*.o)
exec "$OUT"
