#include "plaiy_c.h"
#include "plaiy/logger.h"
#include "plaiy/player_engine.h"
#include "plaiy/media_library.h"
#include "plaiy/source_manager.h"
#include "library/thumbnail_generator.h"
#include "library/seek_thumbnail_generator.h"

#include <nlohmann/json.hpp>
#include <string>
#include <mutex>

using json = nlohmann::json;

// ---- Player wrapper ----

struct PYPlayer {
    py::PlayerEngine engine;
    std::string media_info_json;
    std::string last_error_msg;
    py::SeekThumbnailGenerator seek_thumbs;
    std::string video_path;
    PYDeviceChangeCallback device_cb = nullptr;
    void* device_ud = nullptr;
    PYStateChangeCallback state_cb = nullptr;
    void* state_ud = nullptr;
};

PYPlayer* py_player_create(void) {
    return new PYPlayer();
}

void py_player_destroy(PYPlayer* p) {
    if (p) {
        p->engine.stop();
        delete p;
    }
}

void py_player_set_hw_decode_pref(PYPlayer* p, int pref) {
    if (!p) return;
    p->engine.set_hw_decode_preference(static_cast<py::HWDecodePreference>(pref));
}

void py_player_set_subtitle_font_scale(PYPlayer* p, double scale) {
    if (!p) return;
    p->engine.set_subtitle_font_scale(scale);
}

// ---- Audio filters ----

void py_player_set_eq_enabled(PYPlayer* p, bool enabled) { if (p) p->engine.set_eq_enabled(enabled); }
bool py_player_is_eq_enabled(PYPlayer* p) { return p ? p->engine.is_eq_enabled() : false; }
void py_player_set_eq_band(PYPlayer* p, int band, float gain_db) { if (p) p->engine.set_eq_band(band, gain_db); }
float py_player_get_eq_band(PYPlayer* p, int band) { return p ? p->engine.eq_band(band) : 0.0f; }
void py_player_set_eq_preset(PYPlayer* p, int preset) { if (p) p->engine.set_eq_preset(preset); }
int py_player_get_eq_preset(PYPlayer* p) { return p ? p->engine.eq_preset() : 0; }

void py_player_set_compressor_enabled(PYPlayer* p, bool enabled) { if (p) p->engine.set_compressor_enabled(enabled); }
bool py_player_is_compressor_enabled(PYPlayer* p) { return p ? p->engine.is_compressor_enabled() : false; }
void py_player_set_compressor_threshold(PYPlayer* p, float db) { if (p) p->engine.set_compressor_threshold(db); }
void py_player_set_compressor_ratio(PYPlayer* p, float ratio) { if (p) p->engine.set_compressor_ratio(ratio); }
void py_player_set_compressor_attack(PYPlayer* p, float ms) { if (p) p->engine.set_compressor_attack(ms); }
void py_player_set_compressor_release(PYPlayer* p, float ms) { if (p) p->engine.set_compressor_release(ms); }
void py_player_set_compressor_makeup(PYPlayer* p, float db) { if (p) p->engine.set_compressor_makeup(db); }

void py_player_set_dialogue_boost_enabled(PYPlayer* p, bool enabled) { if (p) p->engine.set_dialogue_boost_enabled(enabled); }
bool py_player_is_dialogue_boost_enabled(PYPlayer* p) { return p ? p->engine.is_dialogue_boost_enabled() : false; }
void py_player_set_dialogue_boost_amount(PYPlayer* p, float amount) { if (p) p->engine.set_dialogue_boost_amount(amount); }
float py_player_get_dialogue_boost_amount(PYPlayer* p) { return p ? p->engine.dialogue_boost_amount() : 0.0f; }

// ---- Video filters (GPU) ----

void py_player_set_brightness(PYPlayer* p, float value) { if (p) p->engine.set_brightness(value); }
float py_player_get_brightness(PYPlayer* p) { return p ? p->engine.brightness() : 0.0f; }
void py_player_set_contrast(PYPlayer* p, float value) { if (p) p->engine.set_contrast(value); }
float py_player_get_contrast(PYPlayer* p) { return p ? p->engine.contrast() : 1.0f; }
void py_player_set_saturation(PYPlayer* p, float value) { if (p) p->engine.set_saturation(value); }
float py_player_get_saturation(PYPlayer* p) { return p ? p->engine.saturation() : 1.0f; }
void py_player_set_sharpness(PYPlayer* p, float value) { if (p) p->engine.set_sharpness(value); }
float py_player_get_sharpness(PYPlayer* p) { return p ? p->engine.sharpness() : 0.0f; }

