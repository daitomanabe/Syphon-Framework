#ifndef FrameBusShared_h
#define FrameBusShared_h

#include <stdatomic.h>
#include <stdint.h>

#define FRAMEBUS_MAGIC 0x4652414d45425553ULL
#define FRAMEBUS_VERSION 1U
#define FRAMEBUS_MAX_SLOTS 8U
#define FRAMEBUS_MAX_CLIENTS 16U
#define FRAMEBUS_COLOR_PRIMARIES_SRGB 1U
#define FRAMEBUS_TRANSFER_SRGB 1U
#define FRAMEBUS_TRANSFER_LINEAR 2U
#define FRAMEBUS_ALPHA_OPAQUE 1U
#define FRAMEBUS_ALPHA_PREMULTIPLIED 2U

typedef struct FrameBusSharedState {
    uint64_t magic;
    uint32_t version;
    uint32_t headerSize;
    uint32_t width;
    uint32_t height;
    uint32_t pixelFormat;
    uint32_t bytesPerPixel;
    uint32_t slotCount;
    uint32_t reserved0;
    uint32_t surfaceIDs[FRAMEBUS_MAX_SLOTS];
    _Atomic uint64_t slotSequences[FRAMEBUS_MAX_SLOTS];
    _Atomic uint64_t clientSequences[FRAMEBUS_MAX_CLIENTS];
    _Atomic uint32_t clientActive[FRAMEBUS_MAX_CLIENTS];
    uint32_t colorPrimaries;
    uint32_t transferFunction;
    uint32_t alphaMode;
    uint32_t flags;
    _Atomic uint64_t sequence;
    _Atomic uint32_t currentSlot;
    _Atomic uint32_t clientCount;
    _Atomic uint64_t slotDepthFrames;
    _Atomic uint64_t overwrittenFrames;
    _Atomic uint64_t publishedFrames;
    _Atomic uint64_t observedFrames;
    _Atomic uint64_t repeatedReads;
    _Atomic uint64_t missedFrames;
    _Atomic uint64_t latestConsumerLagFrames;
    _Atomic uint64_t maxConsumerLagFrames;
    _Atomic uint64_t producerStallNanos;
    _Atomic uint64_t gpuWaitNanos;
    _Atomic uint64_t sharedEventSignals;
    _Atomic uint64_t sharedEventWaits;
    _Atomic uint64_t sharedEventTimeouts;
} FrameBusSharedState;

#endif
