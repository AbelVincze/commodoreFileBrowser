#ifndef CMOD_H
#define CMOD_H

// Tracker module playback, wrapping libopenmpt. See cmod.c.
//
// Like the SID engine next door this is a single global machine, so exactly
// one module plays at a time and opening another replaces it. Order of use:
// cmod_open, then cmod_render from the audio thread.
//
// Everything here is safe to call with nothing open; renders produce silence
// and the readers answer with zero or an empty string.

/// Open a module from bytes already in memory. Returns 1 if libopenmpt
/// recognised it, 0 if it did not — which is also how the caller learns that a
/// file the browser identified is of a format no player here handles.
int cmod_open(const unsigned char *data, int length, int samplerate);

void cmod_close(void);

/// Interleaved stereo, two shorts per frame, at the rate given to cmod_open.
/// Returns frames actually written; a short count means the module ended.
int cmod_render(short *stream, int frames);

/// What libopenmpt made of it: "mod", "xm", "s3m", "med" and so on, the name
/// of the tracker that wrote it, and the title stored inside the file. All
/// three may be empty. The strings belong to the engine and stay valid until
/// the next cmod_open or cmod_close.
const char *cmod_type(void);
const char *cmod_tracker(void);
const char *cmod_title(void);

int cmod_channels(void);
int cmod_instruments(void);
int cmod_samples(void);
int cmod_patterns(void);

/// Subsongs, which XM and MED files sometimes carry. Selecting one restarts.
int cmod_subsong_count(void);
void cmod_set_subsong(int index);

/// Seconds. Position is where playback has got to, and may be set.
double cmod_duration(void);
double cmod_position(void);
void cmod_seek(double seconds);

/// Whether to start over at the end rather than stopping. Off by default.
void cmod_set_repeat(int on);

/// Master gain in millibel, and stereo separation as a percentage where 100 is
/// what the file asks for and 0 is mono. Both apply while the module plays.
void cmod_set_gain(int millibel);
void cmod_set_stereo_separation(int percent);

/// Whether the tempo can be changed at all: it comes from libopenmpt's
/// extended interface, which not every build has to provide.
int cmod_can_set_tempo(void);

/// How fast the module is stepped through its patterns, 1 being its own tempo.
/// The samples still come out at the render rate, so this is speed without a
/// change of pitch. Clamped to 0.25...4: libopenmpt throws outside that rather
/// than clamping, and a thrown factor is one that never gets applied.
void cmod_set_tempo_factor(double factor);

/// Where in the order list playback is, and how long that list is. This is
/// the module's own idea of where it has got to, and it is what moves when the
/// tempo factor is raised — the position in seconds counts audio rendered, so
/// it does not.
int cmod_current_order(void);
int cmod_order_count(void);

/// Per-voice levels for the oscilloscope, 0 to 1, as of the last render.
int cmod_voice_count(void);
double cmod_voice_level(int voice);

#endif
