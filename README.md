# Commodore File Browser

A two-panel file manager for macOS that treats retro disk images as folders.
Copy files between the Mac file system and Commodore or Amiga images, with the
directory of a Commodore image drawn in the original C64 character set — and
play the music you find in them.

Built with Xcode, SwiftUI and AppKit. Open `CommodoreFileBrowser.xcodeproj`
and run, or:

```bash
xcodebuild -project CommodoreFileBrowser.xcodeproj -scheme CommodoreFileBrowser -configuration Release build
```

The app lands in `build/Products/Release/`. `SYMROOT` and `OBJROOT` are set in
the project, so builds go to the project's own `build/` folder rather than to
derived data, from Xcode and from the command line alike.

## What it does

**Browsing and editing images**

* Commodore disks — 1541, 1571, 1581, the 2040 that came before them, and the
  8050 / 8250 of the PET drives — plus T64 tape archives and X64 containers.
* Amiga disks — ADF floppies (OFS and FFS, plain, international or with a
  directory cache), UAE hardfiles with or without a partition table, and DMS
  archives, browsed in place or unpacked.
* Copy, move, rename, delete and make folders in all four directions between
  the Mac and an image, or between two open images.
* Drag and drop, in and out: between the panels, or to and from the Finder.
  Same volume moves, two volumes copy, `⌥` swaps the two — and the inside of an
  image counts as a volume of its own.
* Editing an image is a transaction: nothing touches the file on disk until the
  panel leaves, and `Esc` throws the changes away.
* Format a blank image, edit a disk header, lock entries, rearrange a
  directory, and insert `DEL` entries to draw rules and boxes in a listing.
* An **Advanced** half to the header, rename and `DEL` entry dialogs: the
  printed fields byte by byte in the character ROM's own glyphs, a grid of
  every character no key reaches, the block count a row prints and the figure
  the listing ends on — everything a decorated directory is made of.

**Looking at files**

* A hex viewer that reads the first two bytes as a load address or as data, a
  lister that detokenises Commodore BASIC in the original font, and a bitmap
  viewer that draws a file one pixel per bit — presets for a C64 hires screen,
  a character set, sprites and plain raster order, with the block size
  adjustable for anything else.
* Directories rendered from a real character ROM, so PETSCII box-drawing comes
  out the way a 1541 prints it.

**Playing music**

* SID tunes: PSID and RSID headers, the `Z10 I1000 P1003` file-name convention,
  and Music Assembler tunes recognised from the player's own code.
* Tracker modules: MOD, XM, S3M, IT, MED and the rest through libopenmpt, and
  the Amiga chiptune formats through c-flod — recognised from their bytes, so
  the Amiga habit of naming a file `mod.something`, or nothing at all, does not
  matter.
* An oscilloscope for SID tunes that can be exported as video.

**The Mac side**

* Light, dark and system themes, four palettes and a colour well for each of
  the thirteen roles the browser draws with.
* `⌘O` hands a file to whatever app macOS uses for it; a file inside an image
  is written out as a read-only copy first.

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
| `Return` | enter a folder or an image, play a SID tune, a tracker module or an IFF sample, or show an Amiga or C64 picture |
| `⇧Return` | force the SID player on, entering the addresses by hand |
| `⌘O` | open it with the app macOS uses for it |
| `⌥⌘R` | show it in Finder |
| `⌘P` | print the listing in the active panel |
| right click | open, open with, show in Finder, and the panel's own commands |
| `→` | enter a folder or an image — never goes up |
| `←` or `Delete` | go up — saving the image on the way out |
| `⌘D` | jump to the list of volumes |
| `⌘U` | re-read both panels from disk |
| `Esc` | go up **without** saving the image |
| `⌘S` | save the open image without leaving it |
| `F1` | help |
| `F2` | new disk image (D64 at 35/40/42 tracks, D67, D71, D81, D80, D82, ADF) |
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
| `Space` in a player | play or pause |
| `⌘↑` `⌘↓` in a player | play the previous or next file |
| `⌘←` `⌘→` in the SID player | step the song byte, restarting on that song |
| `Ctrl-Shift` or `⇧⌘C` | switch the Commodore font between upper and lower case |
| `⇧⌘R` | repair the open Commodore image |
| `⇧⌘.` | show hidden files |
| `⌘↑` `⌘↓` | move an entry within an image directory |
| drag | move or copy — between the panels, or to and from the Finder |
| `⌥` drag | copy where it would move, and move where it would copy |

If macOS has `F1`–`F12` mapped to brightness and media keys, hold `Fn`, or turn
on *Use F1, F2, etc. keys as standard function keys* in System Settings ›
Keyboard. Every function key also has a button in the bar along the bottom and
an entry in the menus.

## Copying

Copy and move work in all four directions:

