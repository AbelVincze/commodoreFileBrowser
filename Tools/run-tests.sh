#!/bin/bash
# Exercises the disk image layer against the images in sample_images/ and
# against freshly formatted D64 / D71 / D81 / T64 containers.
set -e
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/cfb-disktests"
swiftc -O -o "$OUT" \
    -import-objc-header CommodoreFileBrowser/CommodoreFileBrowser-Bridging-Header.h \
    -Xcc -Wno-logical-not-parentheses \
    CommodoreFileBrowser/Audio/csid.c \
    CommodoreFileBrowser/Core/*.swift \
    CommodoreFileBrowser/Disk/*.swift \
    CommodoreFileBrowser/Model/PanelModel.swift \
    Tools/DiskTests/main.swift
exec "$OUT"
