#ifndef CFLOD_H
#define CFLOD_H

// The Amiga chiptune players, wrapping c-flod. See cflod.c.
//
// This sits behind libopenmpt rather than beside it: libopenmpt plays the
// tracker formats, and these are the ones it has no reader for — Future
// Composer, SoundMon, Hippel, SidMon, Whittaker and the rest, where the
// "module" is a player routine with its data rather than a pattern table.
//
// A third global machine, like the two beside it, so one thing plays at a time.
//
// Licence note: c-flod and the Flod it was ported from are CC BY-NC-SA 3.0,
// which is not the BSD licence libopenmpt carries. See cflod/LICENSE.txt.

/// Try each player in turn and keep the first that validates the file. There
/// are no magic bytes for most of these formats, so claiming one is the only
/// test there is. Returns 1 if a player took it.
int cflod_open(const unsigned char *data, int length);

void cflod_close(void);

/// Interleaved stereo at 44100, which is the only rate c-flod is built for —
/// its period tables are scaled to it. Returns frames written; a short count
/// means the tune ended or the engine gave up on it.
int cflod_render(short *stream, int frames);

/// Which player claimed it, e.g. "BP SoundMon". Empty when nothing is open.
const char *cflod_player_name(void);

/// Songs inside the file, and which one to play. Selecting one restarts.
int cflod_subsong_count(void);
void cflod_set_subsong(int index);

/// Set when a bounds check inside c-flod fired and the file was abandoned. The
/// engine is 2012 code with fixed-size buffers, and not every module in the
/// world fits them; this is how the caller learns that rather than by crashing.
int cflod_gave_up(void);

#endif
