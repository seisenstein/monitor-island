// IOReport helper implementation. All IOReport symbols are private and resolved
// at runtime via -undefined dynamic_lookup at the final executable link.
#include "include/CIOReport.h"
#include <stdlib.h>

typedef struct {
    void *subscription;
    CFMutableDictionaryRef subbed;
    CFDictionaryRef prev;
} mi_ctx;

void *mi_ioreport_subscribe(CFStringRef group) {
    CFDictionaryRef chans = IOReportCopyChannelsInGroup(group, NULL, 0, 0, 0);
    if (!chans) return NULL;
    CFMutableDictionaryRef mut = CFDictionaryCreateMutableCopy(NULL, 0, chans);
    CFRelease(chans);
    if (!mut) return NULL;
    CFMutableDictionaryRef subbed = NULL;
    void *sub = IOReportCreateSubscription(NULL, mut, &subbed, 0, NULL);
    if (!sub || !subbed) { CFRelease(mut); return NULL; }
    mi_ctx *ctx = (mi_ctx *)malloc(sizeof(mi_ctx));
    ctx->subscription = sub;
    ctx->subbed = subbed;
    ctx->prev = IOReportCreateSamples(sub, subbed, NULL);
    CFRelease(mut);
    return ctx;
}

void mi_ioreport_sample(void *c, MIChannelBlock cb) {
    mi_ctx *ctx = (mi_ctx *)c;
    if (!ctx) return;
    CFDictionaryRef cur = IOReportCreateSamples(ctx->subscription, ctx->subbed, NULL);
    if (!cur) return;
    if (ctx->prev) {
        CFDictionaryRef delta = IOReportCreateSamplesDelta(ctx->prev, cur, NULL);
        if (delta) {
            IOReportIterate(delta, ^int(CFDictionaryRef ch) {
                CFStringRef g = IOReportChannelGetGroup(ch);
                CFStringRef n = IOReportChannelGetChannelName(ch);
                CFStringRef u = IOReportChannelGetUnitLabel(ch);
                int64_t v = IOReportSimpleGetIntegerValue(ch, 0);
                cb(g, n, u, v);
                return 0;
            });
            CFRelease(delta);
        }
        CFRelease(ctx->prev);
    }
    ctx->prev = cur;
}
