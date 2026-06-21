#ifndef CIOREPORT_H
#define CIOREPORT_H

#include <CoreFoundation/CoreFoundation.h>

// ---------------------------------------------------------------------------
// IOReport + IOHIDEventSystemClient private APIs (sudoless). No .tbd stub ships
// in the SDK; declared extern here and resolved at runtime with
// -undefined dynamic_lookup. Signatures follow the macmon writeup.
//
// The IOReport sample/subscription dance is wrapped in C helpers (mi_*) below
// and implemented in shim.c, so Swift never wrestles CF pointer ownership for
// the sample dictionaries. HID is used directly from Swift (implicit bridging).
// ---------------------------------------------------------------------------

typedef int (^IOReportIterateBlock)(CFDictionaryRef channel);

CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup,
                                            uint64_t a, uint64_t b, uint64_t c);
void IOReportMergeChannels(CFMutableDictionaryRef base, CFDictionaryRef toAdd, void *nilv);
void *IOReportCreateSubscription(void *allocator, CFMutableDictionaryRef desiredChannels,
                                 CFMutableDictionaryRef *outSubbedChannels,
                                 uint64_t channelID, void *nilv);
CFDictionaryRef IOReportCreateSamples(void *subscription, CFMutableDictionaryRef subbedChannels, void *nilv);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef cur, void *nilv);
void IOReportIterate(CFDictionaryRef samples, IOReportIterateBlock callback);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef channel);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef channel);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef channel);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef channel);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int index);

// --- High-level helpers (implemented in shim.c) ---
// Per-channel callback: group, channel name, unit label, delta integer value.
typedef void (^MIChannelBlock)(CFStringRef group, CFStringRef name, CFStringRef unit, int64_t value);
// Subscribe to an IOReport group; returns an opaque context (NULL on failure).
void *mi_ioreport_subscribe(CFStringRef group);
// Sample once: iterate the delta vs the previous sample, invoking cb per channel.
void mi_ioreport_sample(void *ctx, MIChannelBlock cb);

// ---------------------------------------------------------------------------
// IOHIDEventSystemClient (private thermal sensors). Non-"Ref" aliases avoid
// clashing with the SDK's CF_BRIDGED_TYPE typedefs. Wrapped in implicit
// bridging so Swift imports managed CF values for Copy* returns.
// ---------------------------------------------------------------------------

typedef CFTypeRef MIHIDClient;
typedef CFTypeRef MIHIDService;
typedef CFTypeRef MIHIDEvent;

CF_IMPLICIT_BRIDGING_ENABLED
CF_ASSUME_NONNULL_BEGIN

MIHIDClient _Nullable IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator);
void IOHIDEventSystemClientSetMatching(MIHIDClient client, CFDictionaryRef matching);
CFArrayRef _Nullable IOHIDEventSystemClientCopyServices(MIHIDClient client);
CFTypeRef _Nullable IOHIDServiceClientCopyProperty(MIHIDService service, CFStringRef key);
MIHIDEvent _Nullable IOHIDServiceClientCopyEvent(MIHIDService service, int64_t type,
                                                 int32_t options, int64_t timestamp);
double IOHIDEventGetFloatValue(MIHIDEvent event, int32_t field);

CF_ASSUME_NONNULL_END
CF_IMPLICIT_BRIDGING_DISABLED

#endif