void py_player_set_deband_enabled(PYPlayer* p, bool enabled) { if (p) p->engine.set_deband_enabled(enabled); }
bool py_player_is_deband_enabled(PYPlayer* p) { return p ? p->engine.is_deband_enabled() : false; }
void py_player_set_lanczos_upscaling(PYPlayer* p, bool enabled) { if (p) p->engine.set_lanczos_upscaling(enabled); }
bool py_player_is_lanczos_upscaling(PYPlayer* p) { return p ? p->engine.lanczos_upscaling() : false; }
void py_player_set_film_grain_enabled(PYPlayer* p, bool enabled) { if (p) p->engine.set_film_grain_enabled(enabled); }
bool py_player_is_film_grain_enabled(PYPlayer* p) { return p ? p->engine.film_grain_enabled() : true; }
void py_player_reset_video_adjustments(PYPlayer* p) { if (p) p->engine.reset_video_adjustments(); }

// ---- Video filters (CPU: deinterlace) ----

void py_player_set_deinterlace_enabled(PYPlayer* p, bool enabled) { if (p) p->engine.set_deinterlace_enabled(enabled); }
bool py_player_is_deinterlace_enabled(PYPlayer* p) { return p ? p->engine.is_deinterlace_enabled() : false; }
void py_player_set_deinterlace_mode(PYPlayer* p, int mode) { if (p) p->engine.set_deinterlace_mode(mode); }
int py_player_get_deinterlace_mode(PYPlayer* p) { return p ? p->engine.deinterlace_mode() : 0; }

int py_player_open(PYPlayer* p, const char* path) {
    if (!p || !path) return PY_ERROR_INVALID_ARG;

    py::Error err = p->engine.open_file(path);
    if (err) return PY_ERROR_FILE_NOT_FOUND;
    p->video_path = path;
    return PY_OK;
}

void py_player_play(PYPlayer* p)  { if (p) p->engine.play(); }
void py_player_pause(PYPlayer* p) { if (p) p->engine.pause(); }
void py_player_stop(PYPlayer* p)  { if (p) p->engine.stop(); }

void py_player_seek(PYPlayer* p, int64_t timestamp_us) {
    if (p) p->engine.seek(timestamp_us);
}

int py_player_get_state(PYPlayer* p) {
    if (!p) return PY_STATE_IDLE;
    return static_cast<int>(p->engine.state());
}

int64_t py_player_get_position(PYPlayer* p) {
    if (!p) return 0;
    return p->engine.current_position_us();
}

int64_t py_player_get_duration(PYPlayer* p) {
    if (!p) return 0;
    return p->engine.duration_us();
}

int py_player_get_audio_track_count(PYPlayer* p) {
    if (!p) return 0;
    return p->engine.audio_track_count();
}

int py_player_get_subtitle_track_count(PYPlayer* p) {
    if (!p) return 0;
    return p->engine.subtitle_track_count();
}

void py_player_select_audio_track(PYPlayer* p, int index) {
    if (p) p->engine.select_audio_track(index);
}

void py_player_select_subtitle_track(PYPlayer* p, int index) {
    if (p) p->engine.select_subtitle_track(index);
}

int py_player_get_active_audio_stream(PYPlayer* p) {
    if (!p) return -1;
    return p->engine.active_audio_stream();
}

int py_player_get_active_subtitle_stream(PYPlayer* p) {
    if (!p) return -1;
    return p->engine.active_subtitle_stream();
}

void py_player_set_audio_passthrough(PYPlayer* p, bool enabled) {
    if (p) p->engine.set_audio_passthrough(enabled);
}

bool py_player_is_passthrough_active(PYPlayer* p) {
    if (!p) return false;
    return p->engine.is_passthrough_active();
}

PYPassthroughCapabilities py_player_query_passthrough_support(PYPlayer* p) {
    PYPassthroughCapabilities out = {};
    if (!p) return out;
    auto caps = p->engine.query_passthrough_support();
    out.ac3 = caps.ac3;
    out.eac3 = caps.eac3;
    out.dts = caps.dts;
    out.dts_hd_ma = caps.dts_hd_ma;
    out.truehd = caps.truehd;
    return out;
}

void py_player_set_device_change_callback(PYPlayer* p, PYDeviceChangeCallback cb, void* userdata) {
    if (!p) return;
    p->device_cb = cb;
    p->device_ud = userdata;

    if (cb) {
        p->engine.set_device_change_callback([p]{
            if (p->device_cb) p->device_cb(p->device_ud);
        });
    } else {
        p->engine.set_device_change_callback(nullptr);
    }
}

void py_player_set_state_callback(PYPlayer* p, PYStateChangeCallback cb, void* userdata) {
    if (!p) return;
    p->state_cb = cb;
    p->state_ud = userdata;

    if (cb) {
        p->engine.set_state_callback([p](py::PlaybackState s){
            if (p->state_cb) p->state_cb(static_cast<int>(s), p->state_ud);
        });
    } else {
        p->engine.set_state_callback(nullptr);
    }
}

void py_player_set_spatial_audio_mode(PYPlayer* p, int mode) {
    if (p) p->engine.set_spatial_audio_mode(mode);
}

