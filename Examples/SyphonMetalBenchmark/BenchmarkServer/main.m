#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <mach/mach_time.h>
#import <fcntl.h>
#import <signal.h>
#import <stdatomic.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>
#import <Syphon/Syphon.h>
#import "../FrameBusShared.h"

static volatile sig_atomic_t gShouldRun = 1;

static void HandleSignal(int signalNumber)
{
    (void)signalNumber;
    gShouldRun = 0;
}

static double NowSeconds(void)
{
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&timebase);
    });
    uint64_t now = mach_absolute_time();
    return ((double)now * (double)timebase.numer / (double)timebase.denom) / 1000000000.0;
}

static NSString *ArgumentValue(NSArray<NSString *> *arguments, NSString *name, NSString *fallback)
{
    NSUInteger index = [arguments indexOfObject:name];
    if (index != NSNotFound && index + 1 < arguments.count)
    {
        return arguments[index + 1];
    }
    return fallback;
}

static NSUInteger UnsignedArgument(NSArray<NSString *> *arguments, NSString *name, NSUInteger fallback)
{
    NSString *value = ArgumentValue(arguments, name, nil);
    return value ? (NSUInteger)MAX((NSInteger)0, value.integerValue) : fallback;
}

static double DoubleArgument(NSArray<NSString *> *arguments, NSString *name, double fallback)
{
    NSString *value = ArgumentValue(arguments, name, nil);
    return value ? value.doubleValue : fallback;
}

static NSString *PixelFormatName(NSString *requested)
{
    NSString *lower = requested.lowercaseString;
    if ([lower isEqualToString:@"rgba16f"] || [lower isEqualToString:@"rgba16float"])
    {
        return @"rgba16f";
    }
    return @"bgra8";
}

static MTLPixelFormat MetalPixelFormat(NSString *pixelFormatName)
{
    return [pixelFormatName isEqualToString:@"rgba16f"] ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
}

static OSType CoreVideoPixelFormat(NSString *pixelFormatName)
{
    return [pixelFormatName isEqualToString:@"rgba16f"] ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA;
}

static NSUInteger BytesPerPixel(NSString *pixelFormatName)
{
    return [pixelFormatName isEqualToString:@"rgba16f"] ? 8U : 4U;
}

