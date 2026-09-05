#!/usr/bin/env python3
"""Expand a 2 KB Commodore character generator into the 4 KB layout the app uses.

A 2 KB ROM holds two 128 glyph sets (upper case/graphics, then lower case) with
no reverse video forms. The C64 ROM instead holds two 256 glyph sets where
glyphs $80-$FF are the inverted images of $00-$7F. This script produces that
layout by inverting every byte, so both ROMs can be indexed the same way.

    ./Tools/expand-rom.py pet_characters.rom CommodoreFileBrowser/Resources/pet.rom
"""
import sys

def main(src_path, dst_path):
    src = open(src_path, 'rb').read()
    if len(src) != 2048:
        sys.exit(f"expected a 2048 byte ROM, got {len(src)}")

    out = bytearray()
    for half in (src[:1024], src[1024:]):          # each 128 glyph set
        out += half                                 # $00-$7F as they are
        out += bytes(b ^ 0xFF for b in half)        # $80-$FF reverse video

    assert len(out) == 4096
    open(dst_path, 'wb').write(out)
    print(f"{src_path} ({len(src)} bytes) -> {dst_path} ({len(out)} bytes)")

if __name__ == "__main__":
    main(*sys.argv[1:3])