int py_player_get_spatial_audio_mode(PYPlayer* p) {
    if (!p) return 0;
    return p->engine.spatial_audio_mode();
}

bool py_player_is_spatial_active(PYPlayer* p) {
    if (!p) return false;
    return p->engine.is_spatial_active();
}

void py_player_set_head_tracking(PYPlayer* p, bool enabled) {
    if (p) p->engine.set_head_tracking_enabled(enabled);
}

bool py_player_is_head_tracking(PYPlayer* p) {
    if (!p) return false;
    return p->engine.is_head_tracking_enabled();
}

void py_player_set_muted(PYPlayer* p, bool muted) {
    if (p) p->engine.set_muted(muted);
}

bool py_player_is_muted(PYPlayer* p) {
    if (!p) return false;
    return p->engine.is_muted();
}

void py_player_set_volume(PYPlayer* p, float volume) {
    if (p) p->engine.set_volume(volume);
}

float py_player_get_volume(PYPlayer* p) {
    if (!p) return 1.0f;
    return p->engine.volume();
}

void py_player_set_playback_speed(PYPlayer* p, double speed) {
    if (p) p->engine.set_playback_speed(speed);
}

double py_player_get_playback_speed(PYPlayer* p) {
    if (!p) return 1.0;
    return p->engine.playback_speed();
}

PYPlaybackStats py_player_get_playback_stats(PYPlayer* p) {
    static_assert(sizeof(PYPlaybackStats) == sizeof(py::PlaybackStats),
                  "PYPlaybackStats and py::PlaybackStats size mismatch — update bridge");
    PYPlaybackStats out = {};
    if (!p) return out;
    py::PlaybackStats s = p->engine.get_playback_stats();
    out.video_width = s.video_width;
    out.video_height = s.video_height;
    out.video_codec_id = s.video_codec_id;
    memcpy(out.video_codec_name, s.video_codec_name, sizeof(out.video_codec_name));
    out.hardware_decode = s.hardware_decode;
    out.video_fps = s.video_fps;
    out.frames_rendered = s.frames_rendered;
    out.frames_dropped = s.frames_dropped;
    out.video_queue_size = s.video_queue_size;
    out.video_packet_queue_size = s.video_packet_queue_size;
    out.audio_codec_id = s.audio_codec_id;
    memcpy(out.audio_codec_name, s.audio_codec_name, sizeof(out.audio_codec_name));
    out.audio_sample_rate = s.audio_sample_rate;
    out.audio_channels = s.audio_channels;
    out.audio_output_channels = s.audio_output_channels;
    out.audio_passthrough = s.audio_passthrough;
    out.audio_codec_profile = s.audio_codec_profile;
    out.audio_atmos = s.audio_atmos;
    out.audio_dts_hd = s.audio_dts_hd;
    out.audio_spatial = s.audio_spatial;
    out.audio_head_tracking = s.audio_head_tracking;
    out.audio_packet_queue_size = s.audio_packet_queue_size;
    out.audio_ring_fill_pct = s.audio_ring_fill_pct;
    out.audio_pts_us = s.audio_pts_us;
    out.video_pts_us = s.video_pts_us;
    out.av_drift_us = s.av_drift_us;
    out.playback_speed = s.playback_speed;
    memcpy(out.container_format, s.container_format, sizeof(out.container_format));
    out.bitrate = s.bitrate;
    out.hdr_type = s.hdr_type;
    out.color_space = s.color_space;
    out.transfer_func = s.transfer_func;
    out.dv_profile = s.dv_profile;
    out.dv_level = s.dv_level;
    out.dv_bl_compatibility_id = s.dv_bl_compatibility_id;
    out.dv_asbdl_active = s.dv_asbdl_active;
    out.dv_has_reshaping = s.dv_has_reshaping;
    out.dv_has_l1 = s.dv_has_l1;
    out.dv_has_l2 = s.dv_has_l2;
    out.dv_l1_min_pq = s.dv_l1_min_pq;
    out.dv_l1_max_pq = s.dv_l1_max_pq;
    out.dv_l1_avg_pq = s.dv_l1_avg_pq;
    return out;
}

