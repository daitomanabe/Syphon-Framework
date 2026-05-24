#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <mach/mach_time.h>
#import <fcntl.h>
#import <signal.h>
#import <stdatomic.h>
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

static NSDictionary *FirstSurface(NSDictionary *serverDescription)
{
    NSArray *surfaces = serverDescription[SyphonServerDescriptionSurfacesKey];
    if (![surfaces isKindOfClass:[NSArray class]] || surfaces.count == 0)
    {
        return nil;
    }
    NSDictionary *surface = surfaces.firstObject;
    return [surface isKindOfClass:[NSDictionary class]] ? surface : nil;
}

static NSString *FrameChannel(NSDictionary *serverDescription)
{
    NSString *channel = FirstSurface(serverDescription)[SyphonSurfaceDescriptionFrameChannelKey];
    return [channel isKindOfClass:[NSString class]] ? channel : SyphonFrameChannelColor;
}

static NSString *PixelFormatLabel(NSDictionary *serverDescription)
{
    NSNumber *pixelFormat = FirstSurface(serverDescription)[SyphonSurfaceDescriptionPixelFormatKey];
    if (![pixelFormat respondsToSelector:@selector(unsignedIntValue)])
    {
        return @"unknown";
    }
    OSType format = pixelFormat.unsignedIntValue;
    char chars[5] = {
        (char)((format >> 24) & 0xff),
        (char)((format >> 16) & 0xff),
        (char)((format >> 8) & 0xff),
        (char)(format & 0xff),
        0
    };
    return [NSString stringWithFormat:@"%s", chars];
}

static NSDictionary *FindServer(NSString *requestedName, NSTimeInterval timeout)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0.0 && gShouldRun)
    {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        NSArray *servers = [[SyphonServerDirectory sharedDirectory] servers];
        for (NSDictionary *server in servers)
        {
            NSString *name = server[SyphonServerDescriptionNameKey];
            if (requestedName.length > 0 && ![name isEqualToString:requestedName])
            {
                continue;
            }
            if ([[FrameChannel(server) lowercaseString] isEqualToString:[SyphonFrameChannelColor lowercaseString]])
            {
                return server;
            }
        }
        usleep(50000);
    }
    return nil;
}

@interface SyphonMetalBenchmarkClientRunner : NSObject
- (instancetype)initWithServerName:(NSString *)serverName findTimeout:(double)findTimeout;
- (NSDictionary *)runWithWarmup:(double)warmup duration:(double)duration pollMicros:(NSUInteger)pollMicros slowConsumerMillis:(double)slowConsumerMillis csvPath:(NSString *)csvPath csvEvery:(NSUInteger)csvEvery;
- (void)stop;
@end

@implementation SyphonMetalBenchmarkClientRunner
{
    NSString *_serverName;
    NSDictionary *_serverDescription;
    id<MTLDevice> _device;
    SyphonMetalClient *_client;
    double _findSeconds;
}

