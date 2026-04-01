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
    PY_ERROR_NETWORK = 8,
};

// ---- Playback state ----
enum PYPlaybackState {
    PY_STATE_IDLE = 0,
    PY_STATE_OPENING = 1,
    PY_STATE_BUFFERING = 2,
    PY_STATE_READY = 3,
    PY_STATE_PLAYING = 4,
    PY_STATE_PAUSED = 5,
    PY_STATE_STOPPED = 6,
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

// ---- Remote playback buffering ----
enum PYRemoteSourceKind {
    PY_REMOTE_SOURCE_NONE = 0,
    PY_REMOTE_SOURCE_PLEX = 1,
};

enum PYRemoteBufferMode {
    PY_REMOTE_BUFFER_OFF = 0,
    PY_REMOTE_BUFFER_MEMORY = 1,
    PY_REMOTE_BUFFER_DISK = 2,
};

enum PYRemoteBufferProfile {
    PY_REMOTE_BUFFER_FAST = 0,
    PY_REMOTE_BUFFER_BALANCED = 1,
    PY_REMOTE_BUFFER_CONSERVATIVE = 2,
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
// Ownership: returned string is owned by the player and valid until the next
// bridge call on the same handle or py_player_destroy().
const char* py_player_get_last_error(PYPlayer* p);
void        py_player_play(PYPlayer* p);
void        py_player_pause(PYPlayer* p);
void        py_player_seek(PYPlayer* p, int64_t timestamp_us);
void        py_player_stop(PYPlayer* p);

// ---- Player configuration (call before py_player_open) ----
void        py_player_set_hw_decode_pref(PYPlayer* p, int pref);
void        py_player_set_subtitle_font_scale(PYPlayer* p, double scale);
void        py_player_set_remote_source_kind(PYPlayer* p, int kind);
void        py_player_set_remote_buffer_mode(PYPlayer* p, int mode);
void        py_player_set_remote_buffer_profile(PYPlayer* p, int profile);

// ---- Audio filters ----
// Equalizer (10-band)
void        py_player_set_eq_enabled(PYPlayer* p, bool enabled);
bool        py_player_is_eq_enabled(PYPlayer* p);
void        py_player_set_eq_band(PYPlayer* p, int band, float gain_db);
float       py_player_get_eq_band(PYPlayer* p, int band);
void        py_player_set_eq_preset(PYPlayer* p, int preset);
int         py_player_get_eq_preset(PYPlayer* p);
// Compressor
void        py_player_set_compressor_enabled(PYPlayer* p, bool enabled);
bool        py_player_is_compressor_enabled(PYPlayer* p);
void        py_player_set_compressor_threshold(PYPlayer* p, float db);
void        py_player_set_compressor_ratio(PYPlayer* p, float ratio);
void        py_player_set_compressor_attack(PYPlayer* p, float ms);
void        py_player_set_compressor_release(PYPlayer* p, float ms);
void        py_player_set_compressor_makeup(PYPlayer* p, float db);
// Dialogue boost
void        py_player_set_dialogue_boost_enabled(PYPlayer* p, bool enabled);
bool        py_player_is_dialogue_boost_enabled(PYPlayer* p);
void        py_player_set_dialogue_boost_amount(PYPlayer* p, float amount);
float       py_player_get_dialogue_boost_amount(PYPlayer* p);

// ---- Video filters (GPU: brightness/contrast/saturation/sharpness/deband) ----
void        py_player_set_deband_enabled(PYPlayer* p, bool enabled);
bool        py_player_is_deband_enabled(PYPlayer* p);
void        py_player_set_lanczos_upscaling(PYPlayer* p, bool enabled);
bool        py_player_is_lanczos_upscaling(PYPlayer* p);
void        py_player_set_film_grain_enabled(PYPlayer* p, bool enabled);
bool        py_player_is_film_grain_enabled(PYPlayer* p);
void        py_player_set_brightness(PYPlayer* p, float value);
float       py_player_get_brightness(PYPlayer* p);
void        py_player_set_contrast(PYPlayer* p, float value);
float       py_player_get_contrast(PYPlayer* p);
void        py_player_set_saturation(PYPlayer* p, float value);
float       py_player_get_saturation(PYPlayer* p);
void        py_player_set_sharpness(PYPlayer* p, float value);
float       py_player_get_sharpness(PYPlayer* p);
void        py_player_reset_video_adjustments(PYPlayer* p);

// ---- Video filters (CPU: deinterlace) ----
void        py_player_set_deinterlace_enabled(PYPlayer* p, bool enabled);
bool        py_player_is_deinterlace_enabled(PYPlayer* p);
void        py_player_set_deinterlace_mode(PYPlayer* p, int mode); // 0=yadif, 1=bwdif
int         py_player_get_deinterlace_mode(PYPlayer* p);

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

typedef void (*PYStateChangeCallback)(int state, void* userdata);
void        py_player_set_state_callback(PYPlayer* p, PYStateChangeCallback cb, void* userdata);

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

    // Dolby Vision (stream-level)
    uint8_t dv_profile;
    uint8_t dv_level;
    uint8_t dv_bl_compatibility_id;
    bool dv_asbdl_active;

