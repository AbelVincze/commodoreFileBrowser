# Commodore File Browser

A two-panel file manager for macOS that treats Commodore disk images as folders.
Copy files from the Mac file system into `.d64` / `.d71` / `.d81` / `.t64`
images and back out again, with the directory of an image drawn in the original
Commodore 64 character set.

Built with Xcode, SwiftUI and AppKit. Open `CommodoreFileBrowser.xcodeproj`
and run, or:

```bash
xcodebuild -project CommodoreFileBrowser.xcodeproj -scheme CommodoreFileBrowser -configuration Release build
```

## How it works

Two panels sit side by side. Each one shows either the list of mounted volumes
(the root), a folder, or the inside of a disk image. `..` is always the first
row, so the same key walks out of a folder or out of an image. The row under
the cursor is drawn inverse; the panel with the focus has a lighter background.

Both panels remember where they were and reopen there on the next launch.

Navigation keeps its place. Entering a folder puts the cursor on the first row,
the `..` entry, so `←` walks straight back out. Once you have been somewhere,
the cursor returns to where you left it, which makes skimming a tree with `←`
and `→` cheap. `⌘D` jumps to the volume list with the cursor on the volume you
were in, and choosing a volume drops you back in the last folder you had open
on it rather than at its root — so a detour to another disk costs two keys
there and two keys back. The per-volume folders persist between launches; the
per-folder cursor positions last for the session.

Inside an image every row is rendered from `character.rom`, exactly the way a
1541 prints a directory: block count, quoted name, file type, `<` for a locked
file and `*` for one that was never closed. The reverse-video header line
carries the disk name, ID and DOS type. PETSCII graphics characters — the ones
scene disks use to draw boxes and rules out of `DEL` entries — come out right
because the names are never converted to ASCII for display.

## Keys

| Key | |
|---|---|
| `↑` `↓` | move the cursor (hold `⇧` for ten rows) |
| `Page ↑/↓`, `Home`, `End` | jump through the listing |
| `Tab` | switch panels |
| `Space` | mark the file under the cursor |
| `+` `-` `*` | mark all, unmark all, invert |
| `Return` | enter a folder or an image, or play a file as music |
| `⇧Return` | play, entering the addresses by hand |
| `→` | enter a folder or an image — never goes up |
| `←` or `Delete` | go up — saving the image on the way out |
| `⌘D` | jump to the list of volumes |
| `Esc` | go up **without** saving the image |
| `⌘S` | save the open image without leaving it |
| `F1` | help |
| `F2` | new disk image (D64 / D71 / D81) |
| `F3` | view the file under the cursor |
| `⇧F3` | view it as a bitmap |
| `F4` | edit the disk header |
| `F5` | copy to the other panel |
| `F6` | move to the other panel |
| `⇧F6` / `⌘R` | rename |
| `F7` | new folder |
| `F8` | delete |
| `F9` | rename |
| `F10` | quit |
| `Ctrl-Shift` | switch the Commodore font between upper and lower case |
| `⇧⌘.` | show hidden files |
| `⌘↑` `⌘↓` | move an entry within an image directory |

If macOS has `F1`–`F12` mapped to brightness and media keys, hold `Fn`, or turn
on *Use F1, F2, etc. keys as standard function keys* in System Settings ›
Keyboard. Every function key also has a button in the bar along the bottom and
an entry in the menus.

## Copying

Copy and move work in all four directions:

* **Mac → image** — the file is written into the image with a legal PETSCII
  name. A `.prg` keeps its two byte load address; the file type follows the
  extension (`.prg`, `.seq`, `.usr`, `.rel`) and defaults to `PRG`.
* **image → Mac** — the file lands as `NAME.prg`, with the load address
  restored at the front so it can be loaded again later.
* **Mac → Mac** — including whole folders.
* **image → image** — between two open images, in either direction.

Existing files are skipped unless *Overwrite* is ticked in the copy sheet;
the status line reports what was copied and what was skipped. Deleting on the
Mac side moves items to the Trash by default (a setting); deleting inside an
image scratches the entry and frees its blocks in the BAM.

An image on read-only media is opened read-only and shows a lock in its header.

## Editing an image is a transaction

Entering an image loads it into memory; every copy, delete, rename, reorder and
header edit is applied to that working copy, and the file on disk is not
touched until the panel leaves.

* **Leaving normally** — `..`, `←`, `Delete`, double-clicking `..`, or
  navigating the panel elsewhere — commits the working copy to the file.
* **`Esc`** leaves without committing. If anything was edited, a sheet asks
  first, offering *Save and Leave*, *Cancel* or *Discard*; with no edits
  pending it just walks up.
* **`⌘S`** commits without leaving, and quitting the app commits both panels.

While edits are pending the panel header reads `MODIFIED`, so the state is
visible before you reach for `Esc`.

## The window

