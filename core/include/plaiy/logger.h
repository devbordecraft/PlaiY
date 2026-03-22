#pragma once

#include <cstdarg>
#include <functional>
#include <string>

namespace py {

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

} // namespace py

// Debug logs compile away in release builds
#ifdef NDEBUG
#define PY_LOG_DEBUG(tag, ...) ((void)0)
#else
#define PY_LOG_DEBUG(tag, ...) ::py::Logger::instance().log(::py::LogLevel::Debug, tag, __VA_ARGS__)
#endif

#define PY_LOG_INFO(tag, ...)  ::py::Logger::instance().log(::py::LogLevel::Info, tag, __VA_ARGS__)
#define PY_LOG_WARN(tag, ...)  ::py::Logger::instance().log(::py::LogLevel::Warning, tag, __VA_ARGS__)
#define PY_LOG_ERROR(tag, ...) ::py::Logger::instance().log(::py::LogLevel::Error, tag, __VA_ARGS__)
