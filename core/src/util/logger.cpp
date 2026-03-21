#include "testplayer/logger.h"
#include <chrono>
#include <cstdio>
#include <cstdarg>
#include <ctime>

namespace tp {

Logger::Logger()
#ifdef NDEBUG
    : min_level_(LogLevel::Info)
#else
    : min_level_(LogLevel::Debug)
#endif
{
}

Logger& Logger::instance() {
    static Logger logger;
    return logger;
}

void Logger::set_level(LogLevel level) {
    min_level_ = level;
}

LogLevel Logger::level() const {
    return min_level_;
}

void Logger::set_callback(LogCallback callback) {
    callback_ = std::move(callback);
}

void Logger::log(LogLevel level, const char* tag, const char* fmt, ...) {
    if (level < min_level_) return;

    char buf[2048];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    if (callback_) {
        callback_(level, tag, buf);
        return;
    }

    const char* level_str = "?";
    switch (level) {
        case LogLevel::Debug:   level_str = "D"; break;
        case LogLevel::Info:    level_str = "I"; break;
        case LogLevel::Warning: level_str = "W"; break;
        case LogLevel::Error:   level_str = "E"; break;
    }

    // Timestamp: HH:MM:SS.mmm
    auto now = std::chrono::system_clock::now();
    auto time_t_now = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()) % 1000;
    struct tm tm_buf;
    localtime_r(&time_t_now, &tm_buf);

    fprintf(stderr, "%02d:%02d:%02d.%03d [%s/%s] %s\n",
            tm_buf.tm_hour, tm_buf.tm_min, tm_buf.tm_sec,
            static_cast<int>(ms.count()), level_str, tag, buf);
}

} // namespace tp