* **Mac → image** — the file is written into the image with a legal PETSCII
  name. A `.prg` keeps its two byte load address; the file type follows the
  extension (`.prg`, `.seq`, `.usr`, `.rel`) and defaults to `PRG`.
* **image → Mac** — the file lands as `name.prg`, with the load address
  restored at the front so it can be loaded again later. The extension is the
  only place the Commodore file type survives, so it is added by default, but
  the copy sheet can be told to write the plain disk name instead; the answer
  is remembered. The load address goes in either way.
* **Mac → Mac** — including whole folders.
* **image → image** — between two open images, in either direction.

Existing files are skipped unless *Overwrite* is ticked in the copy sheet;
the status line reports what was copied and what was skipped. Deleting on the
Mac side moves items to the Trash by default (a setting); deleting inside an
image scratches the entry and frees its blocks in the BAM.

An image on read-only media is opened read-only and shows a lock in its header.

### Dragging

The same four directions can be dragged instead, and the Finder is a fifth: a
selection dragged out lands wherever it is dropped, and files dragged in from
another application go into the panel they are dropped on.

Which of move and copy a drop means is decided the way the Finder decides it.
Two folders on the same volume move; two volumes copy; and `⌥` held at the drop
asks for whichever of the two the volumes did not imply. **The inside of an
image is a volume of its own**, so anything crossing that boundary copies by
default — which is also what it has to be, since the bytes are rewritten into
the other format on the way. Copying between two directories of one image, on
the other hand, moves.

The badge under the pointer says which it will be, and the panel says where it
will land: an outline around the whole listing for the folder it is showing, or
around a single row for a folder inside it. Dropping back where the files
already are, dropping a folder into a disk image, dropping anything into a
read-only image, and dropping a folder inside itself are all refused before the
mouse is let go.

A drag started on a marked row takes every marked row with it; one started
anywhere else takes that row alone. A move the Finder makes happens on its own
queue, after the drag has already ended, so the panel follows the files it let
go of for a few seconds and redraws itself the moment one of them goes. Rows that live inside an image are written
out to a temporary folder as the drag starts, since a directory entry is not a
file until something makes one of it; a name already taken on the far side is
left alone, and the status line says how many were skipped.

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

Rows carry the name in the system font, then size, flags and date in the same
face at a smaller size, with the figures held to an even width so the right
aligned columns do not shuffle as the listing scrolls. The size is an exact
byte count — `1,204`, and `Dir` for anything that can be walked into — on the
Mac side as well as inside an image, since the last hundred bytes are what
decide whether a file still fits a 170K disk.

`BAM MISMATCH` compares the allocation bitmap against the blocks the directory
and its files actually occupy — *Commodore ▸ Repair Disk* is what to do about
it. Scene disks routinely leave the two out of step
to hide data from the DOS, and a half-written image shows up the same way.

The key bar spans the full width, one segment per function key divided by
hairlines, with the key and its label set at the same size. Status messages
appear in the footer of the active panel, and go as soon as that panel walks
somewhere else or the focus moves to the other column: the line reports what
just happened *here*, and a message left standing over a different directory
is describing a place that is no longer on screen.

## The viewer

`F3` opens a file in the viewer; `⇧F3` opens it straight into the bitmap. A
Hex / Bitmap / Image / Basic switch moves between the four modes. A picture
opens on itself rather than on a hex dump of itself — `F3` on an ILBM or a
Koala starts in Image, which is what pressing it on a picture plainly meant.

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

### IFF pictures

`Return` on an Amiga picture opens it, the same key that plays a tune. The
viewer's Image mode draws it in its own colours — the one thing in this browser
that is not two colours tinted from the theme, because a picture brought its
own thirty-two and the point of showing it is to see them.

An Amiga held a picture as one bitplane per bit of depth, every plane a full
page of its own, and a pixel's colour index is one bit taken from the same
place in each. Six planes give 64 indices, and two of the OCS tricks then
reinterpret them:

* **EHB** — Extra Half-Brite, where the upper 32 indices are the lower 32 with
  every gun halved. Nothing in the picture says so except a flag, so a file
  with no `CAMG` but a palette that stops at 32 is read as EHB too, which is
  what it means.
* **HAM** — hold-and-modify, where most pixels are not a colour but a change to
  one channel of the pixel to the left. HAM6 carries four bits a channel and
  HAM8 six.

Both exist to get more colours out of a palette than the palette has room for.
Also read: `ByteRun1` packing and uncompressed bodies, one to eight planes, the
mask plane a stencil keeps where its colour planes would be, and an `ANIM`'s
first frame — the rest of an animation is deltas against it, and the subtitle
says how many are not being shown.

A palette written the way the machines of the day wrote one — four bits a gun,
parked in the high nibble — is widened rather than taken at face value, or
every colour comes out at half brightness. **Correct aspect** shows the picture
the shape it was drawn as: an Amiga pixel was not square, and the file records
how far from square. *Save as PNG* writes it at one pixel per Amiga pixel,
whatever the zoom.

