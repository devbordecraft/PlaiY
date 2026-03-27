#pragma once

#include "http/http_client.h"

namespace py {

class NSHttpClient : public IHttpClient {
public:
    NSHttpClient();
    ~NSHttpClient() override;

    HttpResponse request(const HttpRequest& req) override;

private:
    void* session_;  // NSURLSession* (opaque to avoid ObjC in header)
    void* delegate_; // NSURLSessionDelegate* (prevent dealloc)
};

} // namespace py
