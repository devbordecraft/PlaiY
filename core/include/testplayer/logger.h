#pragma once

#include <cstdarg>
#include <functional>
#include <string>

namespace tp {

enum class LogLevel {
    Debug,
    Info,
    Warning,
    Error,
};

class Logger {
public:
    using LogCallback = std::function<void(LogLevel, const char* tag, const char* message)>;

    static Logger& instance();

    void set_level(LogLevel level);
    LogLevel level() const;
    void set_callback(LogCallback callback);

    void log(LogLevel level, const char* tag, const char* fmt, ...) __attribute__((format(printf, 4, 5)));

private:
    Logger();
    LogLevel min_level_;
    LogCallback callback_;
};

} // namespace tp

// Debug logs compile away in release builds
#ifdef NDEBUG
#define TP_LOG_DEBUG(tag, ...) ((void)0)
#else
#define TP_LOG_DEBUG(tag, ...) ::tp::Logger::instance().log(::tp::LogLevel::Debug, tag, __VA_ARGS__)
#endif

#define TP_LOG_INFO(tag, ...)  ::tp::Logger::instance().log(::tp::LogLevel::Info, tag, __VA_ARGS__)
#define TP_LOG_WARN(tag, ...)  ::tp::Logger::instance().log(::tp::LogLevel::Warning, tag, __VA_ARGS__)
#define TP_LOG_ERROR(tag, ...) ::tp::Logger::instance().log(::tp::LogLevel::Error, tag, __VA_ARGS__)