static void EnsureParentDirectory(NSString *path)
{
    if (!path.length)
    {
        return;
    }
    NSString *parent = path.stringByDeletingLastPathComponent;
    if (parent.length)
    {
        [[NSFileManager defaultManager] createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

static BOOL WriteJSON(NSDictionary *object, NSString *path)
{
    if (!path.length)
    {
        return YES;
    }
    EnsureParentDirectory(path);
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:&error];
    if (!data)
    {
        fprintf(stderr, "Could not encode JSON: %s\n", error.localizedDescription.UTF8String);
        return NO;
    }
    if (![data writeToFile:path atomically:YES])
    {
        fprintf(stderr, "Could not write JSON summary: %s\n", path.UTF8String);
        return NO;
    }
    return YES;
}

static void AtomicMaxUInt64(_Atomic uint64_t *target, uint64_t value)
{
    uint64_t current = atomic_load(target);
    while (value > current && !atomic_compare_exchange_weak(target, &current, value))
    {
    }
}

static uint64_t NanosFromSeconds(double seconds)
{
    return (uint64_t)MAX(0.0, seconds * 1000000000.0);
}

@interface SyphonMetalBenchmarkServerRunner : NSObject
- (instancetype)initWithName:(NSString *)name width:(NSUInteger)width height:(NSUInteger)height fps:(double)fps pixelFormatName:(NSString *)pixelFormatName;
- (NSDictionary *)runWithWarmup:(double)warmup duration:(double)duration waitForClients:(NSUInteger)waitForClients waitTimeout:(double)waitTimeout csvPath:(NSString *)csvPath csvEvery:(NSUInteger)csvEvery;
- (void)stop;
@end

@implementation SyphonMetalBenchmarkServerRunner
{
    NSString *_name;
    NSUInteger _width;
    NSUInteger _height;
    double _fps;
    NSString *_pixelFormatName;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLTexture> _sourceTexture;
    SyphonMetalServer *_server;
    NSUInteger _submittedFrames;
}

- (instancetype)initWithName:(NSString *)name width:(NSUInteger)width height:(NSUInteger)height fps:(double)fps pixelFormatName:(NSString *)pixelFormatName
{
    self = [super init];
    if (self)
    {
        _name = [name copy];
        _width = MAX((NSUInteger)1, width);
        _height = MAX((NSUInteger)1, height);
        _fps = fps;
        _pixelFormatName = [PixelFormatName(pixelFormatName) copy];
        _device = MTLCreateSystemDefaultDevice();
        _commandQueue = [_device newCommandQueue];
        if (!_device || !_commandQueue)
        {
            fprintf(stderr, "Metal device or command queue is unavailable.\n");
            return nil;
        }

        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MetalPixelFormat(_pixelFormatName)
                                                                                              width:_width
                                                                                             height:_height
                                                                                          mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        _sourceTexture = [_device newTextureWithDescriptor:descriptor];
        if (!_sourceTexture)
        {
            fprintf(stderr, "Could not allocate source texture.\n");
            return nil;
        }

        NSUInteger bytesPerPixel = BytesPerPixel(_pixelFormatName);
        NSMutableData *zeroFrame = [NSMutableData dataWithLength:_width * _height * bytesPerPixel];
        [_sourceTexture replaceRegion:MTLRegionMake2D(0, 0, _width, _height)
                           mipmapLevel:0
                             withBytes:zeroFrame.bytes
                           bytesPerRow:_width * bytesPerPixel];

        NSDictionary *options = @{
            SyphonServerOptionFrameChannel: SyphonFrameChannelColor,
            SyphonServerOptionPixelFormat: @(CoreVideoPixelFormat(_pixelFormatName))
        };
        _server = [[SyphonMetalServer alloc] initWithName:_name device:_device options:options];
        if (!_server)
        {
            fprintf(stderr, "Could not start Syphon Metal server.\n");
            return nil;
        }
    }
    return self;
}

- (void)dealloc
{
    [self stop];
}

- (void)stop
{
    [_server stop];
    _server = nil;
}

- (NSUInteger)frameClientCount
{
    NSNumber *count = _server.diagnostics[SyphonDiagnosticsFrameClientCountKey];
    return [count respondsToSelector:@selector(unsignedIntegerValue)] ? count.unsignedIntegerValue : 0U;
}

- (BOOL)waitForFrameClients:(NSUInteger)requiredCount timeout:(double)timeout actualWait:(double *)actualWait
{
    double start = NowSeconds();
    while (gShouldRun && requiredCount > 0U && [self frameClientCount] < requiredCount)
    {
        if (NowSeconds() - start >= timeout)
        {
            break;
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        usleep(10000);
    }
    if (actualWait)
    {
        *actualWait = NowSeconds() - start;
    }
    return requiredCount == 0U || [self frameClientCount] >= requiredCount;
}

- (void)publishFrame
{
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    [_server publishFrameTexture:_sourceTexture
                 onCommandBuffer:commandBuffer
                      imageRegion:NSMakeRect(0, 0, _width, _height)
                          flipped:NO];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    _submittedFrames++;
}

- (NSUInteger)runPhaseNamed:(const char *)phase duration:(double)duration startFrame:(NSUInteger)startFrame csv:(FILE *)csv csvEvery:(NSUInteger)csvEvery
{
    if (duration <= 0.0)
    {
        return 0U;
    }

    double phaseStart = NowSeconds();
    double nextFrameTime = phaseStart;
    NSUInteger phaseFrames = 0U;

    while (gShouldRun)
    {
        double now = NowSeconds();
        if (now - phaseStart >= duration)
        {
            break;
        }

        [self publishFrame];
        phaseFrames++;

        if (csv && (csvEvery <= 1U || (phaseFrames % csvEvery) == 0U))
        {
            NSDictionary *diagnostics = _server.diagnostics;
            NSNumber *published = diagnostics[SyphonDiagnosticsPublishedFrameCountKey] ?: @0;
            NSNumber *frameClients = diagnostics[SyphonDiagnosticsFrameClientCountKey] ?: @0;
            fprintf(csv,
                    "%s,%lu,%.9f,%.9f,%lu,%lu\n",
                    phase,
                    (unsigned long)(startFrame + phaseFrames),
                    NowSeconds(),
                    NowSeconds() - phaseStart,
                    (unsigned long)published.unsignedIntegerValue,
                    (unsigned long)frameClients.unsignedIntegerValue);
        }

        if (_fps > 0.0)
        {
            nextFrameTime += 1.0 / _fps;
            double sleepSeconds = nextFrameTime - NowSeconds();
            if (sleepSeconds > 0.0)
            {
                usleep((useconds_t)(sleepSeconds * 1000000.0));
            }
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }

    return phaseFrames;
}

- (NSDictionary *)runWithWarmup:(double)warmup duration:(double)duration waitForClients:(NSUInteger)waitForClients waitTimeout:(double)waitTimeout csvPath:(NSString *)csvPath csvEvery:(NSUInteger)csvEvery
{
    FILE *csv = NULL;
    if (csvPath.length)
    {
        EnsureParentDirectory(csvPath);
        csv = fopen(csvPath.fileSystemRepresentation, "w");
        if (csv)
        {
            fprintf(csv, "phase,frameIndex,hostTimeSeconds,phaseElapsedSeconds,publishedFrameCount,frameClientCount\n");
        }
    }

    double waitSeconds = 0.0;
    BOOL clientsReady = [self waitForFrameClients:waitForClients timeout:waitTimeout actualWait:&waitSeconds];
    double benchmarkStart = NowSeconds();
    NSUInteger warmupFrames = [self runPhaseNamed:"warmup" duration:warmup startFrame:0 csv:csv csvEvery:csvEvery];
    double measuredStart = NowSeconds();
    NSUInteger measuredFrames = [self runPhaseNamed:"measured" duration:duration startFrame:warmupFrames csv:csv csvEvery:csvEvery];
    double measuredElapsed = NowSeconds() - measuredStart;
    double benchmarkElapsed = NowSeconds() - benchmarkStart;

    if (csv)
    {
        fclose(csv);
    }

    NSDictionary *diagnostics = _server.diagnostics ?: @{};
    return @{
        @"transport": @"syphon-metal",
        @"role": @"server",
        @"serverName": _name,
        @"width": @(_width),
        @"height": @(_height),
        @"targetFPS": @(_fps),
        @"pixelFormat": _pixelFormatName,
        @"warmupSeconds": @(warmup),
        @"durationSeconds": @(duration),
        @"waitForClients": @(waitForClients),
        @"waitTimeoutSeconds": @(waitTimeout),
        @"waitSeconds": @(waitSeconds),
        @"clientsReady": @(clientsReady),
        @"warmupFrames": @(warmupFrames),
        @"measuredFrames": @(measuredFrames),
        @"measuredElapsedSeconds": @(measuredElapsed),
        @"measuredSubmittedFPS": @(measuredElapsed > 0.0 ? (double)measuredFrames / measuredElapsed : 0.0),
        @"totalSubmittedFrames": @(_submittedFrames),
        @"benchmarkElapsedSeconds": @(benchmarkElapsed),
        @"csvEvery": @(csvEvery),
        @"diagnostics": diagnostics
    };
}
@end

@interface FrameBusBenchmarkServerRunner : NSObject
- (instancetype)initWithStatePath:(NSString *)statePath eventPath:(NSString *)eventPath useSharedEvent:(BOOL)useSharedEvent width:(NSUInteger)width height:(NSUInteger)height fps:(double)fps pixelFormatName:(NSString *)pixelFormatName slots:(NSUInteger)slots;
- (NSDictionary *)runWithWarmup:(double)warmup duration:(double)duration waitForClients:(NSUInteger)waitForClients waitTimeout:(double)waitTimeout csvPath:(NSString *)csvPath csvEvery:(NSUInteger)csvEvery;
- (void)stop;
@end

@implementation FrameBusBenchmarkServerRunner
{
    NSString *_statePath;
    NSUInteger _width;
    NSUInteger _height;
    double _fps;
    NSString *_pixelFormatName;
    NSUInteger _slotCount;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLTexture> _sourceTexture;
    id<MTLTexture> _slotTextures[FRAMEBUS_MAX_SLOTS];
    IOSurfaceRef _surfaces[FRAMEBUS_MAX_SLOTS];
    FrameBusSharedState *_state;
    int _stateFD;
    NSUInteger _submittedFrames;
    NSString *_eventPath;
    BOOL _useSharedEvent;
    BOOL _sharedEventReady;
    id<MTLSharedEvent> _sharedEvent;
}

- (instancetype)initWithStatePath:(NSString *)statePath eventPath:(NSString *)eventPath useSharedEvent:(BOOL)useSharedEvent width:(NSUInteger)width height:(NSUInteger)height fps:(double)fps pixelFormatName:(NSString *)pixelFormatName slots:(NSUInteger)slots
{
    self = [super init];
    if (self)
    {
        _statePath = [statePath copy];
        _eventPath = [eventPath copy];
        _useSharedEvent = useSharedEvent;
        _width = MAX((NSUInteger)1, width);
        _height = MAX((NSUInteger)1, height);
        _fps = fps;
        _pixelFormatName = [PixelFormatName(pixelFormatName) copy];
        _slotCount = MIN(MAX((NSUInteger)2, slots), (NSUInteger)FRAMEBUS_MAX_SLOTS);
        _stateFD = -1;

        if (!_statePath.length)
        {
            fprintf(stderr, "FrameBus requires --state.\n");
            return nil;
        }

        _device = MTLCreateSystemDefaultDevice();
        _commandQueue = [_device newCommandQueue];
        if (!_device || !_commandQueue)
        {
            fprintf(stderr, "Metal device or command queue is unavailable.\n");
            return nil;
        }

        MTLTextureDescriptor *sourceDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MetalPixelFormat(_pixelFormatName)
                                                                                                    width:_width
                                                                                                   height:_height
                                                                                                mipmapped:NO];
        sourceDescriptor.usage = MTLTextureUsageShaderRead;
        sourceDescriptor.storageMode = MTLStorageModeShared;
        _sourceTexture = [_device newTextureWithDescriptor:sourceDescriptor];
        if (!_sourceTexture)
        {
            fprintf(stderr, "Could not allocate source texture.\n");
            return nil;
        }

        NSUInteger bytesPerPixel = BytesPerPixel(_pixelFormatName);
        NSMutableData *zeroFrame = [NSMutableData dataWithLength:_width * _height * bytesPerPixel];
        [_sourceTexture replaceRegion:MTLRegionMake2D(0, 0, _width, _height)
                           mipmapLevel:0
                             withBytes:zeroFrame.bytes
                           bytesPerRow:_width * bytesPerPixel];

        for (NSUInteger index = 0; index < _slotCount; index++)
        {
            NSDictionary<NSString *, id> *attributes = @{
                (NSString *)kIOSurfaceIsGlobal: @YES,
                (NSString *)kIOSurfaceWidth: @(_width),
                (NSString *)kIOSurfaceHeight: @(_height),
                (NSString *)kIOSurfacePixelFormat: @(CoreVideoPixelFormat(_pixelFormatName)),
                (NSString *)kIOSurfaceBytesPerElement: @(bytesPerPixel)
            };
            _surfaces[index] = IOSurfaceCreate((CFDictionaryRef)attributes);
            if (!_surfaces[index])
            {
                fprintf(stderr, "Could not create FrameBus IOSurface slot %lu.\n", (unsigned long)index);
                return nil;
            }

            MTLTextureDescriptor *slotDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MetalPixelFormat(_pixelFormatName)
                                                                                                      width:_width
                                                                                                     height:_height
                                                                                                  mipmapped:NO];
            slotDescriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
            _slotTextures[index] = [_device newTextureWithDescriptor:slotDescriptor iosurface:_surfaces[index] plane:0];
            if (!_slotTextures[index])
            {
                fprintf(stderr, "Could not create FrameBus Metal texture slot %lu.\n", (unsigned long)index);
                return nil;
            }
        }

        EnsureParentDirectory(_statePath);
        _stateFD = open(_statePath.fileSystemRepresentation, O_CREAT | O_RDWR | O_TRUNC, 0600);
        if (_stateFD < 0)
        {
            perror("open framebus state");
            return nil;
        }
        if (ftruncate(_stateFD, (off_t)sizeof(FrameBusSharedState)) != 0)
        {
            perror("ftruncate framebus state");
            return nil;
        }
        _state = mmap(NULL, sizeof(FrameBusSharedState), PROT_READ | PROT_WRITE, MAP_SHARED, _stateFD, 0);
        if (_state == MAP_FAILED)
        {
            perror("mmap framebus state");
            _state = NULL;
            return nil;
        }

        memset(_state, 0, sizeof(FrameBusSharedState));
        _state->magic = FRAMEBUS_MAGIC;
        _state->version = FRAMEBUS_VERSION;
        _state->headerSize = (uint32_t)sizeof(FrameBusSharedState);
        _state->width = (uint32_t)_width;
        _state->height = (uint32_t)_height;
        _state->pixelFormat = CoreVideoPixelFormat(_pixelFormatName);
        _state->bytesPerPixel = (uint32_t)bytesPerPixel;
        _state->slotCount = (uint32_t)_slotCount;
        _state->colorPrimaries = FRAMEBUS_COLOR_PRIMARIES_SRGB;
        _state->transferFunction = [_pixelFormatName isEqualToString:@"rgba16f"] ? FRAMEBUS_TRANSFER_LINEAR : FRAMEBUS_TRANSFER_SRGB;
        _state->alphaMode = FRAMEBUS_ALPHA_OPAQUE;
        for (NSUInteger index = 0; index < _slotCount; index++)
        {
            _state->surfaceIDs[index] = IOSurfaceGetID(_surfaces[index]);
        }
        if (_useSharedEvent && _eventPath.length)
        {
            if (@available(macOS 10.14, *))
            {
                _sharedEvent = [_device newSharedEvent];
                MTLSharedEventHandle *handle = [_sharedEvent newSharedEventHandle];
                NSError *archiveError = nil;
                NSData *eventData = [NSKeyedArchiver archivedDataWithRootObject:handle requiringSecureCoding:NO error:&archiveError];
                if (eventData)
                {
                    EnsureParentDirectory(_eventPath);
                    _sharedEventReady = [eventData writeToFile:_eventPath atomically:YES];
                    if (_sharedEventReady)
                    {
                        _state->flags |= 1U;
                    }
                }
                if (!_sharedEventReady && archiveError)
                {
                    fprintf(stderr, "Shared event archive failed: %s\n", archiveError.localizedDescription.UTF8String);
                }
            }
        }
        atomic_store(&_state->currentSlot, 0U);
        atomic_store(&_state->sequence, 0ULL);
        msync(_state, sizeof(FrameBusSharedState), MS_SYNC);
    }
    return self;
}

- (void)dealloc
{
    [self stop];
}

- (void)stop
{
    if (_state)
    {
        msync(_state, sizeof(FrameBusSharedState), MS_SYNC);
        munmap(_state, sizeof(FrameBusSharedState));
        _state = NULL;
    }
    if (_stateFD >= 0)
    {
        close(_stateFD);
        _stateFD = -1;
    }
    for (NSUInteger index = 0; index < _slotCount; index++)
    {
        _slotTextures[index] = nil;
        if (_surfaces[index])
        {
            CFRelease(_surfaces[index]);
            _surfaces[index] = NULL;
        }
    }
}

- (NSUInteger)frameClientCount
{
    return _state ? (NSUInteger)atomic_load(&_state->clientCount) : 0U;
}

- (BOOL)waitForFrameClients:(NSUInteger)requiredCount timeout:(double)timeout actualWait:(double *)actualWait
{
    double start = NowSeconds();
    while (gShouldRun && requiredCount > 0U && [self frameClientCount] < requiredCount)
    {
        if (NowSeconds() - start >= timeout)
        {
            break;
        }
        usleep(10000);
    }
    if (actualWait)
    {
        *actualWait = NowSeconds() - start;
    }
    return requiredCount == 0U || [self frameClientCount] >= requiredCount;
}

- (void)publishFrame
{
    uint64_t nextSequence = atomic_load(&_state->sequence) + 1ULL;
    uint32_t slot = (uint32_t)(nextSequence % _slotCount);
    uint64_t previousSlotSequence = atomic_load(&_state->slotSequences[slot]);
    if (previousSlotSequence > 0ULL)
    {
        atomic_fetch_add(&_state->overwrittenFrames, 1ULL);
    }
    atomic_store(&_state->slotDepthFrames, MIN(nextSequence, (uint64_t)_slotCount));

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:_sourceTexture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(_width, _height, 1)
                toTexture:_slotTextures[slot]
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    if (_sharedEventReady)
    {
        if (@available(macOS 10.14, *))
        {
            [commandBuffer encodeSignalEvent:_sharedEvent value:nextSequence];
            atomic_fetch_add(&_state->sharedEventSignals, 1ULL);
        }
    }

    if (_sharedEventReady)
    {
        atomic_store(&_state->slotSequences[slot], nextSequence);
        atomic_store(&_state->currentSlot, slot);
        atomic_store(&_state->sequence, nextSequence);
        atomic_fetch_add(&_state->publishedFrames, 1ULL);
    }
    double waitStart = NowSeconds();
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    atomic_fetch_add(&_state->producerStallNanos, NanosFromSeconds(NowSeconds() - waitStart));

    if (!_sharedEventReady)
    {
        atomic_store(&_state->slotSequences[slot], nextSequence);
        atomic_store(&_state->currentSlot, slot);
        atomic_store(&_state->sequence, nextSequence);
        atomic_fetch_add(&_state->publishedFrames, 1ULL);
    }
    _submittedFrames++;
}

- (NSUInteger)runPhaseNamed:(const char *)phase duration:(double)duration startFrame:(NSUInteger)startFrame csv:(FILE *)csv csvEvery:(NSUInteger)csvEvery
{
    if (duration <= 0.0)
    {
        return 0U;
    }

    double phaseStart = NowSeconds();
    double nextFrameTime = phaseStart;
    NSUInteger phaseFrames = 0U;

    while (gShouldRun)
    {
        double now = NowSeconds();
        if (now - phaseStart >= duration)
        {
            break;
        }

        [self publishFrame];
        phaseFrames++;

        if (csv && (csvEvery <= 1U || (phaseFrames % csvEvery) == 0U))
        {
            fprintf(csv,
                    "%s,%lu,%.9f,%.9f,%llu,%u,%llu,%llu,%llu\n",
                    phase,
                    (unsigned long)(startFrame + phaseFrames),
                    NowSeconds(),
                    NowSeconds() - phaseStart,
                    (unsigned long long)atomic_load(&_state->publishedFrames),
                    (unsigned int)atomic_load(&_state->clientCount),
                    (unsigned long long)atomic_load(&_state->slotDepthFrames),
                    (unsigned long long)atomic_load(&_state->overwrittenFrames),
                    (unsigned long long)atomic_load(&_state->maxConsumerLagFrames));
        }

        if (_fps > 0.0)
        {
            nextFrameTime += 1.0 / _fps;
            double sleepSeconds = nextFrameTime - NowSeconds();
            if (sleepSeconds > 0.0)
            {
                usleep((useconds_t)(sleepSeconds * 1000000.0));
            }
        }
    }

    return phaseFrames;
}

- (NSDictionary *)runWithWarmup:(double)warmup duration:(double)duration waitForClients:(NSUInteger)waitForClients waitTimeout:(double)waitTimeout csvPath:(NSString *)csvPath csvEvery:(NSUInteger)csvEvery
{
    FILE *csv = NULL;
    if (csvPath.length)
    {
        EnsureParentDirectory(csvPath);
        csv = fopen(csvPath.fileSystemRepresentation, "w");
        if (csv)
        {
            fprintf(csv, "phase,frameIndex,hostTimeSeconds,phaseElapsedSeconds,publishedFrameCount,frameClientCount,slotDepthFrames,overwrittenFrames,maxConsumerLagFrames\n");
        }
    }

    double waitSeconds = 0.0;
    BOOL clientsReady = [self waitForFrameClients:waitForClients timeout:waitTimeout actualWait:&waitSeconds];
    double benchmarkStart = NowSeconds();
    NSUInteger warmupFrames = [self runPhaseNamed:"warmup" duration:warmup startFrame:0 csv:csv csvEvery:csvEvery];
    double measuredStart = NowSeconds();
    NSUInteger measuredFrames = [self runPhaseNamed:"measured" duration:duration startFrame:warmupFrames csv:csv csvEvery:csvEvery];
    double measuredElapsed = NowSeconds() - measuredStart;
    double benchmarkElapsed = NowSeconds() - benchmarkStart;

    if (csv)
    {
        fclose(csv);
    }

    NSDictionary *diagnostics = @{
        @"clientCount": @([self frameClientCount]),
        @"publishedFrames": @((unsigned long long)atomic_load(&_state->publishedFrames)),
        @"observedFrames": @((unsigned long long)atomic_load(&_state->observedFrames)),
        @"missedFrames": @((unsigned long long)atomic_load(&_state->missedFrames)),
        @"repeatedReads": @((unsigned long long)atomic_load(&_state->repeatedReads)),
        @"slotDepthFrames": @((unsigned long long)atomic_load(&_state->slotDepthFrames)),
        @"overwrittenFrames": @((unsigned long long)atomic_load(&_state->overwrittenFrames)),
        @"latestConsumerLagFrames": @((unsigned long long)atomic_load(&_state->latestConsumerLagFrames)),
        @"maxConsumerLagFrames": @((unsigned long long)atomic_load(&_state->maxConsumerLagFrames)),
        @"producerStallNanos": @((unsigned long long)atomic_load(&_state->producerStallNanos)),
        @"gpuWaitNanos": @((unsigned long long)atomic_load(&_state->gpuWaitNanos)),
        @"sharedEventSignals": @((unsigned long long)atomic_load(&_state->sharedEventSignals)),
        @"sharedEventWaits": @((unsigned long long)atomic_load(&_state->sharedEventWaits)),
        @"sharedEventTimeouts": @((unsigned long long)atomic_load(&_state->sharedEventTimeouts)),
        @"sharedEventReady": @(_sharedEventReady)
    };

    return @{
        @"transport": @"framebus-metal",
        @"role": @"server",
        @"statePath": _statePath,
        @"width": @(_width),
        @"height": @(_height),
        @"targetFPS": @(_fps),
        @"pixelFormat": _pixelFormatName,
        @"slotCount": @(_slotCount),
        @"colorPrimaries": @"sRGB",
        @"transferFunction": [_pixelFormatName isEqualToString:@"rgba16f"] ? @"linear" : @"sRGB",
        @"alphaMode": @"opaque",
        @"syncMode": _sharedEventReady ? @"shared-event" : @"sequence-poll",
        @"warmupSeconds": @(warmup),
        @"durationSeconds": @(duration),
        @"waitForClients": @(waitForClients),
        @"waitTimeoutSeconds": @(waitTimeout),
        @"waitSeconds": @(waitSeconds),
        @"clientsReady": @(clientsReady),
        @"warmupFrames": @(warmupFrames),
        @"measuredFrames": @(measuredFrames),
        @"measuredElapsedSeconds": @(measuredElapsed),
        @"measuredSubmittedFPS": @(measuredElapsed > 0.0 ? (double)measuredFrames / measuredElapsed : 0.0),
        @"totalSubmittedFrames": @(_submittedFrames),
        @"benchmarkElapsedSeconds": @(benchmarkElapsed),
        @"csvEvery": @(csvEvery),
        @"diagnostics": diagnostics
    };
}
@end

int main(int argc, const char * argv[])
{
    @autoreleasepool
    {
        (void)argc;
        (void)argv;
        signal(SIGINT, HandleSignal);
        signal(SIGTERM, HandleSignal);

        NSArray<NSString *> *arguments = [[NSProcessInfo processInfo] arguments];
        NSString *name = ArgumentValue(arguments, @"--name", @"Syphon Metal Benchmark");
        NSUInteger width = UnsignedArgument(arguments, @"--width", 1920U);
        NSUInteger height = UnsignedArgument(arguments, @"--height", 1080U);
        double fps = DoubleArgument(arguments, @"--fps", 60.0);
        double warmup = DoubleArgument(arguments, @"--warmup", 2.0);
        double duration = DoubleArgument(arguments, @"--duration", 10.0);
        NSUInteger waitForClients = UnsignedArgument(arguments, @"--wait-for-clients", 1U);
        double waitTimeout = DoubleArgument(arguments, @"--wait-timeout", 10.0);
        NSString *pixelFormat = PixelFormatName(ArgumentValue(arguments, @"--pixel-format", @"bgra8"));
        NSString *transport = ArgumentValue(arguments, @"--transport", @"syphon");
        NSString *statePath = ArgumentValue(arguments, @"--state", nil);
        NSString *eventPath = ArgumentValue(arguments, @"--event", nil);
        NSString *syncMode = ArgumentValue(arguments, @"--sync", @"poll");
        NSUInteger slots = UnsignedArgument(arguments, @"--slots", 3U);
        NSUInteger csvEvery = MAX((NSUInteger)1, UnsignedArgument(arguments, @"--csv-every", 1U));
        NSString *summaryPath = ArgumentValue(arguments, @"--summary", nil);
        NSString *csvPath = ArgumentValue(arguments, @"--csv", nil);

        NSDictionary *summary = nil;
        if ([[transport lowercaseString] isEqualToString:@"framebus"])
        {
            FrameBusBenchmarkServerRunner *runner = [[FrameBusBenchmarkServerRunner alloc] initWithStatePath:statePath
                                                                                                    eventPath:eventPath
                                                                                               useSharedEvent:[[syncMode lowercaseString] isEqualToString:@"shared-event"]
                                                                                                        width:width
                                                                                                       height:height
                                                                                                          fps:fps
                                                                                              pixelFormatName:pixelFormat
                                                                                                        slots:slots];
            if (!runner)
            {
                return 1;
            }

            printf("FrameBus benchmark server '%s' %lux%lu %.2f fps %s slots=%lu\n",
                   name.UTF8String,
                   (unsigned long)width,
                   (unsigned long)height,
                   fps,
                   pixelFormat.UTF8String,
                   (unsigned long)slots);

            summary = [runner runWithWarmup:warmup
                                    duration:duration
                              waitForClients:waitForClients
                                 waitTimeout:waitTimeout
                                     csvPath:csvPath
                                    csvEvery:csvEvery];
            [runner stop];
        }
        else
        {
            SyphonMetalBenchmarkServerRunner *runner = [[SyphonMetalBenchmarkServerRunner alloc] initWithName:name
                                                                                                        width:width
                                                                                                       height:height
                                                                                                          fps:fps
                                                                                              pixelFormatName:pixelFormat];
            if (!runner)
            {
                return 1;
            }

            printf("Syphon Metal benchmark server '%s' %lux%lu %.2f fps %s\n",
                   name.UTF8String,
                   (unsigned long)width,
                   (unsigned long)height,
                   fps,
                   pixelFormat.UTF8String);

            summary = [runner runWithWarmup:warmup
                                    duration:duration
                              waitForClients:waitForClients
                                 waitTimeout:waitTimeout
                                     csvPath:csvPath
                                    csvEvery:csvEvery];
            [runner stop];
        }

        if (summaryPath.length && !WriteJSON(summary, summaryPath))
        {
            return 2;
        }
        if (!summaryPath.length)
        {
            NSData *data = [NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingPrettyPrinted error:nil];
            NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            printf("%s\n", json.UTF8String ?: "{}");
        }
    }
    return 0;
}
