#include "smb_media_source.h"
#include "plaiy/logger.h"

#include <algorithm>
#include <filesystem>
#include <unordered_set>
#include <sys/mount.h>

#import <Foundation/Foundation.h>
#import <NetFS/NetFS.h>

static constexpr const char* TAG = "SMBSource";

namespace fs = std::filesystem;

namespace py {

static const std::unordered_set<std::string> MEDIA_EXTENSIONS = {
    ".mkv", ".mp4", ".avi", ".ts", ".m4v", ".mov",
    ".wmv", ".flv", ".webm", ".m2ts", ".mpg", ".mpeg",
};

SMBMediaSource::SMBMediaSource(SourceConfig config)
    : config_(std::move(config)) {}

SMBMediaSource::~SMBMediaSource() {
    if (mounted_) {
        disconnect();
    }
}

Error SMBMediaSource::connect() {
    if (mounted_ && !mount_path_.empty() && fs::exists(mount_path_)) {
        PY_LOG_INFO(TAG, "Already mounted at %s", mount_path_.c_str());
        return Error::Ok();
    }

    @autoreleasepool {
        NSString* urlString = [NSString stringWithUTF8String:config_.base_uri.c_str()];
        NSURL* url = [NSURL URLWithString:urlString];
        if (!url) {
            return {ErrorCode::InvalidArgument, "Invalid SMB URL: " + config_.base_uri};
        }

        NSString* user = nil;
        NSString* pass = nil;
        NSMutableDictionary* openOptions = [NSMutableDictionary dictionary];

        if (!config_.username.empty() && !config_.password.empty()) {
            user = [NSString stringWithUTF8String:config_.username.c_str()];
            pass = [NSString stringWithUTF8String:config_.password.c_str()];
        } else {
            // Guest access
            openOptions[(__bridge NSString*)kNetFSUseGuestKey] = @YES;
        }

        // Allow subdirectory mounts (mount the specific share path)
        openOptions[(__bridge NSString*)kNetFSAllowSubMountsKey] = @YES;

        CFArrayRef mountPoints = nullptr;
        PY_LOG_INFO(TAG, "Mounting %s...", config_.base_uri.c_str());

        int32_t result = NetFSMountURLSync(
            (__bridge CFURLRef)url,
            nullptr,       // mount path (nil = auto)
            (__bridge CFStringRef)user,
            (__bridge CFStringRef)pass,
            (__bridge CFMutableDictionaryRef)openOptions,
            nullptr,       // mount options
            &mountPoints
        );

        if (result != 0) {
            PY_LOG_ERROR(TAG, "NetFSMountURLSync failed: %d for %s", result, config_.base_uri.c_str());

            std::string msg = "SMB mount failed (error " + std::to_string(result) + ")";
            if (result == EAUTH || result == EPERM) {
                msg = "Authentication failed — check username and password";
                return {ErrorCode::NetworkError, msg};
            }
            if (result == ENOENT || result == EHOSTUNREACH) {
                msg = "Server not found — check the address";
                return {ErrorCode::NetworkError, msg};
            }
            if (result == ETIMEDOUT) {
                msg = "Connection timed out";
                return {ErrorCode::NetworkError, msg};
            }
            return {ErrorCode::NetworkError, msg};
        }

        if (mountPoints && CFArrayGetCount(mountPoints) > 0) {
            NSArray* points = (__bridge_transfer NSArray*)mountPoints;
            NSString* mountPoint = points[0];
            mount_path_ = [mountPoint UTF8String];
            mounted_ = true;
            PY_LOG_INFO(TAG, "Mounted %s at %s", config_.base_uri.c_str(), mount_path_.c_str());
        } else {
            if (mountPoints) CFRelease(mountPoints);
            return {ErrorCode::NetworkError, "Mount succeeded but no mount point returned"};
        }
    }

    return Error::Ok();
}

void SMBMediaSource::disconnect() {
    if (!mounted_ || mount_path_.empty()) return;

    @autoreleasepool {
        // Unmount the volume
        int ret = ::unmount(mount_path_.c_str(), MNT_FORCE);
        if (ret == 0) {
            PY_LOG_INFO(TAG, "Unmounted %s", mount_path_.c_str());
        } else {
            PY_LOG_WARN(TAG, "Unmount failed for %s: %s", mount_path_.c_str(), strerror(errno));
        }
    }

    mounted_ = false;
    mount_path_.clear();
}

bool SMBMediaSource::is_connected() const {
    return mounted_ && !mount_path_.empty() && fs::exists(mount_path_);
}

Error SMBMediaSource::list_directory(const std::string& relative_path,
                                     std::vector<SourceEntry>& entries) {
    entries.clear();

    if (!is_connected()) {
        return {ErrorCode::InvalidState, "SMB source not connected"};
    }

    std::string full_path = mount_path_;
    if (!relative_path.empty()) {
        full_path += "/" + relative_path;
    }

    if (!fs::exists(full_path) || !fs::is_directory(full_path)) {
        return {ErrorCode::FileNotFound, "Directory not found: " + full_path};
    }

    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(full_path,
             fs::directory_options::skip_permission_denied, ec)) {
        if (ec) continue;

        std::string name = entry.path().filename().string();

        // Skip hidden files and macOS metadata
        if (!name.empty() && name[0] == '.') continue;

        if (entry.is_directory(ec)) {
            SourceEntry se;
            se.name = name;
            se.uri = entry.path().string();
            se.is_directory = true;
            se.size = 0;
            entries.push_back(std::move(se));
        } else if (entry.is_regular_file(ec)) {
            std::string ext = entry.path().extension().string();
            for (auto& c : ext) c = static_cast<char>(tolower(c));

            if (MEDIA_EXTENSIONS.count(ext) == 0) continue;

            SourceEntry se;
            se.name = name;
            se.uri = entry.path().string();
            se.is_directory = false;
            se.size = static_cast<int64_t>(entry.file_size(ec));
            entries.push_back(std::move(se));
        }
    }

    // Sort: directories first, then alphabetical
    std::sort(entries.begin(), entries.end(), [](const SourceEntry& a, const SourceEntry& b) {
        if (a.is_directory != b.is_directory) return a.is_directory > b.is_directory;
        return a.name < b.name;
    });

    PY_LOG_DEBUG(TAG, "Listed %s: %zu entries", full_path.c_str(), entries.size());
    return Error::Ok();
}

std::string SMBMediaSource::playable_path(const SourceEntry& entry) const {
    // Mount paths are already local filesystem paths
    return entry.uri;
}

} // namespace py
