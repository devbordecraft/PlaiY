#include "testplayer_c.h"
#include "testplayer/logger.h"
#include "testplayer/player_engine.h"
#include "testplayer/media_library.h"

#include <nlohmann/json.hpp>
#include <string>
#include <mutex>

using json = nlohmann::json;

// ---- Player wrapper ----

struct TPPlayer {
    tp::PlayerEngine engine;
    std::string media_info_json;
    std::string last_error_msg;

    // Callback storage
    TPStateCallback state_cb = nullptr;
    void* state_ud = nullptr;
    TPErrorCallback error_cb = nullptr;
    void* error_ud = nullptr;
};

TPPlayer* tp_player_create(void) {
    return new TPPlayer();
}

void tp_player_destroy(TPPlayer* p) {
    if (p) {
        p->engine.stop();
        delete p;
    }
}

int tp_player_open(TPPlayer* p, const char* path) {
    if (!p || !path) return TP_ERROR_INVALID_ARG;

    // Wire up callbacks before opening
    if (p->state_cb) {
        p->engine.set_state_callback([p](tp::PlaybackState s) {
            p->state_cb(static_cast<int>(s), p->state_ud);
        });
    }
    if (p->error_cb) {
        p->engine.set_error_callback([p](tp::Error err) {
            p->error_cb(static_cast<int>(err.code), err.message.c_str(), p->error_ud);
        });
    }

    tp::Error err = p->engine.open_file(path);
    if (err) return TP_ERROR_FILE_NOT_FOUND;
    return TP_OK;
}

void tp_player_play(TPPlayer* p)  { if (p) p->engine.play(); }
void tp_player_pause(TPPlayer* p) { if (p) p->engine.pause(); }
void tp_player_stop(TPPlayer* p)  { if (p) p->engine.stop(); }

void tp_player_seek(TPPlayer* p, int64_t timestamp_us) {
    if (p) p->engine.seek(timestamp_us);
}

int tp_player_get_state(TPPlayer* p) {
    if (!p) return TP_STATE_IDLE;
    return static_cast<int>(p->engine.state());
}

int64_t tp_player_get_position(TPPlayer* p) {
    if (!p) return 0;
    return p->engine.current_position_us();
}

int64_t tp_player_get_duration(TPPlayer* p) {
    if (!p) return 0;
    return p->engine.duration_us();
}

int tp_player_get_audio_track_count(TPPlayer* p) {
    if (!p) return 0;
    return p->engine.audio_track_count();
}

int tp_player_get_subtitle_track_count(TPPlayer* p) {
    if (!p) return 0;
    return p->engine.subtitle_track_count();
}

void tp_player_select_audio_track(TPPlayer* p, int index) {
    if (p) p->engine.select_audio_track(index);
}

void tp_player_select_subtitle_track(TPPlayer* p, int index) {
    if (p) p->engine.select_subtitle_track(index);
}

const char* tp_player_get_media_info_json(TPPlayer* p) {
    if (!p) return "{}";

    tp::MediaInfo info = p->engine.media_info();
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

        if (t.type == tp::MediaType::Video) {
            tj["width"] = t.width;
            tj["height"] = t.height;
            tj["frame_rate"] = t.frame_rate;
            tj["hdr_type"] = static_cast<int>(t.hdr_metadata.type);
        } else if (t.type == tp::MediaType::Audio) {
            tj["sample_rate"] = t.sample_rate;
            tj["channels"] = t.channels;
        }

        tracks.push_back(tj);
    }
    j["tracks"] = tracks;

    p->media_info_json = j.dump();
    return p->media_info_json.c_str();
}

// ---- Video frame ----

void* tp_player_acquire_video_frame(TPPlayer* p, int64_t target_pts_us) {
    if (!p) return nullptr;
    return p->engine.acquire_video_frame(target_pts_us);
}

void tp_player_release_video_frame(TPPlayer* p, void* frame) {
    if (!p) return;
    p->engine.release_video_frame(static_cast<tp::VideoFrame*>(frame));
}