    // DV per-frame metadata
    bool dv_has_reshaping;
    bool dv_has_l1;
    bool dv_has_l2;
    uint16_t dv_l1_min_pq;
    uint16_t dv_l1_max_pq;
    uint16_t dv_l1_avg_pq;
} PYPlaybackStats;

PYPlaybackStats py_player_get_playback_stats(PYPlayer* p);

// ---- Media info ----
// Ownership: returned string is owned by the player and valid until
// the next call to py_player_open() or py_player_destroy().
const char* py_player_get_media_info_json(PYPlayer* p);

// ---- Dolby Vision output (ASBDL-based rendering) ----
// Returns true if the currently open file uses ASBDL output (DV Profile 5/8/10).
bool        py_player_is_dolby_vision(PYPlayer* p);
// Set the AVSampleBufferDisplayLayer for DV rendering (pass as void*).
// Must be called after py_player_open() and before py_player_play().
void        py_player_set_dv_display_layer(PYPlayer* p, void* layer);

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
int         py_player_frame_get_chroma_format(void* frame); // 0=420, 1=422, 2=444
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

// ---- Dolby Vision per-frame color metadata ----
bool        py_player_frame_has_dovi_color(void* frame);
// Fills 9 floats (3x3 row-major matrix) + 3 offsets
bool        py_player_frame_dovi_ycc_to_rgb(void* frame, float* matrix9, float* offset3);
bool        py_player_frame_dovi_rgb_to_lms(void* frame, float* matrix9);
// Pre-inverted LMS-to-RGB matrix (avoids per-pixel inversion in shader)
bool        py_player_frame_dovi_lms_to_rgb(void* frame, float* matrix9);
// L1 per-scene brightness metadata (PQ domain, 12-bit)
bool        py_player_frame_dovi_l1(void* frame, uint16_t* min_pq, uint16_t* max_pq, uint16_t* avg_pq);
// L2 display trim metadata
bool        py_player_frame_dovi_l2(void* frame, uint16_t* slope, uint16_t* offset,
                                     uint16_t* power, uint16_t* chroma_weight,
                                     uint16_t* saturation_gain, int16_t* ms_weight);
// L5 active area metadata (per-frame letterbox offsets)
bool        py_player_frame_dovi_l5(void* frame, uint16_t* left, uint16_t* right,
                                     uint16_t* top, uint16_t* bottom);
// L6 RPU-level static HDR10 metadata (overrides stream-level SEI)
bool        py_player_frame_dovi_l6(void* frame, uint16_t* max_lum, uint16_t* min_lum,
                                     uint16_t* max_cll, uint16_t* max_fall);
// Mastering display minimum luminance (0.0001 cd/m2 units, from MDCV SEI)
uint32_t    py_player_frame_get_min_luminance(void* frame);
// Pre-computed reshaping LUT (1024 float entries for the given component 0=Y, 1=Cb, 2=Cr)
bool        py_player_frame_dovi_has_reshaping(void* frame);
bool        py_player_frame_dovi_reshape_lut(void* frame, int component, float* lut1024);
uint64_t    py_player_frame_dovi_reshape_fingerprint(void* frame);

// ---- Subtitle ----
typedef struct {
    const uint8_t* rgba_data;
    int width;
    int height;
    int x;
    int y;
} PYSubtitleRegion;

typedef struct {
    // For text subtitles
    const char* text;       // NULL for bitmap subs

    // For bitmap subtitles
    const PYSubtitleRegion* regions;
    int region_count;

    // Timing
    int64_t start_us;
    int64_t end_us;
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

// ---- Source Manager ----
// Manages browsable media sources (local, SMB, NFS, HTTP, Plex, etc.)
typedef struct PYSourceManager PYSourceManager;

PYSourceManager* py_source_manager_create(void);
void             py_source_manager_destroy(PYSourceManager* sm);
// Ownership: returned string is owned by the source manager and valid until
// the next bridge call on the same handle or py_source_manager_destroy().
const char*      py_source_get_last_error(PYSourceManager* sm);

// Add a source from JSON config: {"source_id","display_name","type","base_uri","username"}
int              py_source_add(PYSourceManager* sm, const char* config_json);
int              py_source_remove(PYSourceManager* sm, const char* source_id);
int              py_source_count(PYSourceManager* sm);

// Get individual source config as JSON. Returned string owned by manager.
const char*      py_source_get_config_json(PYSourceManager* sm, int index);
// Get all source configs as JSON array. Returned string owned by manager.
const char*      py_source_all_configs_json(PYSourceManager* sm);
// Load sources from JSON array (re-creates source objects).
int              py_source_load_configs_json(PYSourceManager* sm, const char* json);
// Returns whether the current runtime supports a source type string ("http", "nfs", etc.).
bool             py_source_type_supported(const char* type);

// Connect/disconnect a source. Password is passed at connect time (not serialized).
int              py_source_connect(PYSourceManager* sm, const char* source_id,
                                    const char* password);
void             py_source_disconnect(PYSourceManager* sm, const char* source_id);
bool             py_source_is_connected(PYSourceManager* sm, const char* source_id);

// Browse: returns JSON array of entries: [{"name","uri","is_directory","size"}, ...]
// Returned string owned by manager, valid until next call.
const char*      py_source_list_directory(PYSourceManager* sm,
                                           const char* source_id,
                                           const char* relative_path);

// Get playable path/URI for an entry. Returned string owned by manager.
const char*      py_source_playable_path(PYSourceManager* sm,
                                          const char* source_id,
                                          const char* entry_uri);

#ifdef __cplusplus
}
#endif