const char* py_player_get_media_info_json(PYPlayer* p) {
    if (!p) return "{}";

    const py::MediaInfo& info = p->engine.media_info();
    json j;
    j["file_path"] = info.file_path;
    j["container_format"] = info.container_format;
    j["duration_us"] = info.duration_us;
    j["bit_rate"] = info.bit_rate;

    json tracks = json::array();
    for (const auto& t : info.tracks) {
        json tj;
        tj["stream_index"] = t.stream_index;
        tj["type"] = static_cast<int>(t.type);
        tj["codec_name"] = t.codec_name;
        tj["language"] = t.language;
        tj["title"] = t.title;
        tj["is_default"] = t.is_default;

        if (t.type == py::MediaType::Video) {
            tj["width"] = t.width;
            tj["height"] = t.height;
            tj["frame_rate"] = t.frame_rate;
            tj["hdr_type"] = static_cast<int>(t.hdr_metadata.type);
        } else if (t.type == py::MediaType::Audio) {
            tj["sample_rate"] = t.sample_rate;
            tj["channels"] = t.channels;
            tj["codec_id"] = t.codec_id;
            tj["codec_profile"] = t.codec_profile;
            tj["channel_layout"] = t.channel_layout;
            tj["bits_per_sample"] = t.bits_per_sample;
        } else if (t.type == py::MediaType::Subtitle) {
            tj["subtitle_format"] = static_cast<int>(t.subtitle_format);
        }

        tracks.push_back(tj);
    }
    j["tracks"] = tracks;

    p->media_info_json = j.dump();
    return p->media_info_json.c_str();
}

// ---- Dolby Vision output ----

bool py_player_is_dolby_vision(PYPlayer* p) {
    if (!p) return false;
    return p->engine.is_dolby_vision();
}

void py_player_set_dv_display_layer(PYPlayer* p, void* layer) {
    if (!p) return;
    p->engine.set_dv_display_layer(layer);
}

// ---- Video frame ----

void* py_player_acquire_video_frame(PYPlayer* p, int64_t target_pts_us) {
    if (!p) return nullptr;
    return p->engine.acquire_video_frame(target_pts_us);
}

void py_player_release_video_frame(PYPlayer* p, void* frame) {
    if (!p) return;
    p->engine.release_video_frame(static_cast<py::VideoFrame*>(frame));
}

void* py_player_frame_get_pixel_buffer(void* frame) {
    if (!frame) return nullptr;
    auto* vf = static_cast<py::VideoFrame*>(frame);
    return vf->native_buffer;
}

int py_player_frame_get_width(void* frame) {
    if (!frame) return 0;
    return static_cast<py::VideoFrame*>(frame)->width;
}

int py_player_frame_get_height(void* frame) {
    if (!frame) return 0;
    return static_cast<py::VideoFrame*>(frame)->height;
}

int py_player_frame_get_hdr_type(void* frame) {
    if (!frame) return PY_HDR_SDR;
    return static_cast<int>(static_cast<py::VideoFrame*>(frame)->hdr_metadata.type);
}

uint32_t py_player_frame_get_max_luminance(void* frame) {
    if (!frame) return 0;
    return static_cast<py::VideoFrame*>(frame)->hdr_metadata.max_luminance;
}

uint16_t py_player_frame_get_max_cll(void* frame) {
    if (!frame) return 0;
    return static_cast<py::VideoFrame*>(frame)->hdr_metadata.max_content_light_level;
}

uint16_t py_player_frame_get_max_fall(void* frame) {
    if (!frame) return 0;
    return static_cast<py::VideoFrame*>(frame)->hdr_metadata.max_frame_average_light_level;
}

int py_player_frame_get_color_space(void* frame) {
    if (!frame) return 0;
    return static_cast<py::VideoFrame*>(frame)->color_space;
}

int py_player_frame_get_color_trc(void* frame) {
    if (!frame) return 0;
    return static_cast<py::VideoFrame*>(frame)->color_trc;
}

int64_t py_player_frame_get_pts(void* frame) {
    if (!frame) return 0;
    return static_cast<py::VideoFrame*>(frame)->pts_us;
}

int py_player_frame_get_sar_num(void* frame) {
    if (!frame) return 1;
    int v = static_cast<py::VideoFrame*>(frame)->sar_num;
    return v > 0 ? v : 1;
}

int py_player_frame_get_sar_den(void* frame) {
    if (!frame) return 1;
    int v = static_cast<py::VideoFrame*>(frame)->sar_den;
    return v > 0 ? v : 1;
}

int py_player_frame_get_color_primaries(void* frame) {
    if (!frame) return 0;
    return static_cast<py::VideoFrame*>(frame)->color_primaries;
}

int py_player_frame_get_color_range(void* frame) {
    if (!frame) return 0;
    return static_cast<py::VideoFrame*>(frame)->color_range;
}

int py_player_frame_get_chroma_format(void* frame) {
    if (!frame) return 0;
    return static_cast<int>(static_cast<py::VideoFrame*>(frame)->chroma_format);
}

bool py_player_frame_is_hardware(void* frame) {
    if (!frame) return false;
    return static_cast<py::VideoFrame*>(frame)->hardware_frame;
}

// ---- HDR10+ per-frame dynamic metadata ----

bool py_player_frame_has_hdr10plus(void* frame) {
    if (!frame) return false;
    return static_cast<py::VideoFrame*>(frame)->hdr10plus.present;
}

float py_player_frame_hdr10plus_target_max_lum(void* frame) {
    if (!frame) return 0.0f;
    return static_cast<py::VideoFrame*>(frame)->hdr10plus.targeted_max_luminance;
}

