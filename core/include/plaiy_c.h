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

// ---- Hardware decode preference ----
enum PYHWDecodePref {
    PY_HW_DECODE_AUTO = 0,
    PY_HW_DECODE_FORCE_HW = 1,
    PY_HW_DECODE_FORCE_SW = 2,
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

// ---- Player configuration (call before py_player_open) ----
void        py_player_set_hw_decode_pref(PYPlayer* p, int pref);
void        py_player_set_subtitle_font_scale(PYPlayer* p, double scale);

int         py_player_get_state(PYPlayer* p);
int64_t     py_player_get_position(PYPlayer* p);
int64_t     py_player_get_duration(PYPlayer* p);

// ---- Track info ----
int         py_player_get_audio_track_count(PYPlayer* p);
int         py_player_get_subtitle_track_count(PYPlayer* p);
void        py_player_select_audio_track(PYPlayer* p, int index);
void        py_player_select_subtitle_track(PYPlayer* p, int index);
int         py_player_get_active_audio_stream(PYPlayer* p);
int         py_player_get_active_subtitle_stream(PYPlayer* p);

// ---- Audio passthrough ----
void        py_player_set_audio_passthrough(PYPlayer* p, bool enabled);
bool        py_player_is_passthrough_active(PYPlayer* p);

// ---- Playback stats (debug overlay) ----
typedef struct {
    // Video
    int video_width;
    int video_height;
    int video_codec_id;
    char video_codec_name[32];
    bool hardware_decode;
    double video_fps;
    int frames_rendered;
    int frames_dropped;
    int video_queue_size;
    int video_packet_queue_size;

    // Audio
    int audio_codec_id;
    char audio_codec_name[32];
    int audio_sample_rate;
    int audio_channels;
    int audio_output_channels;
    bool audio_passthrough;
    int audio_packet_queue_size;
    int audio_ring_fill_pct;

    // Sync
    int64_t audio_pts_us;
    int64_t video_pts_us;
    int64_t av_drift_us;

    // Container
    char container_format[32];
    int64_t bitrate;

    // HDR
    int hdr_type;
    int color_space;
    int transfer_func;
} PYPlaybackStats;

PYPlaybackStats py_player_get_playback_stats(PYPlayer* p);

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
uint32_t    py_player_frame_get_max_luminance(void* frame); // in 0.0001 cd/m2 units
uint16_t    py_player_frame_get_max_cll(void* frame);       // MaxCLL in cd/m2
int         py_player_frame_get_color_space(void* frame);
int         py_player_frame_get_color_trc(void* frame);
int64_t     py_player_frame_get_pts(void* frame);          // PTS in microseconds
int         py_player_frame_get_sar_num(void* frame);
int         py_player_frame_get_sar_den(void* frame);
int         py_player_frame_get_color_primaries(void* frame);
int         py_player_frame_get_color_range(void* frame);  // 0=unspecified, 1=limited, 2=full
bool        py_player_frame_is_hardware(void* frame);

// ---- HDR10+ per-frame dynamic metadata ----
bool        py_player_frame_has_hdr10plus(void* frame);
float       py_player_frame_hdr10plus_target_max_lum(void* frame);
float       py_player_frame_hdr10plus_knee_x(void* frame);
float       py_player_frame_hdr10plus_knee_y(void* frame);
int         py_player_frame_hdr10plus_num_anchors(void* frame);
// Fills up to max_count floats into anchors[], returns actual count
int         py_player_frame_hdr10plus_anchors(void* frame, float* anchors, int max_count);
void        py_player_frame_hdr10plus_maxscl(void* frame, float* rgb3);

// ---- Dolby Vision per-frame RPU metadata ----
typedef struct {
    int num_pivots;
    float pivots[9];
    int poly_order[8];
    float poly_coef[8][3];
} PYDoviCurve;

typedef struct {
    PYDoviCurve curves[3];  // Y, Cb, Cr
    float min_pq, max_pq, avg_pq;
    float source_max_pq, source_min_pq;
    float trim_slope, trim_offset, trim_power;
    float trim_chroma_weight, trim_saturation_gain;
} PYDoviMetadata;

bool        py_player_frame_has_dovi(void* frame);
bool        py_player_frame_get_dovi(void* frame, PYDoviMetadata* out);

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

// ---- Library folder management ----
int         py_library_get_folder_count(PYLibrary* lib);
const char* py_library_get_folder(PYLibrary* lib, int index);
int         py_library_remove_folder(PYLibrary* lib, int index);

#ifdef __cplusplus
}
#endif
