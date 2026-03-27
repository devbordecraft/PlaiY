#pragma once

#include "plaiy/error.h"
#include "plaiy/media_source.h"
#include <memory>
#include <string>

namespace py {

class SourceManager {
public:
    SourceManager();
    ~SourceManager();

    // Add a source. The SourceConfig must have a non-empty source_id.
    Error add_source(const SourceConfig& config);

    // Remove a source by ID. Disconnects it first if connected.
    void remove_source(const std::string& source_id);

    int source_count() const;
    IMediaSource* source_at(int index);
    IMediaSource* source_by_id(const std::string& source_id);

    // Factory: creates the correct IMediaSource subclass for a given config.
    // This is the plugin registration point — adding a protocol means adding
    // a case here.
    static std::unique_ptr<IMediaSource> create_source(SourceConfig config);

    // Serialize all source configs as a JSON array (passwords excluded).
    std::string configs_json() const;

    // Load source configs from a JSON array. Creates source objects via factory.
    Error load_configs_json(const std::string& json);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace py