float py_player_frame_hdr10plus_knee_x(void* frame) {
    if (!frame) return 0.0f;
    return static_cast<py::VideoFrame*>(frame)->hdr10plus.knee_point_x;
}

float py_player_frame_hdr10plus_knee_y(void* frame) {
    if (!frame) return 0.0f;
    return static_cast<py::VideoFrame*>(frame)->hdr10plus.knee_point_y;
}

int py_player_frame_hdr10plus_num_anchors(void* frame) {
    if (!frame) return 0;
    return static_cast<py::VideoFrame*>(frame)->hdr10plus.num_bezier_anchors;
}

int py_player_frame_hdr10plus_anchors(void* frame, float* anchors, int max_count) {
    if (!frame || !anchors) return 0;
    auto* vf = static_cast<py::VideoFrame*>(frame);
    int n = vf->hdr10plus.num_bezier_anchors;
    if (n > max_count) n = max_count;
    for (int i = 0; i < n; i++) {
        anchors[i] = vf->hdr10plus.bezier_anchors[i];
    }
    return n;
}

void py_player_frame_hdr10plus_maxscl(void* frame, float* rgb3) {
    if (!frame || !rgb3) return;
    auto* vf = static_cast<py::VideoFrame*>(frame);
    rgb3[0] = vf->hdr10plus.maxscl[0];
    rgb3[1] = vf->hdr10plus.maxscl[1];
    rgb3[2] = vf->hdr10plus.maxscl[2];
}

// ---- Dolby Vision per-frame color metadata ----

bool py_player_frame_has_dovi_color(void* frame) {
    if (!frame) return false;
    return static_cast<py::VideoFrame*>(frame)->dovi_color.present;
}

bool py_player_frame_dovi_ycc_to_rgb(void* frame, float* matrix9, float* offset3) {
    if (!frame || !matrix9 || !offset3) return false;
    auto* vf = static_cast<py::VideoFrame*>(frame);
    if (!vf->dovi_color.present) return false;
    for (int i = 0; i < 9; i++) matrix9[i] = vf->dovi_color.ycc_to_rgb_matrix[i];
    for (int i = 0; i < 3; i++) offset3[i] = vf->dovi_color.ycc_to_rgb_offset[i];
    return true;
}

bool py_player_frame_dovi_rgb_to_lms(void* frame, float* matrix9) {
    if (!frame || !matrix9) return false;
    auto* vf = static_cast<py::VideoFrame*>(frame);
    if (!vf->dovi_color.present) return false;
    for (int i = 0; i < 9; i++) matrix9[i] = vf->dovi_color.rgb_to_lms_matrix[i];
    return true;
}

bool py_player_frame_dovi_lms_to_rgb(void* frame, float* matrix9) {
    if (!frame || !matrix9) return false;
    auto* vf = static_cast<py::VideoFrame*>(frame);
    if (!vf->dovi_color.present) return false;
    for (int i = 0; i < 9; i++) matrix9[i] = vf->dovi_color.lms_to_rgb_matrix[i];
    return true;
}

bool py_player_frame_dovi_l1(void* frame, uint16_t* min_pq, uint16_t* max_pq, uint16_t* avg_pq) {
    if (!frame || !min_pq || !max_pq || !avg_pq) return false;
    auto* vf = static_cast<py::VideoFrame*>(frame);
    if (!vf->dovi_color.has_l1) return false;
    *min_pq = vf->dovi_color.l1_min_pq;
    *max_pq = vf->dovi_color.l1_max_pq;
    *avg_pq = vf->dovi_color.l1_avg_pq;
    return true;
}

bool py_player_frame_dovi_l2(void* frame, uint16_t* slope, uint16_t* offset,
                              uint16_t* power, uint16_t* chroma_weight,
                              uint16_t* saturation_gain, int16_t* ms_weight) {
    if (!frame || !slope || !offset || !power || !chroma_weight ||
        !saturation_gain || !ms_weight) return false;
    auto* vf = static_cast<py::VideoFrame*>(frame);
    if (!vf->dovi_color.has_l2) return false;
    *slope = vf->dovi_color.l2_trim_slope;
    *offset = vf->dovi_color.l2_trim_offset;
    *power = vf->dovi_color.l2_trim_power;
    *chroma_weight = vf->dovi_color.l2_trim_chroma_weight;
    *saturation_gain = vf->dovi_color.l2_trim_saturation_gain;
    *ms_weight = vf->dovi_color.l2_ms_weight;
    return true;
}

bool py_player_frame_dovi_l5(void* frame, uint16_t* left, uint16_t* right,
                              uint16_t* top, uint16_t* bottom) {
    if (!frame || !left || !right || !top || !bottom) return false;
    auto* vf = static_cast<py::VideoFrame*>(frame);
    if (!vf->dovi_color.has_l5) return false;
    *left = vf->dovi_color.l5_left_offset;
    *right = vf->dovi_color.l5_right_offset;
    *top = vf->dovi_color.l5_top_offset;
    *bottom = vf->dovi_color.l5_bottom_offset;
    return true;
}

