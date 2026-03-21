#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Error codes ----
enum TPError {
    TP_OK = 0,
    TP_ERROR_UNKNOWN = 1,
    TP_ERROR_INVALID_ARG = 2,
    TP_ERROR_FILE_NOT_FOUND = 3,
    TP_ERROR_UNSUPPORTED = 4,
    TP_ERROR_DECODER = 5,
    TP_ERROR_AUDIO = 6,
    TP_ERROR_SUBTITLE = 7,
};

// ---- Playback state ----
enum TPPlaybackState {
    TP_STATE_IDLE = 0,
    TP_STATE_OPENING = 1,
    TP_STATE_READY = 2,
    TP_STATE_PLAYING = 3,
    TP_STATE_PAUSED = 4,
    TP_STATE_STOPPED = 5,
};

// ---- HDR type ----
enum TPHDRType {
    TP_HDR_SDR = 0,
    TP_HDR_HDR10 = 1,
    TP_HDR_HDR10_PLUS = 2,
    TP_HDR_HLG = 3,
    TP_HDR_DOLBY_VISION = 4,
};

// ---- Opaque handles ----
typedef struct TPPlayer TPPlayer;
typedef struct TPLibrary TPLibrary;

// ---- Player lifecycle ----
TPPlayer*   tp_player_create(void);
void        tp_player_destroy(TPPlayer* p);

int         tp_player_open(TPPlayer* p, const char* path);
void        tp_player_play(TPPlayer* p);
void        tp_player_pause(TPPlayer* p);
void        tp_player_seek(TPPlayer* p, int64_t timestamp_us);
void        tp_player_stop(TPPlayer* p);

int         tp_player_get_state(TPPlayer* p);
int64_t     tp_player_get_position(TPPlayer* p);
int64_t     tp_player_get_duration(TPPlayer* p);

// ---- Track info ----
int         tp_player_get_audio_track_count(TPPlayer* p);
int         tp_player_get_subtitle_track_count(TPPlayer* p);
void        tp_player_select_audio_track(TPPlayer* p, int index);
void        tp_player_select_subtitle_track(TPPlayer* p, int index);

// ---- Media info ----
const char* tp_player_get_media_info_json(TPPlayer* p);

// ---- Video frame acquisition (called from display link) ----
// Returns an opaque frame handle; NULL if no frame ready.
void*       tp_player_acquire_video_frame(TPPlayer* p, int64_t target_pts_us);
void        tp_player_release_video_frame(TPPlayer* p, void* frame);

// Get properties of an acquired frame
void*       tp_player_frame_get_pixel_buffer(void* frame);   // CVPixelBufferRef (Apple)
int         tp_player_frame_get_width(void* frame);
int         tp_player_frame_get_height(void* frame);
int         tp_player_frame_get_hdr_type(void* frame);
int         tp_player_frame_get_color_space(void* frame);
int         tp_player_frame_get_color_trc(void* frame);
bool        tp_player_frame_is_hardware(void* frame);

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
} TPSubtitleFrame;

TPSubtitleFrame* tp_player_get_subtitle(TPPlayer* p, int64_t timestamp_us);
void             tp_subtitle_free(TPSubtitleFrame* sf);

// ---- Callbacks ----
typedef void (*TPStateCallback)(int state, void* userdata);
typedef void (*TPErrorCallback)(int error_code, const char* message, void* userdata);
void tp_player_set_state_callback(TPPlayer* p, TPStateCallback cb, void* userdata);
void tp_player_set_error_callback(TPPlayer* p, TPErrorCallback cb, void* userdata);

// ---- Logging ----
enum TPLogLevel {
    TP_LOG_LEVEL_DEBUG = 0,
    TP_LOG_LEVEL_INFO = 1,
    TP_LOG_LEVEL_WARNING = 2,
    TP_LOG_LEVEL_ERROR = 3,
};

void tp_log_set_level(int level);
int  tp_log_get_level(void);

typedef void (*TPLogCallback)(int level, const char* tag, const char* message, void* userdata);
void tp_log_set_callback(TPLogCallback cb, void* userdata);

// ---- Media Library ----
TPLibrary*  tp_library_create(void);
void        tp_library_destroy(TPLibrary* lib);
int         tp_library_add_folder(TPLibrary* lib, const char* path);
int         tp_library_get_item_count(TPLibrary* lib);
// Returns a JSON string for the item at index. Caller must NOT free.
const char* tp_library_get_item_json(TPLibrary* lib, int index);
// Returns JSON for all items
const char* tp_library_get_all_items_json(TPLibrary* lib);

#ifdef __cplusplus
}
#endif
