#include "plaiy_c.h"
#include "plaiy/logger.h"
#include "plaiy/player_engine.h"
#include "plaiy/media_library.h"

#include <nlohmann/json.hpp>
#include <string>
#include <mutex>

using json = nlohmann::json;

// ---- Player wrapper ----

struct PYPlayer {
    py::PlayerEngine engine;
    std::string media_info_json;
    std::string last_error_msg;

    // Callback storage
    PYStateCallback state_cb = nullptr;
    void* state_ud = nullptr;
    PYErrorCallback error_cb = nullptr;
    void* error_ud = nullptr;
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

int py_player_open(PYPlayer* p, const char* path) {
    if (!p || !path) return PY_ERROR_INVALID_ARG;

    // Wire up callbacks before opening
    if (p->state_cb) {
        p->engine.set_state_callback([p](py::PlaybackState s) {
            p->state_cb(static_cast<int>(s), p->state_ud);
        });
    }
    if (p->error_cb) {
        p->engine.set_error_callback([p](py::Error err) {
            p->error_cb(static_cast<int>(err.code), err.message.c_str(), p->error_ud);
        });
    }

    py::Error err = p->engine.open_file(path);
    if (err) return PY_ERROR_FILE_NOT_FOUND;
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

int py_player_frame_get_color_space(void* frame) {
    if (!frame) return 0;
    return static_cast<py::VideoFrame*>(frame)->color_space;
}

int py_player_frame_get_color_trc(void* frame) {
    if (!frame) return 0;
    return static_cast<py::VideoFrame*>(frame)->color_trc;
}

bool py_player_frame_is_hardware(void* frame) {
    if (!frame) return false;
    return static_cast<py::VideoFrame*>(frame)->hardware_frame;
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

// ---- Callbacks ----

void py_player_set_state_callback(PYPlayer* p, PYStateCallback cb, void* userdata) {
    if (!p) return;
    p->state_cb = cb;
    p->state_ud = userdata;
}

void py_player_set_error_callback(PYPlayer* p, PYErrorCallback cb, void* userdata) {
    if (!p) return;
    p->error_cb = cb;
    p->error_ud = userdata;
}

// ---- Logging ----

void py_log_set_level(int level) {
    py::Logger::instance().set_level(static_cast<py::LogLevel>(level));
}

int py_log_get_level(void) {
    return static_cast<int>(py::Logger::instance().level());
}

static PYLogCallback g_log_cb = nullptr;
static void* g_log_ud = nullptr;

void py_log_set_callback(PYLogCallback cb, void* userdata) {
    g_log_cb = cb;
    g_log_ud = userdata;

    if (cb) {
        py::Logger::instance().set_callback(
            [](py::LogLevel level, const char* tag, const char* message) {
                if (g_log_cb) {
                    g_log_cb(static_cast<int>(level), tag, message, g_log_ud);
                }
            });
    } else {
        py::Logger::instance().set_callback(nullptr);
    }
}

// ---- Library ----

struct PYLibrary {
    py::MediaLibrary library;
    std::string item_json_cache;
    std::string all_items_json_cache;
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
