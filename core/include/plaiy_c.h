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
// Thread safety: All player functions must be called from the same thread,
// EXCEPT py_player_acquire_video_frame / py_player_release_video_frame
// which are called from the Metal display-link (render) thread.
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

typedef struct {
    bool ac3;
    bool eac3;
    bool dts;
    bool dts_hd_ma;
    bool truehd;
} PYPassthroughCapabilities;

PYPassthroughCapabilities py_player_query_passthrough_support(PYPlayer* p);

typedef void (*PYDeviceChangeCallback)(void* userdata);
void        py_player_set_device_change_callback(PYPlayer* p, PYDeviceChangeCallback cb, void* userdata);

// ---- Spatial audio ----
// Mode: 0 = Auto (default), 1 = Off, 2 = Force Spatial
void        py_player_set_spatial_audio_mode(PYPlayer* p, int mode);
int         py_player_get_spatial_audio_mode(PYPlayer* p);
bool        py_player_is_spatial_active(PYPlayer* p);
void        py_player_set_head_tracking(PYPlayer* p, bool enabled);
bool        py_player_is_head_tracking(PYPlayer* p);

// ---- Mute ----
void        py_player_set_muted(PYPlayer* p, bool muted);
bool        py_player_is_muted(PYPlayer* p);

// ---- Volume ----
void        py_player_set_volume(PYPlayer* p, float volume);
float       py_player_get_volume(PYPlayer* p);

// ---- Playback speed ----
void        py_player_set_playback_speed(PYPlayer* p, double speed);
double      py_player_get_playback_speed(PYPlayer* p);

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
    int audio_codec_profile;
    bool audio_atmos;
    bool audio_dts_hd;
    bool audio_spatial;
    bool audio_head_tracking;
    int audio_packet_queue_size;
    int audio_ring_fill_pct;

    // Sync
    int64_t audio_pts_us;
    int64_t video_pts_us;
    int64_t av_drift_us;
    double playback_speed;

    // Container
    char container_format[32];
    int64_t bitrate;

    // HDR
    int hdr_type;
    int color_space;
    int transfer_func;

    // Dolby Vision
    uint8_t dv_profile;
    uint8_t dv_level;
    uint8_t dv_bl_compatibility_id;
    bool dv_rpu_present;
    float dv_min_pq;
    float dv_max_pq;
    float dv_avg_pq;
    float dv_source_min_pq;
    float dv_source_max_pq;
    float dv_trim_slope;
    float dv_trim_offset;
    float dv_trim_power;
    float dv_trim_chroma_weight;
    float dv_trim_saturation_gain;
} PYPlaybackStats;

PYPlaybackStats py_player_get_playback_stats(PYPlayer* p);

// ---- Media info ----
// Ownership: returned string is owned by the player and valid until
// the next call to py_player_open() or py_player_destroy().
const char* py_player_get_media_info_json(PYPlayer* p);

// ---- Video frame acquisition (called from display-link / render thread) ----
// Returns an opaque frame handle; NULL if no frame ready.
// Ownership: the caller borrows the frame. It is valid until
// py_player_release_video_frame() is called. Do NOT free it.
void*       py_player_acquire_video_frame(PYPlayer* p, int64_t target_pts_us);
void        py_player_release_video_frame(PYPlayer* p, void* frame);

// Get properties of an acquired frame (valid between acquire and release)
void*       py_player_frame_get_pixel_buffer(void* frame);   // CVPixelBufferRef (Apple)
int         py_player_frame_get_width(void* frame);
int         py_player_frame_get_height(void* frame);
int         py_player_frame_get_hdr_type(void* frame);
uint32_t    py_player_frame_get_max_luminance(void* frame); // in 0.0001 cd/m2 units
uint16_t    py_player_frame_get_max_cll(void* frame);       // MaxCLL in cd/m2
uint16_t    py_player_frame_get_max_fall(void* frame);      // MaxFALL in cd/m2
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

// Ownership: caller must call py_subtitle_free() on the returned frame.
// Returns NULL if no subtitle is active at the given timestamp.
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
// Ownership: returned strings are owned by the library. Valid until
// the next scan, add_folder, or py_library_destroy(). Do NOT free.
const char* py_library_get_item_json(PYLibrary* lib, int index);
const char* py_library_get_all_items_json(PYLibrary* lib);

// ---- Thumbnails ----
int py_thumbnail_generate(const char* video_path, const char* output_path,
                          int max_width, int max_height);

// ---- Seek preview thumbnails ----
// Start background generation of seek preview thumbnails.
// interval_seconds: one thumbnail every N seconds. Call after py_player_open().
void py_player_start_seek_thumbnails(PYPlayer* p, int interval_seconds);
void py_player_cancel_seek_thumbnails(PYPlayer* p);

// Get BGRA thumbnail data for a timestamp. Returns PY_OK if available.
// Ownership: out_data points to internal buffer, valid until next call
// to this function, py_player_stop(), or py_player_destroy().
int  py_player_get_seek_thumbnail(PYPlayer* p, int64_t timestamp_us,
                                   const uint8_t** out_data,
                                   int* out_width, int* out_height);
int  py_player_get_seek_thumbnail_progress(PYPlayer* p);

// ---- Library folder management ----
int         py_library_get_folder_count(PYLibrary* lib);
const char* py_library_get_folder(PYLibrary* lib, int index);
int         py_library_remove_folder(PYLibrary* lib, int index);

#ifdef __cplusplus
}
#endif
