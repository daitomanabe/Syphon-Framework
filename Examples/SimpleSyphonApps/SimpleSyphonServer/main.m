#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <signal.h>
#import <unistd.h>
#import <Syphon/Syphon.h>

static volatile sig_atomic_t gShouldRun = 1;

static void HandleSignal(int signalNumber)
{
    (void)signalNumber;
    gShouldRun = 0;
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

@interface SimpleSyphonServerRunner : NSObject
- (instancetype)initWithName:(NSString *)name width:(NSUInteger)width height:(NSUInteger)height fps:(double)fps;
- (void)run;
@end

@implementation SimpleSyphonServerRunner
{
    NSString *_name;
    NSUInteger _width;
    NSUInteger _height;
    double _fps;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLTexture> _colorTexture;
    id<MTLTexture> _depthTexture;
    SyphonMetalServer *_colorServer;
    SyphonMetalServer *_depthServer;
    uint8_t *_colorBytes;
    float *_depthBytes;
    NSUInteger _frameIndex;
}

- (instancetype)initWithName:(NSString *)name width:(NSUInteger)width height:(NSUInteger)height fps:(double)fps
{
    self = [super init];
    if (self)
    {
        _name = [name copy];
        _width = width;
        _height = height;
        _fps = fps > 0.0 ? fps : 60.0;
        _device = MTLCreateSystemDefaultDevice();
        _commandQueue = [_device newCommandQueue];
        if (!_device || !_commandQueue)
        {
            fprintf(stderr, "Metal device or command queue is unavailable.\n");
            return nil;
        }

        MTLTextureDescriptor *colorDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:_width height:_height mipmapped:NO];
        colorDescriptor.usage = MTLTextureUsageShaderRead;
        colorDescriptor.storageMode = MTLStorageModeShared;
        _colorTexture = [_device newTextureWithDescriptor:colorDescriptor];

        MTLTextureDescriptor *depthDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:_width height:_height mipmapped:NO];
        depthDescriptor.usage = MTLTextureUsageShaderRead;
        depthDescriptor.storageMode = MTLStorageModeShared;
        _depthTexture = [_device newTextureWithDescriptor:depthDescriptor];

        _colorBytes = calloc(_width * _height * 4U, sizeof(uint8_t));
        _depthBytes = calloc(_width * _height, sizeof(float));
        if (!_colorTexture || !_depthTexture || !_colorBytes || !_depthBytes)
        {
            fprintf(stderr, "Could not allocate textures or staging buffers.\n");
            return nil;
        }

        NSDictionary *colorOptions = @{SyphonServerOptionFrameChannel: SyphonFrameChannelColor};
        NSDictionary *depthOptions = @{
            SyphonServerOptionFrameChannel: SyphonFrameChannelDepth,
            SyphonServerOptionPixelFormat: @(kCVPixelFormatType_DepthFloat32)
        };
        _colorServer = [[SyphonMetalServer alloc] initWithName:[_name stringByAppendingString:@" Color"] device:_device options:colorOptions];
        _depthServer = [[SyphonMetalServer alloc] initWithName:[_name stringByAppendingString:@" Depth"] device:_device options:depthOptions];
        if (!_colorServer || !_depthServer)
        {
            fprintf(stderr, "Could not start Syphon servers.\n");
            return nil;
        }
    }
    return self;
}

- (void)dealloc
{
    [_colorServer stop];
    [_depthServer stop];
    free(_colorBytes);
    free(_depthBytes);
}

- (void)fillFrames
{
    float t = (float)_frameIndex / (float)_fps;
    for (NSUInteger y = 0; y < _height; y++)
    {
        for (NSUInteger x = 0; x < _width; x++)
        {
            float u = (float)x / (float)MAX((NSUInteger)1, _width - 1U);
            float v = (float)y / (float)MAX((NSUInteger)1, _height - 1U);
            uint8_t r = (uint8_t)(127.5f + 127.5f * sinf((u * 8.0f) + t));
            uint8_t g = (uint8_t)(127.5f + 127.5f * sinf((v * 8.0f) - t * 1.3f));
            uint8_t b = (uint8_t)(127.5f + 127.5f * sinf(((u + v) * 6.0f) + t * 0.7f));
            NSUInteger colorIndex = (y * _width + x) * 4U;
            _colorBytes[colorIndex + 0U] = b;
            _colorBytes[colorIndex + 1U] = g;
            _colorBytes[colorIndex + 2U] = r;
            _colorBytes[colorIndex + 3U] = 255U;

            float depthMeters = 1.0f + 0.75f * (0.5f + 0.5f * sinf((u * 10.0f) + (v * 4.0f) + t));
            _depthBytes[y * _width + x] = depthMeters;
        }
    }
}

- (void)publishFrame
{
    [self fillFrames];

    MTLRegion region = MTLRegionMake2D(0, 0, _width, _height);
    [_colorTexture replaceRegion:region mipmapLevel:0 withBytes:_colorBytes bytesPerRow:_width * 4U];
    [_depthTexture replaceRegion:region mipmapLevel:0 withBytes:_depthBytes bytesPerRow:_width * sizeof(float)];

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    [_colorServer publishFrameTexture:_colorTexture onCommandBuffer:commandBuffer imageRegion:NSMakeRect(0, 0, _width, _height) flipped:NO];
    [_depthServer publishFrameTexture:_depthTexture onCommandBuffer:commandBuffer imageRegion:NSMakeRect(0, 0, _width, _height) flipped:NO];
    [commandBuffer commit];
    _frameIndex++;
}

- (void)run
{
    printf("Publishing '%s Color' and '%s Depth' at %lux%lu %.2f fps. Press Ctrl-C to stop.\n",
           _name.UTF8String, _name.UTF8String, (unsigned long)_width, (unsigned long)_height, _fps);
    useconds_t sleepMicros = (useconds_t)MAX(1000.0, 1000000.0 / _fps);
    while (gShouldRun)
    {
        @autoreleasepool
        {
            [self publishFrame];
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
        }
        usleep(sleepMicros);
    }
}
@end

int main(int argc, const char * argv[])
{
    @autoreleasepool
    {
        signal(SIGINT, HandleSignal);
        signal(SIGTERM, HandleSignal);

        NSArray<NSString *> *arguments = [[NSProcessInfo processInfo] arguments];
        NSString *name = ArgumentValue(arguments, @"--name", @"Simple Syphon Server");
        NSUInteger width = (NSUInteger)[ArgumentValue(arguments, @"--width", @"1280") integerValue];
        NSUInteger height = (NSUInteger)[ArgumentValue(arguments, @"--height", @"720") integerValue];
        double fps = [ArgumentValue(arguments, @"--fps", @"60") doubleValue];

        SimpleSyphonServerRunner *runner = [[SimpleSyphonServerRunner alloc] initWithName:name width:width height:height fps:fps];
        if (!runner)
        {
            return 1;
        }
        [runner run];
    }
    return 0;
}