bool py_player_frame_dovi_l6(void* frame, uint16_t* max_lum, uint16_t* min_lum,
                              uint16_t* max_cll, uint16_t* max_fall) {
    if (!frame || !max_lum || !min_lum || !max_cll || !max_fall) return false;
    auto* vf = static_cast<py::VideoFrame*>(frame);
    if (!vf->dovi_color.has_l6) return false;
    *max_lum = vf->dovi_color.l6_max_luminance;
    *min_lum = vf->dovi_color.l6_min_luminance;
    *max_cll = vf->dovi_color.l6_max_cll;
    *max_fall = vf->dovi_color.l6_max_fall;
    return true;
}

uint32_t py_player_frame_get_min_luminance(void* frame) {
    if (!frame) return 0;
    return static_cast<py::VideoFrame*>(frame)->hdr_metadata.min_luminance;
}

bool py_player_frame_dovi_has_reshaping(void* frame) {
    if (!frame) return false;
    return static_cast<py::VideoFrame*>(frame)->dovi_color.has_reshaping;
}

bool py_player_frame_dovi_reshape_lut(void* frame, int component, float* lut1024) {
    if (!frame || !lut1024 || component < 0 || component > 2) return false;
    auto* vf = static_cast<py::VideoFrame*>(frame);
    if (!vf->dovi_color.has_reshaping) return false;
    for (int i = 0; i < 1024; i++) lut1024[i] = vf->dovi_color.reshape_lut[component][i];
    return true;
}

// ---- Subtitle ----

PYSubtitleFrame* py_player_get_subtitle(PYPlayer* p, int64_t timestamp_us) {
    if (!p) return nullptr;

    py::SubtitleFrame sf = p->engine.get_subtitle_frame(timestamp_us);
    if (sf.text.empty() && sf.regions.empty()) return nullptr;

    auto* out = new PYSubtitleFrame();
    memset(out, 0, sizeof(*out));
    out->start_us = sf.start_us;
    out->end_us = sf.end_us;

    if (sf.is_text) {
        // Copy text (caller must not free the text; it's owned by the struct)
        char* text_copy = new char[sf.text.size() + 1];
        memcpy(text_copy, sf.text.c_str(), sf.text.size() + 1);
        out->text = text_copy;
    } else if (!sf.regions.empty()) {
        // Use the first region for simplicity
        const auto& r = sf.regions[0];
        uint8_t* data_copy = new uint8_t[r.rgba_data.size()];
        memcpy(data_copy, r.rgba_data.data(), r.rgba_data.size());
        out->rgba_data = data_copy;
        out->width = r.width;
        out->height = r.height;
        out->x = r.x;
        out->y = r.y;
        out->region_count = static_cast<int>(sf.regions.size());
    }

    return out;
}

void py_subtitle_free(PYSubtitleFrame* sf) {
    if (!sf) return;
    delete[] sf->text;
    delete[] sf->rgba_data;
    delete sf;
}

// ---- Logging ----

void py_log_set_level(int level) {
    py::Logger::instance().set_level(static_cast<py::LogLevel>(level));
}

int py_log_get_level(void) {
    return static_cast<int>(py::Logger::instance().level());
}

static std::mutex g_log_mutex;
static PYLogCallback g_log_cb = nullptr;
static void* g_log_ud = nullptr;

void py_log_set_callback(PYLogCallback cb, void* userdata) {
    {
        std::lock_guard<std::mutex> lock(g_log_mutex);
        g_log_cb = cb;
        g_log_ud = userdata;
    }

    if (cb) {
        py::Logger::instance().set_callback(
            [](py::LogLevel level, const char* tag, const char* message) {
                std::lock_guard<std::mutex> lock(g_log_mutex);
                if (g_log_cb) {
                    g_log_cb(static_cast<int>(level), tag, message, g_log_ud);
                }
            });
    } else {
        py::Logger::instance().set_callback(nullptr);
    }
}

// ---- Thumbnails ----

int py_thumbnail_generate(const char* video_path, const char* output_path,
                          int max_width, int max_height) {
    if (!video_path || !output_path) return PY_ERROR_INVALID_ARG;
    return py::ThumbnailGenerator::generate(video_path, output_path, max_width, max_height)
        ? PY_OK : PY_ERROR_DECODER;
}

// ---- Seek preview thumbnails ----

static std::string seek_thumb_cache_dir(const std::string& video_path) {
    // Simple hash of path for cache directory name
    std::hash<std::string> hasher;
    size_t h = hasher(video_path);
    char hex[32];
    snprintf(hex, sizeof(hex), "%016zx", h);

    const char* home = getenv("HOME");
    std::string dir = std::string(home ? home : "/tmp") +
                      "/Library/Caches/PlaiY/seek_thumbs/" + hex;
    return dir;
}

