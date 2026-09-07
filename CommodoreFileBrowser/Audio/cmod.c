// Tracker module playback, wrapping libopenmpt. See cmod.h.
//
// libopenmpt is per-module rather than a global machine, but the app plays one
// thing at a time and the SID engine beside this one is already shaped that
// way, so the handle is kept here rather than handed to Swift.

#include <stdlib.h>
#include <string.h>

#include "libopenmpt/libopenmpt/libopenmpt.h"

#include "cmod.h"

static openmpt_module *module;
static int rate = 44100;

// libopenmpt hands out strings the caller has to free. Holding the last of
// each keeps the header's promise that they stay valid until the next open.
static char *type_string;
static char *tracker_string;
static char *title_string;

#define CMOD_MAX_VOICES 64
static double voice_levels[CMOD_MAX_VOICES];
static int voice_count;

static void take(char **slot, const char *owned) {
    free(*slot);
    *slot = owned && *owned ? strdup(owned) : NULL;
    if (owned) openmpt_free_string(owned);
}

static const char *or_empty(const char *s) { return s ? s : ""; }

void cmod_close(void) {
    if (module) { openmpt_module_destroy(module); module = NULL; }
    take(&type_string, NULL);
    take(&tracker_string, NULL);
    take(&title_string, NULL);
    memset(voice_levels, 0, sizeof(voice_levels));
    voice_count = 0;
}

int cmod_open(const unsigned char *data, int length, int samplerate) {
    cmod_close();
    if (!data || length <= 0) return 0;

    rate = samplerate > 0 ? samplerate : 44100;
    // Silent logging: a file the browser offers is one it already believes in,
    // and a format libopenmpt does not know is answered by the return value,
    // not by a line on the console.
    module = openmpt_module_create_from_memory2(data, (size_t)length,
                                                openmpt_log_func_silent, NULL,
                                                openmpt_error_func_ignore, NULL,
                                                NULL, NULL, NULL);
    if (!module) return 0;

    take(&type_string, openmpt_module_get_metadata(module, "type"));
    take(&tracker_string, openmpt_module_get_metadata(module, "tracker"));
    take(&title_string, openmpt_module_get_metadata(module, "title"));

    // Stop at the end rather than looping, which is what a file browser
    // playing through a directory wants.
    openmpt_module_set_repeat_count(module, 0);

    voice_count = openmpt_module_get_num_channels(module);
    if (voice_count > CMOD_MAX_VOICES) voice_count = CMOD_MAX_VOICES;
    return 1;
}

int cmod_render(short *stream, int frames) {
    if (!stream || frames <= 0) return 0;
    if (!module) { memset(stream, 0, (size_t)frames * 2 * sizeof(short)); return 0; }

    size_t got = openmpt_module_read_interleaved_stereo(module, rate, (size_t)frames, stream);
    if ((int)got < frames) {
        memset(stream + got * 2, 0, ((size_t)frames - got) * 2 * sizeof(short));
    }

    for (int v = 0; v < voice_count; v++) {
        voice_levels[v] = openmpt_module_get_current_channel_vu_mono(module, v);
    }
    return (int)got;
}

const char *cmod_type(void) { return or_empty(type_string); }
const char *cmod_tracker(void) { return or_empty(tracker_string); }
const char *cmod_title(void) { return or_empty(title_string); }

int cmod_channels(void) { return module ? openmpt_module_get_num_channels(module) : 0; }
int cmod_instruments(void) { return module ? openmpt_module_get_num_instruments(module) : 0; }
int cmod_samples(void) { return module ? openmpt_module_get_num_samples(module) : 0; }
int cmod_patterns(void) { return module ? openmpt_module_get_num_patterns(module) : 0; }

int cmod_subsong_count(void) { return module ? openmpt_module_get_num_subsongs(module) : 0; }

void cmod_set_subsong(int index) {
    if (module) openmpt_module_select_subsong(module, index);
}

double cmod_duration(void) { return module ? openmpt_module_get_duration_seconds(module) : 0.0; }
double cmod_position(void) { return module ? openmpt_module_get_position_seconds(module) : 0.0; }

void cmod_seek(double seconds) {
    if (module) openmpt_module_set_position_seconds(module, seconds);
}

void cmod_set_repeat(int on) {
    if (module) openmpt_module_set_repeat_count(module, on ? -1 : 0);
}

void cmod_set_gain(int millibel) {
    if (module) {
        openmpt_module_set_render_param(module, OPENMPT_MODULE_RENDER_MASTERGAIN_MILLIBEL, millibel);
    }
}

void cmod_set_stereo_separation(int percent) {
    if (module) {
        openmpt_module_set_render_param(module,
            OPENMPT_MODULE_RENDER_STEREOSEPARATION_PERCENT, percent);
    }
}

int cmod_voice_count(void) { return voice_count; }

double cmod_voice_level(int voice) {
    if (voice < 0 || voice >= voice_count) return 0.0;
    return voice_levels[voice];
}
