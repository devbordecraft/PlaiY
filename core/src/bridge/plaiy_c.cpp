#include "plaiy_c.h"
#include "plaiy/logger.h"
#include "plaiy/player_engine.h"
#include "plaiy/media_library.h"
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

// ---- Dolby Vision per-frame RPU metadata ----

bool py_player_frame_has_dovi(void* frame) {
    if (!frame) return false;
    return static_cast<py::VideoFrame*>(frame)->dovi.present;
}

bool py_player_frame_get_dovi(void* frame, PYDoviMetadata* out) {
    if (!frame || !out) return false;
    auto* vf = static_cast<py::VideoFrame*>(frame);
    if (!vf->dovi.present) return false;

    for (int c = 0; c < 3; c++) {
        const auto& src = vf->dovi.curves[c];
        out->curves[c].num_pivots = src.num_pivots;
        for (int i = 0; i < 9; i++) out->curves[c].pivots[i] = src.pivots[i];
        for (int i = 0; i < 8; i++) {
            out->curves[c].poly_order[i] = src.poly_order[i];
            for (int j = 0; j < 3; j++) out->curves[c].poly_coef[i][j] = src.poly_coef[i][j];
        }
    }
    out->min_pq = vf->dovi.min_pq;
    out->max_pq = vf->dovi.max_pq;
    out->avg_pq = vf->dovi.avg_pq;
    out->source_max_pq = vf->dovi.source_max_pq;
    out->source_min_pq = vf->dovi.source_min_pq;
    out->trim_slope = vf->dovi.trim_slope;
    out->trim_offset = vf->dovi.trim_offset;
    out->trim_power = vf->dovi.trim_power;
    out->trim_chroma_weight = vf->dovi.trim_chroma_weight;
    out->trim_saturation_gain = vf->dovi.trim_saturation_gain;
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