A `FORM ILBM` holding a palette and no pixels — how DPaint saved its `.col`
files — is not claimed as a picture. Neither is a truncated one refused: half a
picture is drawn as far as it goes.

### C64 pictures

The same Image mode draws what the C64's painters saved. None of these files
has a header, a magic number or anything else that says what it is: a painter
of the day dumped the VIC-II's memory to disk and the loader put it back. So a
format is recognised by its exact size and its load address together, which is
narrow enough that an ordinary program almost never falls into it — and refused
outright when neither matches, rather than guessed at.

| Format | Load | Size | |
|---|---|---|---|
| Koala Painter | `$6000` | 10003 | multicolour |
| Advanced Art Studio | `$2000` | 10018 | multicolour |
| Art Studio | `$2000` | 9009 | hires |
| Doodle | `$5C00` | 9218 | hires |
| Hi-Eddi | `$A000` | 9002 | hires |
| Face Painter | `$4000` | 10004 | multicolour |
| Run Paint | `$6000` | 10006 | multicolour |
| Interpaint | `$4000` | 10003 / 9002 | multicolour or hires |
| Amica Paint | `$4000` | packed | multicolour |
| Blackmail FLI | `$3B00` | 17474 | multicolour, eight video matrices |
| Raw bitmap | none | 10001 / 9000 | a screen dumped with no load address |

Almost all of them are the same four pieces in a different order — an 8000 byte
bitmap, a 1000 byte video matrix, 1000 bytes of colour RAM and a byte of
background colour — so they are a table rather than a decoder each. Amica Paint
is the exception that has to be unpacked before any of it means anything, which
is also how it is recognised: its size is whatever the picture compressed to,
so it is unpacked on spec and claimed only if a whole picture comes out.

**Hires** gives each 8x8 cell two colours out of the video matrix; **multicolour**
trades half the horizontal resolution for four, the fourth coming from colour
RAM and the first being the one background colour the whole screen shares.
**FLI** is the trick of handing the chip a fresh video matrix on every raster
line, so a cell gets eight colours instead of two — at the cost of the leftmost
three character columns, which the chip has no time left to fetch. Those are
cut, which is why an FLI picture comes out 296 wide.

The colours are Colodore's, the measurements of a real machine most emulators
and modern C64 tools agree on. The VIC-II had no palette to read: its sixteen
colours were fixed in silicon, and every RGB set for them is somebody's
photograph of a television.

**Correct aspect** matters more here than on the Amiga, because nothing in any
of these files records the pixel shape — it was a property of the television,
not of the picture. On, a picture is drawn at the PAL ratio; off, one pixel is
one square pixel. A multicolour picture is drawn 320 wide either way, with its
pixels the two screen pixels wide they really were, rather than squeezed into
160 and stretched back out.

### IFF samples

`Return` on an `8SVX` plays it. Eight bit, one channel, at whatever rate the
sampler was clocking Paula at — sixteen distinct rates turn up in a collection
of five hundred, which is why the audio node is built at the file's rate and
the mixer does the resampling.

An instrument carries a loop point, and *Repeat the loop* plays it the way it
was meant to be held: the attack once, then the tail round and round. An effect
has no loop and the toggle does not appear. There is no video export here —
the exporter counts its frames in SID samples per second, and a 16726 Hz sound
would come out of step with its own picture.

Fibonacci-delta compressed samples are refused by name rather than played as
noise. There is not one in five hundred and fifty.

## Playing SID music

`Return` on a file opens the player. It is a sheet rather than a bar, so
closing it stops playback.

The addresses it needs are worked out four ways:

* **PSID / RSID header** — load, init and play addresses, subtune count,
  title, author and SID model all come from the header.
* **The file name** — `Z10 I1000 P1003` gives init `$1000` and play `$1003`.
  Case does not matter, so a file written `z900 if000 pf003` on the Mac works
  the same as the upper case form a disk carries.
  A `!` in place of the `I` (`Z108 !2800 P2803`), or trailing the name, marks a
  tune with more than one song. Run-together spellings such as
  `Z101 !E006PPE000` parse too; names like `PLAYER V3.1 0800` correctly do not.
* **The Music Assembler player** — recognised by its own code, so the name is
  free to be anything. The editor saves the player in front of the tune at a
  fixed layout: init `$48` past the load address, and the interrupt handler
  that drives the music `$18` past it. Both the init routine and the head of
  the play routine are checked, and the play routine's own address has to agree
  with where the file says it loads, so a copy moved somewhere else without
  being relocated is not mistaken for a working tune. Where a ripper wrote a
  banner over the first bytes — a fifth of the 256 such tunes on the disks here
  — the handler is gone and the routine it called, `$21` on, is used instead.
