#pragma once

#include <map>
#include <string>

namespace py {

struct HttpResponse {
    int status_code = 0;
    std::string body;
    std::string error_message;

    bool ok() const { return status_code >= 200 && status_code < 300; }
};

struct HttpRequest {
    std::string url;
    std::string method = "GET";
    std::string body;
    std::map<std::string, std::string> headers;
    int timeout_seconds = 15;
};

class IHttpClient {
public:
    virtual ~IHttpClient() = default;

    // Synchronous HTTP request. Blocks until complete or timeout.
    // Caller is responsible for running this on a background thread.
    virtual HttpResponse request(const HttpRequest& req) = 0;
};

} // namespace py