void* tp_player_frame_get_pixel_buffer(void* frame) {
    if (!frame) return nullptr;
    auto* vf = static_cast<tp::VideoFrame*>(frame);
    return vf->native_buffer;
}

int tp_player_frame_get_width(void* frame) {
    if (!frame) return 0;
    return static_cast<tp::VideoFrame*>(frame)->width;
}

int tp_player_frame_get_height(void* frame) {
    if (!frame) return 0;
    return static_cast<tp::VideoFrame*>(frame)->height;
}

int tp_player_frame_get_hdr_type(void* frame) {
    if (!frame) return TP_HDR_SDR;
    return static_cast<int>(static_cast<tp::VideoFrame*>(frame)->hdr_metadata.type);
}

int tp_player_frame_get_color_space(void* frame) {
    if (!frame) return 0;
    return static_cast<tp::VideoFrame*>(frame)->color_space;
}

int tp_player_frame_get_color_trc(void* frame) {
    if (!frame) return 0;
    return static_cast<tp::VideoFrame*>(frame)->color_trc;
}

bool tp_player_frame_is_hardware(void* frame) {
    if (!frame) return false;
    return static_cast<tp::VideoFrame*>(frame)->hardware_frame;
}

// ---- Subtitle ----

TPSubtitleFrame* tp_player_get_subtitle(TPPlayer* p, int64_t timestamp_us) {
    if (!p) return nullptr;

    tp::SubtitleFrame sf = p->engine.get_subtitle_frame(timestamp_us);
    if (sf.text.empty() && sf.regions.empty()) return nullptr;

    auto* out = new TPSubtitleFrame();
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

void tp_subtitle_free(TPSubtitleFrame* sf) {
    if (!sf) return;
    delete[] sf->text;
    delete[] sf->rgba_data;
    delete sf;
}

// ---- Callbacks ----

void tp_player_set_state_callback(TPPlayer* p, TPStateCallback cb, void* userdata) {
    if (!p) return;
    p->state_cb = cb;
    p->state_ud = userdata;
}

void tp_player_set_error_callback(TPPlayer* p, TPErrorCallback cb, void* userdata) {
    if (!p) return;
    p->error_cb = cb;
    p->error_ud = userdata;
}

// ---- Logging ----

void tp_log_set_level(int level) {
    tp::Logger::instance().set_level(static_cast<tp::LogLevel>(level));
}

int tp_log_get_level(void) {
    return static_cast<int>(tp::Logger::instance().level());
}

static TPLogCallback g_log_cb = nullptr;
static void* g_log_ud = nullptr;

void tp_log_set_callback(TPLogCallback cb, void* userdata) {
    g_log_cb = cb;
    g_log_ud = userdata;

    if (cb) {
        tp::Logger::instance().set_callback(
            [](tp::LogLevel level, const char* tag, const char* message) {
                if (g_log_cb) {
                    g_log_cb(static_cast<int>(level), tag, message, g_log_ud);
                }
            });
    } else {
        tp::Logger::instance().set_callback(nullptr);
    }
}

// ---- Library ----

struct TPLibrary {
    tp::MediaLibrary library;
    std::string item_json_cache;
    std::string all_items_json_cache;
};

TPLibrary* tp_library_create(void) {
    return new TPLibrary();
}

void tp_library_destroy(TPLibrary* lib) {
    delete lib;
}

int tp_library_add_folder(TPLibrary* lib, const char* path) {
    if (!lib || !path) return TP_ERROR_INVALID_ARG;
    tp::Error err = lib->library.add_folder(path);
    return err ? TP_ERROR_FILE_NOT_FOUND : TP_OK;
}

int tp_library_get_item_count(TPLibrary* lib) {
    if (!lib) return 0;
    return lib->library.item_count();
}

const char* tp_library_get_item_json(TPLibrary* lib, int index) {
    if (!lib) return "{}";
    const tp::MediaItem* item = lib->library.item_at(index);
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

const char* tp_library_get_all_items_json(TPLibrary* lib) {
    if (!lib) return "[]";

    json arr = json::array();
    for (int i = 0; i < lib->library.item_count(); i++) {
        const tp::MediaItem* item = lib->library.item_at(i);
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