- (instancetype)initWithServerName:(NSString *)serverName findTimeout:(double)findTimeout
{
    self = [super init];
    if (self)
    {
        _serverName = [serverName copy];
        _device = MTLCreateSystemDefaultDevice();
        if (!_device)
        {
            fprintf(stderr, "Metal device is unavailable.\n");
            return nil;
        }

        double findStart = NowSeconds();
        _serverDescription = FindServer(_serverName, findTimeout);
        _findSeconds = NowSeconds() - findStart;
        if (!_serverDescription)
        {
            fprintf(stderr, "Could not find Syphon server '%s'.\n", _serverName.UTF8String);
            return nil;
        }

        _client = [[SyphonMetalClient alloc] initWithServerDescription:_serverDescription
                                                                device:_device
                                                               options:nil
                                                       newFrameHandler:^(SyphonMetalClient *client) {
                                                           (void)client;
                                                       }];
        if (!_client || !_client.isValid)
        {
            fprintf(stderr, "Could not connect to Syphon server '%s'.\n", _serverName.UTF8String);
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
    [_client stop];
    _client = nil;
}

- (NSUInteger)runPhaseNamed:(const char *)phase duration:(double)duration startFrame:(NSUInteger)startFrame pollMicros:(NSUInteger)pollMicros slowConsumerMillis:(double)slowConsumerMillis csv:(FILE *)csv csvEvery:(NSUInteger)csvEvery
{
    if (duration <= 0.0)
    {
        return 0U;
    }

    double phaseStart = NowSeconds();
    NSUInteger observedFrames = 0U;
    useconds_t slowConsumerMicros = (useconds_t)MAX(0.0, slowConsumerMillis * 1000.0);
    useconds_t idlePollMicros = (useconds_t)MAX((NSUInteger)100, pollMicros);

    while (gShouldRun)
    {
        @autoreleasepool
        {
            double now = NowSeconds();
            if (now - phaseStart >= duration)
            {
                break;
            }

            BOOL observed = NO;
            if (_client.hasNewFrame)
            {
                id<MTLTexture> texture = [_client newFrameImage];
                observedFrames++;
                observed = YES;

                if (csv && (csvEvery <= 1U || (observedFrames % csvEvery) == 0U))
                {
                    NSDictionary *diagnostics = _client.diagnostics ?: @{};
                    NSNumber *notifications = diagnostics[SyphonDiagnosticsReceivedFrameNotificationCountKey] ?: @0;
                    NSNumber *surfaceRequests = diagnostics[SyphonDiagnosticsNewSurfaceRequestCountKey] ?: @0;
                    NSNumber *lastFrameID = diagnostics[SyphonDiagnosticsLastFrameIDKey] ?: @0;
                    fprintf(csv,
                            "%s,%lu,%.9f,%.9f,%lu,%lu,%lu,%lu,%lu\n",
                            phase,
                            (unsigned long)(startFrame + observedFrames),
                            NowSeconds(),
                            NowSeconds() - phaseStart,
                            (unsigned long)(texture ? texture.width : 0U),
                            (unsigned long)(texture ? texture.height : 0U),
                            (unsigned long)notifications.unsignedIntegerValue,
                            (unsigned long)surfaceRequests.unsignedIntegerValue,
                            (unsigned long)lastFrameID.unsignedIntegerValue);
                }
            }

            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
            if (observed && slowConsumerMicros > 0)
            {
                usleep(slowConsumerMicros);
            }
            else
            {
                usleep(idlePollMicros);
            }
        }
    }

    return observedFrames;
}

- (NSDictionary *)runWithWarmup:(double)warmup duration:(double)duration pollMicros:(NSUInteger)pollMicros slowConsumerMillis:(double)slowConsumerMillis csvPath:(NSString *)csvPath csvEvery:(NSUInteger)csvEvery
{
    FILE *csv = NULL;
    if (csvPath.length)
    {
        EnsureParentDirectory(csvPath);
        csv = fopen(csvPath.fileSystemRepresentation, "w");
        if (csv)
        {
            fprintf(csv, "phase,observedFrameIndex,hostTimeSeconds,phaseElapsedSeconds,textureWidth,textureHeight,receivedFrameNotificationCount,newSurfaceRequestCount,lastFrameID\n");
        }
    }

    double benchmarkStart = NowSeconds();
    NSUInteger warmupFrames = [self runPhaseNamed:"warmup" duration:warmup startFrame:0 pollMicros:pollMicros slowConsumerMillis:slowConsumerMillis csv:csv csvEvery:csvEvery];
    double measuredStart = NowSeconds();
    NSUInteger measuredFrames = [self runPhaseNamed:"measured" duration:duration startFrame:warmupFrames pollMicros:pollMicros slowConsumerMillis:slowConsumerMillis csv:csv csvEvery:csvEvery];
    double measuredElapsed = NowSeconds() - measuredStart;
    double benchmarkElapsed = NowSeconds() - benchmarkStart;

    if (csv)
    {
        fclose(csv);
    }

    NSDictionary *diagnostics = _client.diagnostics ?: @{};
    return @{
        @"transport": @"syphon-metal",
        @"role": @"client",
        @"serverName": _serverName,
        @"serverChannel": FrameChannel(_serverDescription),
        @"serverPixelFormat": PixelFormatLabel(_serverDescription),
        @"findSeconds": @(_findSeconds),
        @"warmupSeconds": @(warmup),
        @"durationSeconds": @(duration),
        @"pollMicros": @(pollMicros),
        @"slowConsumerMillis": @(slowConsumerMillis),
        @"warmupObservedFrames": @(warmupFrames),
        @"measuredObservedFrames": @(measuredFrames),
        @"measuredElapsedSeconds": @(measuredElapsed),
        @"measuredObservedFPS": @(measuredElapsed > 0.0 ? (double)measuredFrames / measuredElapsed : 0.0),
        @"benchmarkElapsedSeconds": @(benchmarkElapsed),
        @"csvEvery": @(csvEvery),
        @"diagnostics": diagnostics
    };
}
@end

static MTLPixelFormat FrameBusMetalPixelFormatForCVPixelFormat(OSType pixelFormat)
{
    if (pixelFormat == kCVPixelFormatType_64RGBAHalf)
    {
        return MTLPixelFormatRGBA16Float;
    }
    return MTLPixelFormatBGRA8Unorm;
}

static NSString *OSTypeLabel(OSType format)
{
    char chars[5] = {
        (char)((format >> 24) & 0xff),
        (char)((format >> 16) & 0xff),
        (char)((format >> 8) & 0xff),
        (char)(format & 0xff),
        0
    };
    return [NSString stringWithFormat:@"%s", chars];
}

@interface FrameBusBenchmarkClientRunner : NSObject
- (instancetype)initWithStatePath:(NSString *)statePath eventPath:(NSString *)eventPath useSharedEvent:(BOOL)useSharedEvent findTimeout:(double)findTimeout;
- (NSDictionary *)runWithWarmup:(double)warmup duration:(double)duration pollMicros:(NSUInteger)pollMicros slowConsumerMillis:(double)slowConsumerMillis csvPath:(NSString *)csvPath csvEvery:(NSUInteger)csvEvery;
- (void)stop;
@end

@implementation FrameBusBenchmarkClientRunner
{
    NSString *_statePath;
    id<MTLDevice> _device;
    FrameBusSharedState *_state;
    int _stateFD;
    IOSurfaceRef _surfaces[FRAMEBUS_MAX_SLOTS];
    id<MTLTexture> _textures[FRAMEBUS_MAX_SLOTS];
    uint64_t _lastSequence;
    double _findSeconds;
    BOOL _registered;
    NSUInteger _clientIndex;
    NSString *_eventPath;
    BOOL _useSharedEvent;
    BOOL _sharedEventReady;
    id<MTLSharedEvent> _sharedEvent;
}

- (instancetype)initWithStatePath:(NSString *)statePath eventPath:(NSString *)eventPath useSharedEvent:(BOOL)useSharedEvent findTimeout:(double)findTimeout
{
    self = [super init];
    if (self)
    {
        _statePath = [statePath copy];
        _eventPath = [eventPath copy];
        _useSharedEvent = useSharedEvent;
        _stateFD = -1;
        _clientIndex = NSNotFound;
        if (!_statePath.length)
        {
            fprintf(stderr, "FrameBus client requires --state.\n");
            return nil;
        }

        _device = MTLCreateSystemDefaultDevice();
        if (!_device)
        {
            fprintf(stderr, "Metal device is unavailable.\n");
            return nil;
        }

        double findStart = NowSeconds();
        while (gShouldRun && NowSeconds() - findStart < findTimeout)
        {
            _stateFD = open(_statePath.fileSystemRepresentation, O_RDWR, 0600);
            if (_stateFD >= 0)
            {
                break;
            }
            usleep(10000);
        }
        if (_stateFD < 0)
        {
            perror("open framebus state");
            return nil;
        }

        _state = mmap(NULL, sizeof(FrameBusSharedState), PROT_READ | PROT_WRITE, MAP_SHARED, _stateFD, 0);
        if (_state == MAP_FAILED)
        {
            perror("mmap framebus state");
            _state = NULL;
            return nil;
        }

        while (gShouldRun && NowSeconds() - findStart < findTimeout)
        {
            if (_state->magic == FRAMEBUS_MAGIC && _state->version == FRAMEBUS_VERSION && _state->slotCount > 0U)
            {
                break;
            }
            usleep(10000);
        }
        _findSeconds = NowSeconds() - findStart;

        if (_state->magic != FRAMEBUS_MAGIC || _state->version != FRAMEBUS_VERSION || _state->slotCount == 0U)
        {
            fprintf(stderr, "FrameBus state was not initialized.\n");
            return nil;
        }

        MTLPixelFormat metalPixelFormat = FrameBusMetalPixelFormatForCVPixelFormat(_state->pixelFormat);
        for (NSUInteger index = 0; index < _state->slotCount && index < FRAMEBUS_MAX_SLOTS; index++)
        {
            _surfaces[index] = IOSurfaceLookup(_state->surfaceIDs[index]);
            if (!_surfaces[index])
            {
                fprintf(stderr, "Could not look up FrameBus IOSurface slot %lu.\n", (unsigned long)index);
                return nil;
            }
            MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:metalPixelFormat
                                                                                                  width:_state->width
                                                                                                 height:_state->height
                                                                                              mipmapped:NO];
            descriptor.usage = MTLTextureUsageShaderRead;
            _textures[index] = [_device newTextureWithDescriptor:descriptor iosurface:_surfaces[index] plane:0];
            if (!_textures[index])
            {
                fprintf(stderr, "Could not create FrameBus texture slot %lu.\n", (unsigned long)index);
                return nil;
            }
        }

        _lastSequence = atomic_load(&_state->sequence);
        for (NSUInteger index = 0; index < FRAMEBUS_MAX_CLIENTS; index++)
        {
            uint32_t expected = 0U;
            if (atomic_compare_exchange_strong(&_state->clientActive[index], &expected, 1U))
            {
                _clientIndex = index;
                atomic_store(&_state->clientSequences[index], _lastSequence);
                atomic_fetch_add(&_state->clientCount, 1U);
                _registered = YES;
                break;
            }
        }
        if (!_registered)
        {
            fprintf(stderr, "No free FrameBus client slot.\n");
            return nil;
        }

        if (_useSharedEvent && (_state->flags & 1U) && _eventPath.length)
        {
            if (@available(macOS 10.14, *))
            {
                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:findTimeout];
                NSData *eventData = nil;
                while ([deadline timeIntervalSinceNow] > 0.0 && gShouldRun)
                {
                    eventData = [NSData dataWithContentsOfFile:_eventPath];
                    if (eventData.length > 0)
                    {
                        break;
                    }
                    usleep(10000);
                }
                if (eventData.length > 0)
                {
                    NSError *unarchiveError = nil;
                    MTLSharedEventHandle *handle = [NSKeyedUnarchiver unarchivedObjectOfClass:[MTLSharedEventHandle class] fromData:eventData error:&unarchiveError];
                    if (!handle)
                    {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                        handle = [NSKeyedUnarchiver unarchiveObjectWithData:eventData];
#pragma clang diagnostic pop
                    }
                    if (handle)
                    {
                        _sharedEvent = [_device newSharedEventWithHandle:handle];
                        _sharedEventReady = _sharedEvent != nil;
                    }
                    if (!_sharedEventReady && unarchiveError)
                    {
                        fprintf(stderr, "Shared event unarchive failed: %s\n", unarchiveError.localizedDescription.UTF8String);
                    }
                }
            }
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
    if (_state && _registered)
    {
        atomic_fetch_sub(&_state->clientCount, 1U);
        if (_clientIndex != NSNotFound && _clientIndex < FRAMEBUS_MAX_CLIENTS)
        {
            atomic_store(&_state->clientActive[_clientIndex], 0U);
        }
        _registered = NO;
    }
    uint32_t slotCount = _state ? _state->slotCount : 0U;
    for (NSUInteger index = 0; index < slotCount && index < FRAMEBUS_MAX_SLOTS; index++)
    {
        _textures[index] = nil;
        if (_surfaces[index])
        {
            CFRelease(_surfaces[index]);
            _surfaces[index] = NULL;
        }
    }
    if (_state)
    {
        munmap(_state, sizeof(FrameBusSharedState));
        _state = NULL;
    }
    if (_stateFD >= 0)
    {
        close(_stateFD);
        _stateFD = -1;
    }
}

- (NSUInteger)runPhaseNamed:(const char *)phase duration:(double)duration startFrame:(NSUInteger)startFrame pollMicros:(NSUInteger)pollMicros slowConsumerMillis:(double)slowConsumerMillis csv:(FILE *)csv csvEvery:(NSUInteger)csvEvery
{
    if (duration <= 0.0)
    {
        return 0U;
    }

    double phaseStart = NowSeconds();
    NSUInteger observedFrames = 0U;
    useconds_t slowConsumerMicros = (useconds_t)MAX(0.0, slowConsumerMillis * 1000.0);

    while (gShouldRun)
    {
        double now = NowSeconds();
        if (now - phaseStart >= duration)
        {
            break;
        }

        uint64_t sequence = atomic_load(&_state->sequence);
        BOOL observed = NO;
        if (sequence != _lastSequence)
        {
            if (sequence > _lastSequence + 1ULL)
            {
                atomic_fetch_add(&_state->missedFrames, sequence - _lastSequence - 1ULL);
            }
            if (_sharedEventReady)
            {
                if (@available(macOS 12.0, *))
                {
                    double waitStart = NowSeconds();
                    BOOL signaled = [_sharedEvent waitUntilSignaledValue:sequence timeoutMS:1000];
                    atomic_fetch_add(&_state->gpuWaitNanos, NanosFromSeconds(NowSeconds() - waitStart));
                    atomic_fetch_add(&_state->sharedEventWaits, 1ULL);
                    if (!signaled)
                    {
                        atomic_fetch_add(&_state->sharedEventTimeouts, 1ULL);
                    }
                }
            }
            _lastSequence = sequence;
            observedFrames++;
            observed = YES;
            atomic_fetch_add(&_state->observedFrames, 1ULL);
            if (_clientIndex != NSNotFound && _clientIndex < FRAMEBUS_MAX_CLIENTS)
            {
                atomic_store(&_state->clientSequences[_clientIndex], sequence);
            }
            uint64_t published = atomic_load(&_state->publishedFrames);
            uint64_t lag = published > sequence ? published - sequence : 0ULL;
            atomic_store(&_state->latestConsumerLagFrames, lag);
            AtomicMaxUInt64(&_state->maxConsumerLagFrames, lag);

            uint32_t slot = atomic_load(&_state->currentSlot);
            id<MTLTexture> texture = slot < FRAMEBUS_MAX_SLOTS ? _textures[slot] : nil;
            if (csv && (csvEvery <= 1U || (observedFrames % csvEvery) == 0U))
            {
                fprintf(csv,
                        "%s,%lu,%.9f,%.9f,%lu,%lu,%llu,%llu,%llu,%llu\n",
                        phase,
                        (unsigned long)(startFrame + observedFrames),
                        NowSeconds(),
                        NowSeconds() - phaseStart,
                        (unsigned long)(texture ? texture.width : 0U),
                        (unsigned long)(texture ? texture.height : 0U),
                        (unsigned long long)sequence,
                        (unsigned long long)atomic_load(&_state->publishedFrames),
                        (unsigned long long)atomic_load(&_state->missedFrames),
                        (unsigned long long)lag);
            }
        }
        else
        {
            atomic_fetch_add(&_state->repeatedReads, 1ULL);
        }

        if (observed && slowConsumerMicros > 0)
        {
            usleep(slowConsumerMicros);
        }
        else if (pollMicros > 0U)
        {
            usleep((useconds_t)pollMicros);
        }
    }

    return observedFrames;
}

- (NSDictionary *)runWithWarmup:(double)warmup duration:(double)duration pollMicros:(NSUInteger)pollMicros slowConsumerMillis:(double)slowConsumerMillis csvPath:(NSString *)csvPath csvEvery:(NSUInteger)csvEvery
{
    FILE *csv = NULL;
    if (csvPath.length)
    {
        EnsureParentDirectory(csvPath);
        csv = fopen(csvPath.fileSystemRepresentation, "w");
        if (csv)
        {
            fprintf(csv, "phase,observedFrameIndex,hostTimeSeconds,phaseElapsedSeconds,textureWidth,textureHeight,sequence,publishedFrameCount,missedFrames,consumerLagFrames\n");
        }
    }

    double benchmarkStart = NowSeconds();
    NSUInteger warmupFrames = [self runPhaseNamed:"warmup" duration:warmup startFrame:0 pollMicros:pollMicros slowConsumerMillis:slowConsumerMillis csv:csv csvEvery:csvEvery];
    double measuredStart = NowSeconds();
    NSUInteger measuredFrames = [self runPhaseNamed:"measured" duration:duration startFrame:warmupFrames pollMicros:pollMicros slowConsumerMillis:slowConsumerMillis csv:csv csvEvery:csvEvery];
    double measuredElapsed = NowSeconds() - measuredStart;
    double benchmarkElapsed = NowSeconds() - benchmarkStart;

    if (csv)
    {
        fclose(csv);
    }

    NSDictionary *diagnostics = @{
        @"clientCount": @((unsigned int)atomic_load(&_state->clientCount)),
        @"publishedFrames": @((unsigned long long)atomic_load(&_state->publishedFrames)),
        @"observedFrames": @((unsigned long long)atomic_load(&_state->observedFrames)),
        @"missedFrames": @((unsigned long long)atomic_load(&_state->missedFrames)),
        @"repeatedReads": @((unsigned long long)atomic_load(&_state->repeatedReads)),
        @"lastSequence": @((unsigned long long)_lastSequence),
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
        @"role": @"client",
        @"statePath": _statePath,
        @"width": @(_state->width),
        @"height": @(_state->height),
        @"serverPixelFormat": OSTypeLabel(_state->pixelFormat),
        @"colorPrimaries": @"sRGB",
        @"transferFunction": _state->transferFunction == FRAMEBUS_TRANSFER_LINEAR ? @"linear" : @"sRGB",
        @"alphaMode": @"opaque",
        @"syncMode": _sharedEventReady ? @"shared-event" : @"sequence-poll",
        @"findSeconds": @(_findSeconds),
        @"warmupSeconds": @(warmup),
        @"durationSeconds": @(duration),
        @"pollMicros": @(pollMicros),
        @"slowConsumerMillis": @(slowConsumerMillis),
        @"warmupObservedFrames": @(warmupFrames),
        @"measuredObservedFrames": @(measuredFrames),
        @"measuredElapsedSeconds": @(measuredElapsed),
        @"measuredObservedFPS": @(measuredElapsed > 0.0 ? (double)measuredFrames / measuredElapsed : 0.0),
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
        double findTimeout = DoubleArgument(arguments, @"--find-timeout", 10.0);
        double warmup = DoubleArgument(arguments, @"--warmup", 2.0);
        double duration = DoubleArgument(arguments, @"--duration", 10.0);
        NSUInteger pollMicros = UnsignedArgument(arguments, @"--poll-us", 1000U);
        double slowConsumerMillis = DoubleArgument(arguments, @"--slow-consumer-ms", 0.0);
        NSString *transport = ArgumentValue(arguments, @"--transport", @"syphon");
        NSString *statePath = ArgumentValue(arguments, @"--state", nil);
        NSString *eventPath = ArgumentValue(arguments, @"--event", nil);
        NSString *syncMode = ArgumentValue(arguments, @"--sync", @"poll");
        NSUInteger csvEvery = MAX((NSUInteger)1, UnsignedArgument(arguments, @"--csv-every", 1U));
        NSString *summaryPath = ArgumentValue(arguments, @"--summary", nil);
        NSString *csvPath = ArgumentValue(arguments, @"--csv", nil);

        NSDictionary *summary = nil;
        if ([[transport lowercaseString] isEqualToString:@"framebus"])
        {
            FrameBusBenchmarkClientRunner *runner = [[FrameBusBenchmarkClientRunner alloc] initWithStatePath:statePath
                                                                                                   eventPath:eventPath
                                                                                              useSharedEvent:[[syncMode lowercaseString] isEqualToString:@"shared-event"]
                                                                                                 findTimeout:findTimeout];
            if (!runner)
            {
                return 1;
            }

            summary = [runner runWithWarmup:warmup
                                    duration:duration
                                  pollMicros:pollMicros
                          slowConsumerMillis:slowConsumerMillis
                                     csvPath:csvPath
                                    csvEvery:csvEvery];
            [runner stop];
        }
        else
        {
            SyphonMetalBenchmarkClientRunner *runner = [[SyphonMetalBenchmarkClientRunner alloc] initWithServerName:name findTimeout:findTimeout];
            if (!runner)
            {
                return 1;
            }

            summary = [runner runWithWarmup:warmup
                                    duration:duration
                                  pollMicros:pollMicros
                          slowConsumerMillis:slowConsumerMillis
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