void py_player_start_seek_thumbnails(PYPlayer* p, int interval_seconds) {
    if (!p || p->video_path.empty()) return;
    std::string cache_dir = seek_thumb_cache_dir(p->video_path);
    p->seek_thumbs.start(p->video_path, cache_dir, interval_seconds);
}

void py_player_cancel_seek_thumbnails(PYPlayer* p) {
    if (p) p->seek_thumbs.cancel();
}

int py_player_get_seek_thumbnail(PYPlayer* p, int64_t timestamp_us,
                                  const uint8_t** out_data,
                                  int* out_width, int* out_height) {
    if (!p || !out_data || !out_width || !out_height) return PY_ERROR_INVALID_ARG;

    int64_t dur = p->engine.duration_us();
    if (!p->seek_thumbs.get_thumbnail(timestamp_us, dur, out_data, out_width, out_height))
        return PY_ERROR_UNKNOWN;
    return PY_OK;
}

int py_player_get_seek_thumbnail_progress(PYPlayer* p) {
    if (!p) return 0;
    return p->seek_thumbs.progress();
}

// ---- Library ----

struct PYLibrary {
    py::MediaLibrary library;
    std::string item_json_cache;
    std::string all_items_json_cache;
    std::string folder_cache;
};

PYLibrary* py_library_create(void) {
    return new PYLibrary();
}

void py_library_destroy(PYLibrary* lib) {
    delete lib;
}

int py_library_add_folder(PYLibrary* lib, const char* path) {
    if (!lib || !path) return PY_ERROR_INVALID_ARG;
    py::Error err = lib->library.add_folder(path);
    return err ? PY_ERROR_FILE_NOT_FOUND : PY_OK;
}

int py_library_get_item_count(PYLibrary* lib) {
    if (!lib) return 0;
    return lib->library.item_count();
}

const char* py_library_get_item_json(PYLibrary* lib, int index) {
    if (!lib) return "{}";
    const py::MediaItem* item = lib->library.item_at(index);
    if (!item) return "{}";

    json j;
    j["file_path"] = item->file_path;
    j["title"] = item->title;
    j["container_format"] = item->container_format;
    j["duration_us"] = item->duration_us;
    j["video_width"] = item->video_width;
    j["video_height"] = item->video_height;
    j["video_codec"] = item->video_codec;
    j["audio_codec"] = item->audio_codec;
    j["audio_channels"] = item->audio_channels;
    j["hdr_type"] = static_cast<int>(item->hdr_type);
    j["file_size"] = item->file_size;
    j["audio_track_count"] = item->audio_track_count;
    j["subtitle_track_count"] = item->subtitle_track_count;

    lib->item_json_cache = j.dump();
    return lib->item_json_cache.c_str();
}

const char* py_library_get_all_items_json(PYLibrary* lib) {
    if (!lib) return "[]";

    json arr = json::array();
    for (int i = 0; i < lib->library.item_count(); i++) {
        const py::MediaItem* item = lib->library.item_at(i);
        if (!item) continue;

        json j;
        j["file_path"] = item->file_path;
        j["title"] = item->title;
        j["duration_us"] = item->duration_us;
        j["video_width"] = item->video_width;
        j["video_height"] = item->video_height;
        j["video_codec"] = item->video_codec;
        j["audio_codec"] = item->audio_codec;
        j["hdr_type"] = static_cast<int>(item->hdr_type);
        j["file_size"] = item->file_size;
        arr.push_back(j);
    }

    lib->all_items_json_cache = arr.dump();
    return lib->all_items_json_cache.c_str();
}

int py_library_get_folder_count(PYLibrary* lib) {
    if (!lib) return 0;
    return lib->library.folder_count();
}

const char* py_library_get_folder(PYLibrary* lib, int index) {
    if (!lib) return "";
    lib->folder_cache = lib->library.folder_at(index);
    return lib->folder_cache.c_str();
}

int py_library_remove_folder(PYLibrary* lib, int index) {
    if (!lib) return PY_ERROR_INVALID_ARG;
    lib->library.remove_folder(index);
    return PY_OK;
}

// ---- Source Manager ----

struct PYSourceManager {
    py::SourceManager manager;
    std::string cached_configs_json;
    std::string cached_config_json;
    std::string cached_listing_json;
    std::string cached_playable_path;
};

PYSourceManager* py_source_manager_create(void) {
    return new PYSourceManager();
}

void py_source_manager_destroy(PYSourceManager* sm) {
    delete sm;
}

