// The Amiga chiptune players, wrapping c-flod. See cflod.h.
//
// Two things about c-flod shape this file.
//
// It has no detection worth using: the FileLoader that came with the C port is
// half converted, most of its checks still sitting in the source as commented
// out ActionScript. That does not matter, because these formats mostly have no
// magic bytes to check anyway — a Hippel or a Whittaker tune is a player
// routine with data behind it. The way to recognise one is to let each player
// read the file and see which validates it, which is what cflod_open does.
//
// And it is 2012 code that traps into the debugger when a file does not fit its
// fixed-size buffers, which in an application means the process dies. The
// checks cannot be compiled out — they guard writes into those buffers — so
// instead there is a landing point here that they jump back to.

#include <setjmp.h>
#include <stdlib.h>
#include <string.h>

#include "cflod/flashlib/ByteArray.h"
#include "cflod/neoart/flod/core/CorePlayer.h"
#include "cflod/neoart/flod/core/Amiga.h"
#include "cflod/neoart/flod/core/Soundblaster.h"
#include "cflod/neoart/flod/futurecomposer/FCPlayer.h"
#include "cflod/neoart/flod/digitalmugician/DMPlayer.h"
#include "cflod/neoart/flod/sidmon/S1Player.h"
#include "cflod/neoart/flod/sidmon/S2Player.h"
#include "cflod/neoart/flod/soundfx/FXPlayer.h"
#include "cflod/neoart/flod/soundmon/BPPlayer.h"
#include "cflod/neoart/flod/hubbard/RHPlayer.h"
#include "cflod/neoart/flod/fred/FEPlayer.h"
#include "cflod/neoart/flod/hippel/JHPlayer.h"
#include "cflod/neoart/flod/deltamusic/D1Player.h"
#include "cflod/neoart/flod/deltamusic/D2Player.h"
#include "cflod/neoart/flod/whittaker/DWPlayer.h"

#include "cflod.h"

// MARK: - The landing point

static jmp_buf escape;
static int guarded;      // whether a longjmp would land somewhere valid
static int gave_up;

void cflod_panic(void) {
    if (guarded) { guarded = 0; longjmp(escape, 1); }
    // Outside a guarded section there is nowhere to jump to. Note it and carry
    // on: the alternative is killing the application.
    gave_up = 1;
}

// Deliberately not wrapped in do/while: the failure handler is sometimes a
// `continue`, which has to reach the enclosing loop rather than a wrapper.
#define CFLOD_GUARD_BEGIN(on_failure)          \
    guarded = 1;                               \
    if (setjmp(escape)) {                      \
        guarded = 0;                           \
        gave_up = 1;                           \
        on_failure;                            \
    }

#define CFLOD_GUARD_END() guarded = 0

// MARK: - The players, in the order they are tried

// Order matters. The players that check a signature come before the ones that
// work structurally, and the loosest — Whittaker, which scans for 68000 code
// patterns — comes last, so a file it might have claimed goes to a player that
// is sure of it first.
enum { P_FC, P_DM, P_S2, P_BP, P_FX, P_D1, P_D2, P_JH, P_FE, P_RH, P_S1, P_DW, P_MAX };

static const char *player_names[P_MAX] = {
    "Future Composer", "Digital Mugician", "SidMon II", "BP SoundMon",
    "SoundFX", "Delta Music 1", "Delta Music 2", "Jochen Hippel", "Fred Editor",
    "Rob Hubbard", "SidMon", "David Whittaker",
};

typedef void (*player_ctor)(struct CorePlayer *, struct CoreMixer *);

static const player_ctor player_ctors[P_MAX] = {
    (player_ctor)FCPlayer_ctor, (player_ctor)DMPlayer_ctor, (player_ctor)S2Player_ctor,
    (player_ctor)BPPlayer_ctor, (player_ctor)FXPlayer_ctor, (player_ctor)D1Player_ctor,
    (player_ctor)D2Player_ctor, (player_ctor)JHPlayer_ctor, (player_ctor)FEPlayer_ctor,
    (player_ctor)RHPlayer_ctor, (player_ctor)S1Player_ctor, (player_ctor)DWPlayer_ctor,
};

// One union big enough for whichever player wins, so nothing is allocated.
static union {
    struct CorePlayer core;
    struct FCPlayer fc; struct DMPlayer dm; struct S1Player s1; struct S2Player s2;
    struct FXPlayer fx; struct BPPlayer bp; struct RHPlayer rh; struct FEPlayer fe;
    struct JHPlayer jh; struct D1Player d1; struct D2Player d2; struct DWPlayer dw;
} player;

static union { struct CoreMixer core; struct Amiga amiga; } hardware;