The window uses `.windowStyle(.hiddenTitleBar)` and draws its own title, so the
browser is one solid colour edge to edge — title bar, body and key bar all
measure identical. The title sits on the same line as the window buttons and
clear of them, from AppKit's own geometry: the buttons span x 9-69 pt with
their centres 16 pt below the window top, and the system bar is 32 pt tall. The
title area is taller than that so the top of the window is not cramped. Setting `backgroundColor` on the window is not enough: a
`WindowGroup` keeps its own background behind a standard title bar whatever the
window is told, which leaves the title bar reading lighter than the content. The divider between the panels is
a plain splitter painted in the window colour (`HSplitView` draws a hard black
seam); drag it to resize, and the position is remembered.

Each panel has no border at all: the active side is picked out by a slightly
lighter background. The header carries an all-caps context line above the path
or the disk header line, with a large DIN Condensed type marker on the right —
`FS` for the file system, `D64` / `D71` / `D81` / `T64` for a container, its
capitals aligned to the top of the info line. Inside an image the listing
starts on the same column as the disk header line above it, with the mark
indicator drawn in the leading padding so it never shifts the text. Commodore
text is drawn in the same dimmed colour throughout. The rules above and below
the listing are inset to line up with the text.

The info line reports what the container is and what state it is in:

```
FILESYSTEM: MACINTOSH HD
D64 (35 TRACKS)   BAM MISMATCH (665 BLOCKS)   MODIFIED   READ ONLY
T64 TAPE · 51 KB
```

`BAM MISMATCH` compares the allocation bitmap against the blocks the directory
and its files actually occupy. Scene disks routinely leave the two out of step
to hide data from the DOS, and a half-written image shows up the same way.

The key bar spans the full width, one segment per function key divided by
hairlines, with the key and its label set at the same size. Status messages
appear in the footer of the active panel.

## The viewer

`F3` opens a file in the viewer; `⇧F3` opens it straight into the bitmap. A
Hex / Bitmap / Basic switch moves between the three modes.

A **Raw/C64** switch decides what the first two bytes mean. C64, the default,
reads them as the load address, starts the offsets there and dumps from the
third byte; Raw starts at `0000` and treats them as data. The choice is
remembered. Rows always begin on a `$10` boundary, so a load address of `$0801`
starts at `0800` with one blank slot and every column stays under one address
digit.

### Basic listing

A tokenised BASIC program is listed the way the machine prints it, in the
Commodore character set. Keywords are expanded outside quotes and left as raw
bytes inside them, so control codes in strings still show as the reverse-video
characters a real `LIST` puts there, and no space appears where the program
never stored one — `IFS=34THENL$=` lists exactly like that.

The token table is BASIC V2 (`$80`-`$CB`), which the PET, VIC-20 and C64 share.
BASIC 4.0 and 7.0 add keywords above `$CB`; those pass through as PETSCII rather
than being expanded. A file that does not begin with a tokenised line says so
instead of showing noise.

### Bitmap view

Data is drawn one pixel per bit, after the model in the author's `Binview`
tool. Bytes are tiled as **blocks** of `BW x BH` pixels (`BW` a multiple of 8);
inside a block the bytes run in raster order, 8 horizontal pixels each, and
blocks tile left to right then wrap down. The whole feature is that one
mapping — and it means the interesting layouts are just numbers:

| Preset | | |
|---|---|---|
| Hires | 8x8 blocks, 320 wide | a C64 bitmap screen |
| Charset | 8x8 blocks, 128 wide | 16 characters per row |
| Sprites | 24x21 blocks, 192 wide | 8 sprites per row |
| Linear | one byte row after another | plain raster order |

The preset is guessed from the file's size when the viewer opens, and every
number stays editable underneath it. A block width that is not a whole number of
bytes rounds up, and the display width settles on a whole number of blocks, so
the grid always divides.

**Align** is what makes the sprite preset actually line up. A sprite occupies 64
bytes in memory but only fills 63 of them, so without an align of 64 every
sprite after the first slides one byte — eight pixels — to the left, and the
bank stair-steps across the screen. Align rounds each block's stride up to 2, 4,
8 … 512 bytes; the leftover bytes are consumed but never drawn. Everything else
packs tight at align *None*.

**Offset** skips bytes before drawing, on top of whatever Raw or C64 already
skipped, for scrubbing into data that does not start on a boundary. It takes
decimal or hex (`$0801`, `0x801`), and the ±1 / ±blk buttons step by a byte or a
whole block.

Hovering reports the byte's offset, its C64 address, its value and its pixel and
block coordinates, and outlines the block it belongs to. *Save as PNG…* writes
the rendered image out. Zoom and invert are remembered between files; the block
geometry is not, since it depends on what the file is. At most 1 MB is drawn.

## Playing SID music

`Return` on a file opens the player. It is a sheet rather than a bar, so
closing it stops playback.

The addresses it needs are worked out three ways:

* **PSID / RSID header** — load, init and play addresses, subtune count,
  title, author and SID model all come from the header.