* **By hand** — anything else, or `⇧Return` to override a wrong guess. The file
  is treated as a PRG, so its first two bytes give the load address.

Speed and SID model take effect where they stand: the tune plays on rather than
restarting from the beginning, and switching the speed back to *Tune* restores
whatever rate the tune itself asked for. Choosing a different song does restart,
since that means running init again. The speed is in Hertz, and a new file
always opens on *Tune*: a rate that suited the last tune says nothing about this
one, and leaving it set was a good way to wonder why a tune sounded wrong.

### Transport

Three buttons: play/pause, stop and fast forward. Pause holds the tune where it is
and play picks it up from there; stop rewinds, so the next play starts the tune
from the top. Editing an address and pressing play builds the tune again rather
than resuming.

Fast forward runs for exactly as long as the key is held down: the play routine
is called ten times as often, so ten seconds of tune go by in one — the pitch is
untouched, only the tempo. The clock beside them counts the same ten seconds
rather than the one, since what it says is where in the tune the sound has got
to. Beside it is the rate the play routine is actually being called at, which is
the one place the tune's own timing shows as a figure.

The volume slider sits at the right of the row, and its level is remembered from
one tune to the next. Ten times the events per second is harsh at full level, so
fast forward plays at half — the slider does not move for it, since the level
asked for has not changed. Both that and a drag of the slider are eased in
across a buffer rather than stepped to, so neither arrives as a click. An
exported video is unaffected: it is rendered from the engine directly, and the
level is a monitoring choice.

When the addresses are known the tune starts playing as the sheet opens; a file
needing them typed in waits. The SID model and the oscilloscope settings are
remembered from one tune to the next, and the remembered model takes precedence
over the one a PSID header asks for.

`⌘Q` quits from anywhere, including with a sheet open: a sheet disables the
menu bar, so the shortcut never reaches the Quit item on its own and the app
could not be left without dismissing whatever was in the way first.

With the player open, `⌘↑` and `⌘↓` play the previous and next file, stepping
over the `DEL` rules a directory is decorated with, and `⌘←` and `⌘→` walk the
A,X,Y byte so a multi-song file can be gone through a song at a time. They take
Command because the sheet's address fields hold the keyboard and would otherwise
swallow a bare arrow; holding Command also stops `⌘↑`/`⌘↓` from rearranging the
directory behind the sheet.

A song is chosen by the byte written to A, X and Y before init, which is what
the `Song` stepper sets. Playback speed is 50, 100, 200 or 400 Hz, any figure
you type, or *Tune* to keep the tune's own timing — 50 Hz vsync, or whatever
its CIA timer asks for.

### Oscilloscope

An optional scope draws either the mixed output or one trace per voice. Each
frame is lined up on a rising crossing of zero rather than on wherever the
buffer happens to begin, so the trace stands still instead of sliding across the
cell — the same trigger an oscilloscope uses. The crossing sits in the middle of
the cell, with half a window of wave drawn either side of it. Hysteresis stops a
wave dithering around zero from firing several times a cycle. Noise never locks,
which is right: there is no phase to lock to.
 Per
voice it is always **three rows**, one column per SID chip, so a column is that
chip's voices 1-3 — 3 traces for one chip, 6 for two, 9 for three. (The engine
emulates at most three chips, so nine voices is the ceiling.)

*Export…* writes the scope to an `.mp4` with the tune as its soundtrack, into the
folder on show — or the folder holding the image, when the panel is inside one.
Rendering is offline rather than real time: the soundtrack is rendered first,
then the engine is rewound and replayed a video frame at a time, so picture and
sound stay in step however long the export takes. A three second clip takes well
under a second.

The picture is 720p, 1080p or 4K, at 4:3 or 16:9 — 960, 1440 and 2880 wide at
4:3, and 1280, 1920 and 3840 at 16:9, so both sides always come out even, which
is what H.264 wants. Hovering the row says which, in pixels. The choice is
remembered from one tune to the next, as is the length.

The scope is drawn against a 540 tall reference and scaled from there, so a 4K
frame gets a trace four times as thick rather than a hairline, and no more steps
along it than there are samples in the window: past that the line is a staircase
of repeated values rather than a finer curve.

