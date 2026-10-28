// OfflineTweak.m
#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <Network/Network.h>
#import <objc/runtime.h>
#import "fishhook.h"

// ---------- 1. Все HTTP(S)/WS запросы падают как "нет интернета" ----------
@interface OfflineURLProtocol : NSURLProtocol @end
@implementation OfflineURLProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)req {
    NSString *s = req.URL.scheme.lowercaseString;
    return [s isEqualToString:@"http"] || [s isEqualToString:@"https"] ||
           [s isEqualToString:@"ws"]   || [s isEqualToString:@"wss"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)req { return req; }
- (void)startLoading {
    NSError *e = [NSError errorWithDomain:NSURLErrorDomain
                                     code:NSURLErrorNotConnectedToInternet
                                 userInfo:@{NSLocalizedDescriptionKey:
                                     @"The Internet connection appears to be offline."}];
    [self.client URLProtocol:self didFailWithError:e];
}
- (void)stopLoading {}
@end

// Подмешиваем протокол во все конфигурации сессий
static void swizzleClassGetter(Class cls, SEL sel) {
    Method m = class_getClassMethod(cls, sel);
    IMP orig = method_getImplementation(m);
    IMP repl = imp_implementationWithBlock(^NSURLSessionConfiguration *(id self_) {
        NSURLSessionConfiguration *c =
            ((NSURLSessionConfiguration *(*)(id, SEL))orig)(self_, sel);
        c.protocolClasses = @[[OfflineURLProtocol class]];
        return c;
    });
    method_setImplementation(m, repl);
}

// ---------- 2. SCNetworkReachability ----------
static Boolean (*orig_SCNRGetFlags)(SCNetworkReachabilityRef, SCNetworkReachabilityFlags *);
static Boolean my_SCNRGetFlags(SCNetworkReachabilityRef t, SCNetworkReachabilityFlags *flags) {
    if (flags) *flags = 0;          // нет достижимости
    return true;
}

// ---------- 3. Network.framework (NWPathMonitor) ----------
static nw_path_status_t (*orig_nw_path_get_status)(nw_path_t);
static nw_path_status_t my_nw_path_get_status(nw_path_t p) {
    return nw_path_status_unsatisfied;
}
static bool (*orig_nw_path_uses_interface_type)(nw_path_t, nw_interface_type_t);
static bool my_nw_path_uses_interface_type(nw_path_t p, nw_interface_type_t t) {
    return false;
}

__attribute__((constructor))
static void init(void) {
    [NSURLProtocol registerClass:[OfflineURLProtocol class]]; // для NSURLSession.shared
    swizzleClassGetter([NSURLSessionConfiguration class], @selector(defaultSessionConfiguration));
    swizzleClassGetter([NSURLSessionConfiguration class], @selector(ephemeralSessionConfiguration));

    rebind_symbols((struct rebinding[]){
        {"SCNetworkReachabilityGetFlags", my_SCNRGetFlags, (void *)&orig_SCNRGetFlags},
        {"nw_path_get_status", my_nw_path_get_status, (void *)&orig_nw_path_get_status},
        {"nw_path_uses_interface_type", my_nw_path_uses_interface_type, (void *)&orig_nw_path_uses_interface_type},
    }, 3);
}