* **The file name** — `Z10 I1000 P1003` gives init `$1000` and play `$1003`.
  Case does not matter, so a file written `z900 if000 pf003` on the Mac works
  the same as the upper case form a disk carries.
  A `!` in place of the `I` (`Z108 !2800 P2803`), or trailing the name, marks a
  tune with more than one song. Run-together spellings such as
  `Z101 !E006PPE000` parse too; names like `PLAYER V3.1 0800` correctly do not.
* **By hand** — anything else, or `⇧Return` to override a wrong guess. The file
  is treated as a PRG, so its first two bytes give the load address.

When the addresses are known the tune starts playing as the sheet opens; a file
needing them typed in waits. The SID model and the oscilloscope settings are
remembered from one tune to the next, and the remembered model takes precedence
over the one a PSID header asks for.

A song is chosen by the byte written to A, X and Y before init, which is what
the `Song` stepper sets. Playback speed is 50, 100, 200 or 400 Hz, any figure
you type, or *Tune* to keep the tune's own timing — 50 Hz vsync, or whatever
its CIA timer asks for.

### Oscilloscope

An optional scope draws either the mixed output or one trace per voice. Per
voice it is always **three rows**, one column per SID chip, so a column is that
chip's voices 1-3 — 3 traces for one chip, 6 for two, 9 for three. (The engine
emulates at most three chips, so nine voices is the ceiling.)

*Export…* writes the scope to an `.mp4` with the tune as its soundtrack, into
the folder on show — or the folder holding the image, when the panel is inside
one. Rendering is offline rather than real time: the soundtrack is rendered
first, then the engine is rewound and replayed a video frame at a time, so
picture and sound stay in step however long the export takes. A three second
clip takes well under a second.

The engine is [cSID-light](http://hermit.sidrip.com) by Hermit
(Mihaly Horvath), vendored into `Audio/csid.c` with SDL and its `main()`
removed. His CPU and SID emulation is untouched; the additions are a small API
for the load address, the init and play routines, the A/X/Y byte and an
explicit playback rate, and a per-voice tap for the oscilloscope. Licensed
"do what you want, but please mention me as its original author".

## Themes

*Settings › Appearance* has Light / Dark / System, four presets (Standard,
Graphite, Commodore 64, Amber Terminal) and a colour well for each of the
thirteen roles the browser draws with — separately for the light and the dark
palette. *Display* picks the character ROM (Commodore 64 or PET) and switches
between the upper case/graphics and lower case/upper case halves of it. The
character cell size is fixed at 16 px, which the panel layout is built around.

### Character ROMs

`character.rom` is the C64 generator: two 256 glyph sets where `$80`-`$FF` are
the reverse video forms. A PET generator is only 2 KB — two 128 glyph sets with
no reverse video — so `Tools/expand-rom.py` builds the missing halves by
inverting every byte, and both ROMs are then indexed identically:

```bash
./Tools/expand-rom.py pet_characters.rom CommodoreFileBrowser/Resources/pet.rom
```

`pet_characters.rom` in the project root is the 2 KB source; the generated 4 KB
`Resources/pet.rom` is what ships in the app. Any other 2 KB Commodore
generator can be added the same way.

`Tools/snapshot` renders a directory listing in every ROM and character set at
once, which is the quickest way to eyeball a newly added generator:

```bash
swiftc -o /tmp/snap CommodoreFileBrowser/Core/*.swift CommodoreFileBrowser/Disk/*.swift \
    CommodoreFileBrowser/Model/*.swift CommodoreFileBrowser/Views/PanelView.swift \
    CommodoreFileBrowser/Views/PETSCIIText.swift Tools/snapshot/main.swift && SHOT_DIR=/tmp /tmp/snap
```

## Formats

| | |
|---|---|
| D64 | 35, 40 and 42 track, with or without error info |
| D71 | 70 tracks, both BAM halves |
| D81 | 80 tracks, both BAM sectors |
| T64 | tape archives; rebuilt on write, with broken end addresses repaired from the next record's offset |

Writing allocates blocks outwards from the directory track with the normal
interleave, grows the directory by a sector when the current one fills up, and
keeps the BAM free counts in step. `F2` formats a blank image with the correct
free block count for its type (664 / 1328 / 3160).

## Commodore menu

Beyond plain file management: edit the disk header, insert a `DEL` entry to
draw rules and boxes in a directory, lock and unlock entries, and move an entry
up or down to rearrange the listing.

## Tests

```bash
./Tools/run-tests.sh
```

Reads every image in `sample_images/`, checks each file against its block
count, then formats blank D64/D71/D81 images and round trips a spread of file
sizes through write, save, reopen, read, delete, rename, reorder and header
edit — including packing a D64 until it is full — and round trips a T64.
It also covers the transaction rules above: that edits stay off disk until the
panel leaves, that leaving normally commits them, and that `Esc` discards them
without changing the file.