int py_source_add(PYSourceManager* sm, const char* config_json) {
    if (!sm || !config_json) return PY_ERROR_INVALID_ARG;

    try {
        auto j = json::parse(config_json);
        py::SourceConfig cfg;
        cfg.source_id = j.value("source_id", "");
        cfg.display_name = j.value("display_name", "");
        cfg.base_uri = j.value("base_uri", "");
        cfg.username = j.value("username", "");

        std::string type_str = j.value("type", "local");
        if (type_str == "smb") cfg.type = py::MediaSourceType::SMB;
        else if (type_str == "nfs") cfg.type = py::MediaSourceType::NFS;
        else if (type_str == "http") cfg.type = py::MediaSourceType::HTTP;
        else if (type_str == "plex") cfg.type = py::MediaSourceType::Plex;
        else cfg.type = py::MediaSourceType::Local;

        py::Error err = sm->manager.add_source(cfg);
        if (err) return PY_ERROR_INVALID_ARG;
        return PY_OK;
    } catch (...) {
        return PY_ERROR_INVALID_ARG;
    }
}

int py_source_remove(PYSourceManager* sm, const char* source_id) {
    if (!sm || !source_id) return PY_ERROR_INVALID_ARG;
    sm->manager.remove_source(source_id);
    return PY_OK;
}

int py_source_count(PYSourceManager* sm) {
    if (!sm) return 0;
    return sm->manager.source_count();
}

const char* py_source_get_config_json(PYSourceManager* sm, int index) {
    if (!sm) return "{}";
    auto* src = sm->manager.source_at(index);
    if (!src) return "{}";

    const auto& cfg = src->config();
    json j;
    j["source_id"] = cfg.source_id;
    j["display_name"] = cfg.display_name;
    j["base_uri"] = cfg.base_uri;
    j["username"] = cfg.username;

    switch (cfg.type) {
        case py::MediaSourceType::SMB:  j["type"] = "smb"; break;
        case py::MediaSourceType::NFS:  j["type"] = "nfs"; break;
        case py::MediaSourceType::HTTP: j["type"] = "http"; break;
        case py::MediaSourceType::Plex: j["type"] = "plex"; break;
        default: j["type"] = "local"; break;
    }
    j["connected"] = src->is_connected();

    sm->cached_config_json = j.dump();
    return sm->cached_config_json.c_str();
}

const char* py_source_all_configs_json(PYSourceManager* sm) {
    if (!sm) return "[]";
    sm->cached_configs_json = sm->manager.configs_json();
    return sm->cached_configs_json.c_str();
}

int py_source_load_configs_json(PYSourceManager* sm, const char* json_str) {
    if (!sm || !json_str) return PY_ERROR_INVALID_ARG;
    py::Error err = sm->manager.load_configs_json(json_str);
    return err ? PY_ERROR_INVALID_ARG : PY_OK;
}

int py_source_connect(PYSourceManager* sm, const char* source_id, const char* password) {
    if (!sm || !source_id) return PY_ERROR_INVALID_ARG;

    auto* src = sm->manager.source_by_id(source_id);
    if (!src) return PY_ERROR_INVALID_ARG;

    // Inject password into config (it's not serialized)
    auto& cfg = const_cast<py::SourceConfig&>(src->config());
    if (password) cfg.password = password;

    py::Error err = src->connect();
    if (err) {
        if (err.code == py::ErrorCode::NetworkError) return PY_ERROR_NETWORK;
        return PY_ERROR_UNKNOWN;
    }
    return PY_OK;
}

void py_source_disconnect(PYSourceManager* sm, const char* source_id) {
    if (!sm || !source_id) return;
    auto* src = sm->manager.source_by_id(source_id);
    if (src) src->disconnect();
}

bool py_source_is_connected(PYSourceManager* sm, const char* source_id) {
    if (!sm || !source_id) return false;
    auto* src = sm->manager.source_by_id(source_id);
    return src && src->is_connected();
}

const char* py_source_list_directory(PYSourceManager* sm,
                                      const char* source_id,
                                      const char* relative_path) {
    if (!sm || !source_id) return "[]";

    auto* src = sm->manager.source_by_id(source_id);
    if (!src) return "[]";

    std::vector<py::SourceEntry> entries;
    py::Error err = src->list_directory(relative_path ? relative_path : "", entries);
    if (err) return "[]";

    json arr = json::array();
    for (const auto& e : entries) {
        json j;
        j["name"] = e.name;
        j["uri"] = e.uri;
        j["is_directory"] = e.is_directory;
        j["size"] = e.size;
        arr.push_back(j);
    }

    sm->cached_listing_json = arr.dump();
    return sm->cached_listing_json.c_str();
}

const char* py_source_playable_path(PYSourceManager* sm,
                                     const char* source_id,
                                     const char* entry_uri) {
    if (!sm || !source_id || !entry_uri) return "";

    auto* src = sm->manager.source_by_id(source_id);
    if (!src) return "";

    py::SourceEntry entry;
    entry.uri = entry_uri;
    sm->cached_playable_path = src->playable_path(entry);
    return sm->cached_playable_path.c_str();
}
