// Tracker module playback, wrapping libopenmpt. See cmod.h.
//
// libopenmpt is per-module rather than a global machine, but the app plays one
// thing at a time and the SID engine beside this one is already shaped that
// way, so the handle is kept here rather than handed to Swift.

#include <stdlib.h>
#include <string.h>

#include "libopenmpt/libopenmpt/libopenmpt.h"
#include "libopenmpt/libopenmpt/libopenmpt_ext.h"

#include "cmod.h"

// Opened through the extended interface rather than the plain one. Everything
// here works on the plain handle it hands back; the extension is only for the
// tempo factor, which is not a render parameter or a ctl but lives behind the
// "interactive" interface.
static openmpt_module_ext *extended;
static openmpt_module *module;
static openmpt_module_ext_interface_interactive interactive;
static int has_interactive;
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
    if (extended) { openmpt_module_ext_destroy(extended); extended = NULL; }
    module = NULL;
    memset(&interactive, 0, sizeof(interactive));
    has_interactive = 0;
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
    extended = openmpt_module_ext_create_from_memory(data, (size_t)length,
                                                     openmpt_log_func_silent, NULL,
                                                     openmpt_error_func_ignore, NULL,
                                                     NULL, NULL, NULL);
    if (!extended) return 0;
    module = openmpt_module_ext_get_module(extended);
    if (!module) { cmod_close(); return 0; }
    has_interactive = openmpt_module_ext_get_interface(
        extended, LIBOPENMPT_EXT_C_INTERFACE_INTERACTIVE,
        &interactive, sizeof(interactive)) != 0;

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

int cmod_can_set_tempo(void) { return has_interactive && interactive.set_tempo_factor != NULL; }

void cmod_set_tempo_factor(double factor) {
    // libopenmpt's own fast forward: the module is stepped through its patterns
    // faster while the samples still come out at the render rate, so it plays
    // quicker without changing pitch. Held to the range the library documents.
    // libopenmpt throws outside this range rather than clamping, and a thrown
    // factor is one that never gets applied at all — which is exactly how a
    // fast forward can look like it is running while nothing moves.
    if (!cmod_can_set_tempo()) return;
    if (factor < 0.25) factor = 0.25;
    if (factor > 4.0) factor = 4.0;
    interactive.set_tempo_factor(extended, factor);
}

int cmod_current_order(void) { return module ? openmpt_module_get_current_order(module) : 0; }
int cmod_order_count(void) { return module ? openmpt_module_get_num_orders(module) : 0; }

int cmod_voice_count(void) { return voice_count; }

double cmod_voice_level(int voice) {
    if (voice < 0 || voice >= voice_count) return 0.0;
    return voice_levels[voice];
}
