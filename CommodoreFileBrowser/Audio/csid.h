#ifndef CSID_H
#define CSID_H

// Commodore SID playback, wrapping Hermit's cSID-light engine. See csid.c.
//
// The engine is a single global machine, so exactly one tune plays at a time.
// Order of use: csid_init, csid_load, csid_set_addresses, csid_set_sid,
// csid_set_speed_hz, csid_start, then csid_render from the audio thread.

void cSID_init(int samplerate);

/// Copy a tune body into the C64 address space at `loadaddr`, clearing the
/// rest. The two byte PRG load address must already be stripped.
void csid_load(const unsigned char *data, int length, unsigned int loadaddr);

/// A play address of zero means the tune installs its own interrupt and the
/// vector is read after init.
void csid_set_addresses(unsigned int init_addr, unsigned int play_addr);

/// 6581 or 8580; a second and third SID base address, or zero for none.
void csid_set_sid(int model, unsigned int addr2, unsigned int addr3);

/// Calls to the play routine per second. Zero keeps the tune's own timing,
/// which is 50 Hz vsync or whatever its CIA timer asks for. Takes effect
/// immediately: the tune keeps playing rather than restarting.
void csid_set_speed_hz(double hz);

/// 6581 or 8580, applied mid-tune without restarting it.
void csid_set_model(int model);

/// Runs the init routine with `axy` in A, X and Y — how a C64 tune is told
/// which song to play.
void csid_start(unsigned char subtune, unsigned char axy);

/// One 16-bit mono sample per frame, at the rate given to cSID_init.
void csid_render(short *stream, int frames);

/// Oscilloscope capture. Off by default; enabling clears the window.
void csid_scope_enable(int on);
int csid_scope_length(void);
int csid_sid_count(void);
/// Most recent `count` samples of a track, oldest first. Tracks 0-8 are the
/// voices in chip order, track 9 is the mix.
void csid_scope_read(int track, short *dest, int count);

unsigned long csid_play_call_count(void);
double csid_frame_sampleperiod(void);

#endif