The engine is [cSID-light](http://hermit.sidrip.com) by Hermit
(Mihaly Horvath) — see [Credits](#credits).

## Playing tracker modules

`Return` plays a module too, and finds one without help from its name.

Amiga modules are not named the way Mac files are. The convention there is a
prefix — `mod.crockets`, `med.jazz` — and plenty of files carry nothing at all:
of the 47 modules inside the ADF and DMS images here, five are called `KONMOD`,
`LPMOD`, `LSMmiuzik`, `MUSC` and `oliNBP`. So the bytes decide, not the name.

Every format worth playing announces itself: the four characters at offset 1080
for the 31-sample Amiga module, a mark at the front for the trackers and the
chiptune editors. A mark on its own is not enough, though — the ProTracker
playroutine source carries a line reading `EQU 1080 ;"M.K." :)`, a comment
naming the offset of the mark, which in that file lands *at* offset 1080. What
settles it is arithmetic: a module says how long each of its 31 samples is and
which patterns it plays, and header, patterns and samples account for the file
exactly, once a pattern is sized by the channel count its mark spells out.

### Two engines

**libopenmpt** is asked first and plays the tracker formats — MOD, XM, S3M, IT,
MED, DigiBooster, Oktalyzer, MultiTracker. It is also the one that can say how
long a module runs and seek within it.

**c-flod** is asked second and plays the Amiga chiptune formats, where the file
is a player routine with its data behind it rather than a pattern table: Future
Composer, SoundMon, Hippel, SidMon, Whittaker, Hubbard, Fred, Delta Music,
Digital Mugician, SoundFX. Those carry no signature at all, so recognising one
means letting each player read the file and seeing which validates it — which
is only safe because guessing wrong was made survivable. Against 401 icons,
libraries, fonts, bitmaps and source files, no player claimed one.

A format the browser can name but neither engine plays says so in the status
line rather than opening a player that cannot start, the same way `Return` does
when a file is not a tune at all.

Both engines are vendored rather than linked, and c-flod needed patching to be
safe to guess with — see [Credits](#credits). Note that c-flod carries a
non-commercial licence, unlike everything else here.

### The sheet

A transport rather than a form: a module carries its whole song, so there is
nothing to type in and it opens playing. Position, length and seeking come from
libopenmpt; a chiptune player routine reports none of them, so that sheet shows
no clock. The *Stereo* switch is there because Amiga modules pan the voices
hard left and right, which is how they were meant to sound on speakers and
tiring on headphones; turned off, every channel is mixed to both sides. It is a
switch rather than a percentage because that is the whole of the choice.

Otherwise it is the SID sheet: the same three transport keys, the same volume,
the same oscilloscope with a video export under it, and `⌘↑` / `⌘↓` to play the
previous or next file — which crosses between the two players by itself, since
the file being stepped to is what decides which sheet opens. `⌘←` / `⌘→` step
the songs inside a module, as they step a SID tune's subtunes.

Two things differ, both because of what is underneath. The oscilloscope draws
the output — mixed, or left over right — rather than a trace per voice: there
is nothing else to draw, since libopenmpt reports a level per channel but not
the samples behind it, and a chiptune player reports nothing at all. And fast
forward runs at four times rather than the SID player's ten, because four is
where libopenmpt's tempo factor stops — it throws above that rather than
clamping, so asking for ten applies nothing at all. A chiptune player has no
tempo to change, so its key is disabled rather than pretending.

## Themes

*Settings › Appearance* has Light / Dark / System, four presets (Standard,
Graphite, Commodore 64, Amber Terminal) and a colour well for each of the
thirteen roles the browser draws with — separately for the light and the dark
palette. *Display* picks the character ROM (Commodore 64 or PET) and switches
between the upper case/graphics and lower case/upper case halves of it. The
character cell size is fixed at 16 px, which the panel layout is built around.

### Upper and lower case

A Commodore letter comes in two forms, and which one is stored decides what it
draws in each half of the ROM. Unshifted letters, `$41`-`$5A`, are what the
machine types by default: capitals in the upper case / graphics set, lower case
in the other. Shifted letters, `$C1`-`$DA`, are graphics in the first set and
capitals in the second.

So case here is not decoration, it picks the form. **Names are written in lower
case**: `new disk` stores the unshifted letters and reads `NEW DISK` in the set
the machine boots into, and `new disk` once the character set is switched.
Capitals ask for the shifted form, which is what lets a name be given in mixed
case — `NewFile` reads exactly as written in the lower case set, at the price of
the `N` and the `F` being graphics in the other, which is what a real machine
does too.

Everything the browser spells for itself follows the same rule and is written in
lower case in the source: the file types on a directory row, the BASIC keywords
a listing expands, the disk name a new image is given. Reading back is the
inverse, so a name taken out of a directory and written straight back is the
same bytes — which is why a name a Commodore typed comes out lower case on the
Mac. Those really are its unshifted letters, and spelling them back in capitals
would store the graphics forms instead.

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

### Commodore

| | Drive | |
|---|---|---|
| D64 | 1541 | 35, 40 and 42 track, with or without error info — 664 blocks free |
| D67 | 2040 | 35 tracks, DOS 1, one more sector on the second zone — 670 free |
| D71 | 1571 | 70 tracks, both BAM halves — 1328 free |
| D81 | 1581 | 80 tracks, both BAM sectors — 3160 free |
| D80 | 8050 | 77 tracks — 2052 free |
| D82 | 8250 | 154 tracks — 4133 free |
| X64 | — | the old VICE container; the 64 byte header is read and the disk inside it is handled as its own type |
| T64 | — | tape archives; rebuilt on write, with broken end addresses repaired from the next record's offset |

Writing allocates blocks outwards from the directory track with the normal
interleave, grows the directory by a sector when the current one fills up, and
keeps the BAM free counts in step. `F2` formats a blank image with the correct
free block count for its type.

### Amiga

| | |
|---|---|
| ADF | 880K and 1.76M floppies — OFS and FFS, plain, international, or with a directory cache |
| HDF | UAE hardfiles: one bare volume filling the file, or a Rigid Disk Block describing partitions, in which case the root of the image is the partition list |
| DMS | DiskMasher archives, browsed in place or unpacked to an ADF from the File menu |
| IFF | `ILBM` pictures and `ANIM` first frames in the viewer, `8SVX` samples in a player — recognised by content, since an Amiga file is as likely to be called `pic.1` as anything else |

Amiga directories are hash tables rather than a list, so the browser walks the
chains and shows the entries a real AmigaDOS would — including the ones a
naive reader misses when two names collide in the same bucket. Writing keeps
the bitmap, the hash chains and, where the volume has one, the directory cache
all in step. A hardfile is read through a memory map and written a block at a
time, so changing one directory entry on a two gigabyte file writes one block.

DMS decoding checks both the CRC of each packed track and the checksum of the
unpacked bytes, so a decoder that goes wrong says so rather than handing back
plausible rubbish. Partitions whose file system is PFS or SFS are listed with
their type but not opened — those are third-party file systems, not AmigaDOS.

A D64 can be formatted at 35, 40 or 42 tracks — 174,848, 196,608 and 205,312
bytes. The extra tracks are in the file and are read back, but the BAM a 1541
writes only reaches track 35, so all three still report 664 blocks free and
nothing here puts a file past track 35. That matches the drive: reaching those
tracks needs a DOS that was extended to know about them, and the extended DOSes
do not agree on where to keep their free counts.

## The system

`Return` walks into a folder or an image and plays a file that is a tune or a
tracker module. It used to open the player for anything at all, which meant a
text file produced a sheet asking for two hex addresses that were never going
to exist; now it says so in the status line instead, and `⇧Return` still forces
the SID player onto a file the browser cannot read as one.

`⌘O` is the other half: it hands the row to the system, exactly as a double
click in Finder would. On a `.d64` that is whatever opens `.d64` files on this
machine — an emulator, rather than this listing, which is what `Return` is for.
On a folder it is a Finder window. The two never overlap: `Return` navigates,
`⌘O` hands over. `⌥⌘R` reveals the row in Finder.

Right clicking a row gives both of those, an *Open With* list built from the
applications macOS offers for that file, and the commands that were otherwise
only on function keys — view, play, copy, move, rename, delete. *Play as SID*
reads the file the same way `Return` does, headers and all; the entry below it
is `⇧Return`, the player forced on with the addresses typed in by hand.

A file inside a disk image is not a file the system can reach, so opening one
writes a copy to a temporary folder and opens that. It is a copy: edits do not
go back into the image. The menu says *Open Copy* rather than *Open*, and the
copy is written read-only, so an editor reports it as locked instead of saving
into a folder nobody will read again. *Show in Finder* on such a row reveals the
image itself, the only thing that really exists.

While a sheet or an error message is up the browser takes no input at all. The
key monitor swallows the keystroke rather than passing it on, and the menus and
the key bar go grey to say so. Without that a function key still ran: the sheet
it asked for could not be shown over the alert, so it waited and sprang open the
moment the alert was dismissed, and `⌘D` — a menu shortcut, never seen by the
browser's own key handling — moved a panel nobody could see. `⌘Q` is the one
exception, since it is the way out.

## Commodore menu

Beyond plain file management: edit the disk header, insert a `DEL` entry to
draw rules and boxes in a directory, lock and unlock entries, and move an entry
up or down to rearrange the listing.

### Advanced

**Disk header**, **Rename** and **Add DEL entry** each ask for a name in a
plain text field, in the system font, which is right for nearly everything and
cannot say the half of PETSCII a decorated directory is written in. Each of the
three carries an **Advanced** disclosure that opens onto the bytes themselves.

The field is a row of cells drawn from the character ROM. Typing writes into
the cell under the caret and steps on, the arrows move it, `⌫` blanks a cell
back to a shifted space, and below sits a grid of every character no key
reaches — the graphics, the reverse video forms, the shifted space itself —
which the character set picker draws in either half of the ROM. *Every byte*
widens the grid to all 256.

A rename opens on the whole 16 byte name field, past the shifted space as well
as before it. That matters because a drive closes the quote on the first
shifted space and prints the rest of the field after it as ordinary characters,
which is where a decorated row keeps its graphics — and the browser draws its
listing rows the same way. Beside it is the block count the row prints, written
as given and checked against nothing, which is what lets a directory count in
pictures. **Add DEL entry** offers exactly the same, since a spacer row and a
file's row are decorated alike.

The header opens on the whole reverse-video line: 16 bytes of name, two of
padding, the two ID bytes, one more pad and the DOS type. The first pad byte is
where the drive puts the closing quote, so it never prints; everything after it
does, and the panel draws the line from those bytes rather than spelling the
gaps as spaces. **Blocks free** sets the figure the listing ends on by moving
the per-track free counters and leaving the allocation map alone — the way a
demo disk claims to be empty with the files still on it. `Repair Disk` counts
the map, so it would put the figure back.

### Repair Disk

The 1541's `VALIDATE`, with a report first. It walks every file's block chain —
and a `REL` file's side sectors, which nothing else here follows — then rebuilds
the allocation map from what it found, corrects the block count on every entry
that disagrees with its own file, and hands back the sectors that were marked
allocated and used by nothing.

It shows what it found before it writes anything: the unclosed files it will
scratch, the block counts it will correct, how many sectors it will free and
allocate, and what the free count will be afterwards. Like every other edit to
an image it lands in memory, so `Esc` still discards it and `⌘S` still commits
it.

An **unclosed file** — the `*` a drive leaves after an interrupted save — is
scratched, which is what `VALIDATE` does and is usually the whole problem: its
entry still points into a live file's data, and setting it aside first is what
lets the rest of the disk be put right. Of the 48 disks this was written
against, 19 hold one, and they account for 13 of the 17 that look like they
have two files sharing a sector.

What it will not do is guess. Two closed files claiming one sector, or a chain
that walks off the disk, is damage the allocation map cannot describe: the
report names the files and nothing is written. Seven of those 48 disks fall
that way; the other 41 come out clean.

It will, though, offer to get the damage out of the way. **Delete N Damaged
Files** scratches exactly the entries standing in the repair's path — every
claimant of a shared sector, and every file whose chain leaves the disk or
turns back on itself — and surveys again, so the repair it unblocks is still
read before it is agreed to. Both claimants of a shared sector go, not one of
them: the sector belongs to a single file and nothing on the disk says which,
so keeping either would be the guess the repair refuses to make. Only the
directory entries are touched; their blocks are left where they are for the
rebuild that follows to work out afresh. It is an edit like any other, so
leaving the image without saving still undoes the lot.

A `DEL` entry owns nothing — a scratched file's blocks go back to the disk and
only the name is left — so directory art is read as the decoration it is and
left alone.

## Printing a listing

`⌘P` prints what the active panel is showing, and prints it the way the panel
draws it. A Commodore directory goes to paper out of the character ROM — the
reverse-video header line, the block counts, the quoted names with whatever
decoration is padding them out, the file types, the locks, and the count of
free blocks the drive prints under them. It comes out in the half of the ROM
the panel is currently in, so switching to lower case with `⇧⌘C` before
printing prints in lower case. A host folder or an Amiga volume has no ROM
behind it and is set in the system's monospaced face instead, in the same
columns the panel shows: name, size, permission bits, date.

On screen the glyphs are a bitmap, one image pixel per C64 pixel, because a
screen has a pixel grid to line them up with. A printer does not — an 8 pixel
glyph would land on fractions of a dot at 600 dpi — so on paper the same glyphs
go down as rectangles, and stay square at any size.

Size and columns are chosen in the print dialog itself, in a **Listing** pane
beside the ones the printer provides, against the live preview:

* **Size** is the side of one character cell, 5 to 16 points.
* **Columns** runs the listing down the page once or twice. Two columns put a
  disk with a long directory on one sheet — a full 1541 directory of 144
  entries fits a single page at 8 points.

A listing too wide for the column it has been given is drawn smaller so it
still fits between the margins, which is what keeps two columns of a long
Amiga listing on the paper rather than off the edge of it. Both choices are
remembered for the next listing.

## Quick Look

Two app extensions put the same readers behind Finder's space bar.

**Thumbnails.** A picture becomes its own icon, drawn at the shape it was
meant to have rather than squared off. A folder of ILBMs or Koalas reads as
pictures instead of as a wall of blank pages. It compiles the picture reader and nothing
else — no emulator, no engines — because a thumbnail is asked for a folder at a
time and the system will not wait while something warms up.

**Previews.** Space bar on a picture shows it with its size and mode; on a SID
tune, a tracker module or an 8SVX sample it shows what the file is and starts
playing. Quick Look tears a preview down as the arrow keys move through a
folder, so the sound stops with it — otherwise walking past ten tunes would
leave ten running.

Both decide what a file is from its own bytes. What they cannot do is decide
which files to be offered in the first place: Quick Look routes by type, and a
type comes from the extension on the name. `.iff`, `.ilbm`, `.lbm`, `.anim`,
`.8svx`, `.sid`, `.mod`, `.xm`, `.s3m`, `.it`, `.med`, `.koa`, `.kla`, `.ocp`,
`.aas`, `.hed`, `.dd`, `.fcp`, `.ami`, `.bml` and a few more are declared and
work. An Amiga file called `mod.something` or `pic.1` does not:
its extension is the tune's name, so macOS has nothing to match. Those are what
the browser itself is for, where `Return` reads the bytes instead.

An extension only exists once the app is installed and registered, which means
in `/Applications` rather than run from a build folder:

```bash
cp -R build/Products/Release/CommodoreFileBrowser.app /Applications/
```

Opening it once is enough for macOS to find the extensions inside it. *System
Settings › General › Login Items & Extensions › Quick Look* lists them, and is
where to turn them off.

## Credits

The two audio engines are vendored into the tree rather than linked, so there is
no library to find at run time. Both keep their own licence files.

| | | |
|---|---|---|
| **cSID-light** | Hermit (Mihaly Horvath) | The SID chip and the 6502 around it, in `Audio/csid.c`. A single C file, trimmed to the playback path. Licensed "do what you want, but please mention me as its original author". |
| **libopenmpt** | OpenMPT project | The tracker formats — MOD, XM, S3M, IT, MED and the rest — in `Audio/libopenmpt/`. BSD-3-Clause. |
| **c-flod** | rofl0r, ported from Flod by Christian Corti | The Amiga chiptune players — Future Composer, SoundMon, Hippel, SidMon, Whittaker, Hubbard, Fred, Delta Music, Digital Mugician, SoundFX — in `Audio/cflod/`. **CC BY-NC-SA 3.0**, which is not the licence the rest of this carries. |

The `character.rom` and `pet_characters.rom` files are the Commodore 64 and PET
character generators.

### What was changed

cSID-light's own front end and file loading were removed; its CPU and SID
emulation are untouched. The additions are a small API for the load address,
the init and play routines, the A/X/Y byte and an explicit playback rate, plus
a per-voice tap for the oscilloscope.

libopenmpt is the released source with the test suites and the build system
dropped. Only its C API is exposed to Swift, through a shim the size of the SID
one.

c-flod needed three changes. It traps into the debugger when a file will not
fit one of its fixed-size buffers, which in an application means the process
dies — and since these formats are recognised by handing the file to each
player in turn, being wrong has to be survivable. Those checks guard writes
into the buffers, so they cannot simply be compiled out; instead there is a
landing point in the shim that they jump back to, and the load fails rather
than the app. It also assumed an x86 debug instruction, and allowed a module
only 286 KB of sample memory where the machines these came from had two
megabytes. Its tracker and FastTracker players are left out: libopenmpt plays
those, and c-flod's FastTracker is a 5.8 MB static structure dimensioned for 32
instruments that fails on ordinary XM files.

## The source tree

Three targets share one folder tree:

| | |
|---|---|
| `Shared/Picture` | the IFF container and the ILBM reader — the app, the previews and the thumbnails |
| `Shared/Sound` | SID, module and 8SVX readers, the three players, and the vendored C engines — the app and the previews |
| `CommodoreFileBrowser` | the browser: panels, dialogs, disk formats, themes, video export |
| `QuickLookPreview`, `QuickLookThumbnail` | one file each, near enough |

Xcode compiles a folder into a target, so the tree is what says which target
gets what — there are no membership lists to keep in step. Each target compiles
its folders into one module, so nothing needs importing and nothing needs to be
`public`. `Shared/Sound` reads IFF chunks for its 8SVX, so anything taking
Sound takes Picture too.

The engines are compiled twice, once for the browser and once for the preview
extension. That is about seventy seconds of libopenmpt per architecture on a
clean build and nothing at all on an incremental one — cheaper than a framework
and the `public` annotations one would need across thirty files.

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
without changing the file. And the drag rules: which of move and copy two
places imply, which drops are refused before the mouse is let go, and that a
drop between two folders, into an image, back out of one, or in from another
application puts the files where they were dropped. The pointer itself is not
driven — everything behind it is.

The music side is checked against real collections rather than fixtures. SID:
the naming convention against every shape on the disks, PSID parsing, and the
Music Assembler signature across 256 tunes. Modules: that content detection
finds all 152 modules in the music folder and 47 more inside 200 ADF and DMS
images while taking none of 601 icons, libraries, fonts, bitmaps and source
files for one; that both engines open and sound every module found; and that
sixty-four files of noise can be handed to every chiptune player without taking
the process down.
