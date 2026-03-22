#pragma once

#include <string>

namespace py {

enum class ErrorCode {
    OK = 0,
    Unknown,
    InvalidArgument,
    FileNotFound,
    UnsupportedFormat,
    UnsupportedCodec,
    DecoderInitFailed,
    DecoderError,
    DemuxerError,
    EndOfFile,
    NeedMoreInput,
    OutputNotReady,
    AudioOutputError,
    RendererError,
    LibraryError,
    SubtitleError,
    OutOfMemory,
    InvalidState,
};

struct Error {
    ErrorCode code = ErrorCode::OK;
    std::string message;

    Error() = default;
    Error(ErrorCode c) : code(c) {}
    Error(ErrorCode c, std::string msg) : code(c), message(std::move(msg)) {}

    explicit operator bool() const { return code != ErrorCode::OK; }
    bool ok() const { return code == ErrorCode::OK; }

    static Error Ok() { return {ErrorCode::OK}; }
};

} // namespace py