static struct ByteArray stream;
static struct ByteArray wave;
static unsigned char wave_buffer[COREMIXER_MAX_BUFFER * 2 * sizeof(float)];
static unsigned char *file_copy;

static int chosen = -1;
static int open_flag;

// c-flod produces its output a tick at a time rather than on demand, so what
// one call asks for and what the mixer gives rarely match. Whatever is left
// over waits here for the next call.
static short carry[COREMIXER_MAX_BUFFER * 2];
static int carry_frames;
static int carry_read;

// MARK: - Opening

void cflod_close(void) {
    open_flag = 0;
    free(file_copy); file_copy = NULL;
    chosen = -1;
    carry_frames = carry_read = 0;
    gave_up = 0;
    guarded = 0;
}

int cflod_open(const unsigned char *data, int length) {
    cflod_close();
    if (!data || length <= 0) return 0;

    // The players keep pointers into the stream while they play, so the bytes
    // have to outlive the call.
    file_copy = malloc((size_t)length);
    if (!file_copy) return 0;
    memcpy(file_copy, data, (size_t)length);

    ByteArray_ctor(&stream);
    if (!ByteArray_open_mem(&stream, (char *)file_copy, (size_t)length)) {
        cflod_close();
        return 0;
    }
    open_flag = 1;

    // Both live across the setjmp below, so both have to survive a longjmp.
    for (volatile int i = 0; i < P_MAX; i++) {
        volatile int claimed = 0;
        Amiga_ctor(&hardware.amiga);
        player_ctors[(int)i](&player.core, &hardware.core);
        if ((unsigned)length <= player.core.min_filesize) continue;

        // A player reading a file it does not understand is exactly when the
        // bounds checks fire, so every attempt is guarded.
        CFLOD_GUARD_BEGIN({ continue; });
        CorePlayer_load(&player.core, &stream);
        claimed = player.core.version != 0;
        CFLOD_GUARD_END();

        if (claimed) {
            chosen = (int)i;
            ByteArray_ctor(&wave);
            wave.endian = BAE_LITTLE;
            ByteArray_open_mem(&wave, (char *)wave_buffer, sizeof(wave_buffer));
            hardware.core.wave = &wave;

            CFLOD_GUARD_BEGIN({ cflod_close(); return 0; });
            player.core.initialize(&player.core);
            CFLOD_GUARD_END();
            gave_up = 0;
            return 1;
        }
    }

    cflod_close();
    return 0;
}

// MARK: - Rendering

/// Ask the mixer for its next tick, and put what comes back in the carry.
/// Returns 0 when the tune is over or the engine gave up on it.
static int pull(void) {
    if (chosen < 0 || gave_up) return 0;
    if (CoreMixer_get_complete(&hardware.core)) return 0;

    wave.pos = 0;
    CFLOD_GUARD_BEGIN({ return 0; });
    hardware.core.accurate(&hardware.core);
    CFLOD_GUARD_END();

    // The mixer writes interleaved stereo shorts, four bytes to the frame.
    int frames = wave.pos / 4;
    if (frames <= 0) return 0;
    if (frames > COREMIXER_MAX_BUFFER) frames = COREMIXER_MAX_BUFFER;
    memcpy(carry, wave_buffer, (size_t)frames * 4);
    carry_frames = frames;
    carry_read = 0;
    return 1;
}

int cflod_render(short *stream_out, int frames) {
    if (!stream_out || frames <= 0) return 0;
    if (chosen < 0) {
        memset(stream_out, 0, (size_t)frames * 2 * sizeof(short));
        return 0;
    }

    int done = 0;
    while (done < frames) {
        if (carry_read >= carry_frames && !pull()) break;
        int available = carry_frames - carry_read;
        int take = frames - done;
        if (take > available) take = available;
        memcpy(stream_out + done * 2, carry + carry_read * 2, (size_t)take * 4);
        done += take;
        carry_read += take;
    }
    if (done < frames) {
        memset(stream_out + done * 2, 0, ((size_t)frames - done) * 2 * sizeof(short));
    }
    return done;
}

// MARK: - What it is

const char *cflod_player_name(void) {
    return chosen >= 0 ? player_names[chosen] : "";
}

int cflod_subsong_count(void) {
    return chosen >= 0 ? player.core.lastSong + 1 : 0;
}

void cflod_set_subsong(int index) {
    if (chosen < 0 || index < 0 || index > player.core.lastSong) return;
    player.core.playSong = index;
    carry_frames = carry_read = 0;
    CFLOD_GUARD_BEGIN({ return; });
    player.core.initialize(&player.core);
    CFLOD_GUARD_END();
}

int cflod_gave_up(void) { return gave_up; }
