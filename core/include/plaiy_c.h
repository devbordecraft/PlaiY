#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Error codes ----
enum PYError {
    PY_OK = 0,
    PY_ERROR_UNKNOWN = 1,
    PY_ERROR_INVALID_ARG = 2,
    PY_ERROR_FILE_NOT_FOUND = 3,
    PY_ERROR_UNSUPPORTED = 4,
    PY_ERROR_DECODER = 5,
    PY_ERROR_AUDIO = 6,
    PY_ERROR_SUBTITLE = 7,
};

// ---- Playback state ----
enum PYPlaybackState {
    PY_STATE_IDLE = 0,
    PY_STATE_OPENING = 1,
    PY_STATE_READY = 2,
    PY_STATE_PLAYING = 3,
    PY_STATE_PAUSED = 4,
    PY_STATE_STOPPED = 5,
};

// ---- HDR type ----
enum PYHDRType {
    PY_HDR_SDR = 0,
    PY_HDR_HDR10 = 1,
    PY_HDR_HDR10_PLUS = 2,
    PY_HDR_HLG = 3,
    PY_HDR_DOLBY_VISION = 4,
};

// ---- Opaque handles ----
typedef struct PYPlayer PYPlayer;
typedef struct PYLibrary PYLibrary;

// ---- Player lifecycle ----
PYPlayer*   py_player_create(void);
void        py_player_destroy(PYPlayer* p);

int         py_player_open(PYPlayer* p, const char* path);
void        py_player_play(PYPlayer* p);
void        py_player_pause(PYPlayer* p);
void        py_player_seek(PYPlayer* p, int64_t timestamp_us);
void        py_player_stop(PYPlayer* p);

int         py_player_get_state(PYPlayer* p);
int64_t     py_player_get_position(PYPlayer* p);
int64_t     py_player_get_duration(PYPlayer* p);

// ---- Track info ----
int         py_player_get_audio_track_count(PYPlayer* p);
int         py_player_get_subtitle_track_count(PYPlayer* p);
void        py_player_select_audio_track(PYPlayer* p, int index);
void        py_player_select_subtitle_track(PYPlayer* p, int index);

// ---- Media info ----
const char* py_player_get_media_info_json(PYPlayer* p);

// ---- Video frame acquisition (called from display link) ----
// Returns an opaque frame handle; NULL if no frame ready.
void*       py_player_acquire_video_frame(PYPlayer* p, int64_t target_pts_us);
void        py_player_release_video_frame(PYPlayer* p, void* frame);

// Get properties of an acquired frame
void*       py_player_frame_get_pixel_buffer(void* frame);   // CVPixelBufferRef (Apple)
int         py_player_frame_get_width(void* frame);
int         py_player_frame_get_height(void* frame);
int         py_player_frame_get_hdr_type(void* frame);
int         py_player_frame_get_color_space(void* frame);
int         py_player_frame_get_color_trc(void* frame);
bool        py_player_frame_is_hardware(void* frame);

// ---- Subtitle ----
typedef struct {
    // For text subtitles
    const char* text;       // NULL for bitmap subs

    // For bitmap subtitles
    const uint8_t* rgba_data;
    int width;
    int height;
    int x;
    int y;

    // Timing
    int64_t start_us;
    int64_t end_us;

    // Number of bitmap regions (for ASS)
    int region_count;
} PYSubtitleFrame;

PYSubtitleFrame* py_player_get_subtitle(PYPlayer* p, int64_t timestamp_us);
void             py_subtitle_free(PYSubtitleFrame* sf);

// ---- Callbacks ----
typedef void (*PYStateCallback)(int state, void* userdata);
typedef void (*PYErrorCallback)(int error_code, const char* message, void* userdata);
void py_player_set_state_callback(PYPlayer* p, PYStateCallback cb, void* userdata);
void py_player_set_error_callback(PYPlayer* p, PYErrorCallback cb, void* userdata);

// ---- Logging ----
enum PYLogLevel {
    PY_LOG_LEVEL_DEBUG = 0,
    PY_LOG_LEVEL_INFO = 1,
    PY_LOG_LEVEL_WARNING = 2,
    PY_LOG_LEVEL_ERROR = 3,
};

void py_log_set_level(int level);
int  py_log_get_level(void);

typedef void (*PYLogCallback)(int level, const char* tag, const char* message, void* userdata);
void py_log_set_callback(PYLogCallback cb, void* userdata);

// ---- Media Library ----
PYLibrary*  py_library_create(void);
void        py_library_destroy(PYLibrary* lib);
int         py_library_add_folder(PYLibrary* lib, const char* path);
int         py_library_get_item_count(PYLibrary* lib);
// Returns a JSON string for the item at index. Caller must NOT free.
const char* py_library_get_item_json(PYLibrary* lib, int index);
// Returns JSON for all items
const char* py_library_get_all_items_json(PYLibrary* lib);

#ifdef __cplusplus
}
#endif
