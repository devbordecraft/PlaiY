#include "ns_http_client.h"
#include "plaiy/logger.h"

#import <Foundation/Foundation.h>

static constexpr const char* TAG = "HttpClient";

// Delegate that accepts self-signed certificates (common for Plex servers)
@interface PYURLSessionDelegate : NSObject <NSURLSessionDelegate>
@end

@implementation PYURLSessionDelegate

- (void)URLSession:(NSURLSession*)session
    didReceiveChallenge:(NSURLAuthenticationChallenge*)challenge
      completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,
                                  NSURLCredential* _Nullable))completionHandler {
    if ([challenge.protectionSpace.authenticationMethod
            isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        SecTrustRef trust = challenge.protectionSpace.serverTrust;
        if (trust) {
            NSURLCredential* credential = [NSURLCredential credentialForTrust:trust];
            completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
            return;
        }
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

@end

namespace py {

NSHttpClient::NSHttpClient() {
    @autoreleasepool {
        PYURLSessionDelegate* del = [[PYURLSessionDelegate alloc] init];
        delegate_ = (__bridge_retained void*)del;

        NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
        NSURLSession* session = [NSURLSession sessionWithConfiguration:config
                                                              delegate:del
                                                         delegateQueue:nil];
        session_ = (__bridge_retained void*)session;
    }
}

NSHttpClient::~NSHttpClient() {
    @autoreleasepool {
        NSURLSession* session = (__bridge_transfer NSURLSession*)session_;
        [session invalidateAndCancel];
        session_ = nullptr;

        // Release the delegate
        CFRelease(delegate_);
        delegate_ = nullptr;
    }
}

HttpResponse NSHttpClient::request(const HttpRequest& req) {
    @autoreleasepool {
        NSURLSession* session = (__bridge NSURLSession*)session_;

        NSURL* url = [NSURL URLWithString:[NSString stringWithUTF8String:req.url.c_str()]];
        if (!url) {
            PY_LOG_ERROR(TAG, "Invalid URL: %s", req.url.c_str());
            return {0, "", "Invalid URL: " + req.url};
        }

        NSMutableURLRequest* nsReq = [NSMutableURLRequest requestWithURL:url];
        nsReq.HTTPMethod = [NSString stringWithUTF8String:req.method.c_str()];
        nsReq.timeoutInterval = static_cast<NSTimeInterval>(req.timeout_seconds);

        for (const auto& [key, value] : req.headers) {
            [nsReq setValue:[NSString stringWithUTF8String:value.c_str()]
                forHTTPHeaderField:[NSString stringWithUTF8String:key.c_str()]];
        }

        if (!req.body.empty()) {
            nsReq.HTTPBody = [NSData dataWithBytes:req.body.c_str()
                                            length:req.body.size()];
        }

        __block HttpResponse result;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        PY_LOG_DEBUG(TAG, "%s %s", req.method.c_str(), req.url.c_str());

        NSURLSessionDataTask* task = [session
            dataTaskWithRequest:nsReq
              completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                if (error) {
                    result.error_message = [error.localizedDescription UTF8String];
                    PY_LOG_WARN(TAG, "Request failed: %s", result.error_message.c_str());
                } else {
                    NSHTTPURLResponse* httpResp = (NSHTTPURLResponse*)response;
                    result.status_code = static_cast<int>(httpResp.statusCode);
                    if (data) {
                        result.body = std::string(
                            static_cast<const char*>(data.bytes),
                            static_cast<size_t>(data.length));
                    }
                    PY_LOG_DEBUG(TAG, "Response: %d (%zu bytes)",
                                 result.status_code, result.body.size());
                }
                dispatch_semaphore_signal(sem);
              }];
        [task resume];

        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        return result;
    }
}

} // namespace py
