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
    OSType format = [pixelFormat unsignedIntValue];
    char chars[5] = {
        (char)((format >> 24) & 0xff),
        (char)((format >> 16) & 0xff),
        (char)((format >> 8) & 0xff),
        (char)(format & 0xff),
        0
    };
    return [NSString stringWithFormat:@"%s", chars];
}

static NSDictionary *FindServer(NSString *requestedName, NSString *channel)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
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
            if ([[FrameChannel(server) lowercaseString] isEqualToString:[channel lowercaseString]])
            {
                return server;
            }
        }
        usleep(100000);
    }
    return nil;
}

static void LogTextureSample(NSString *label, id<MTLTexture> texture)
{
    if (!texture)
    {
        printf("%s: no texture\n", label.UTF8String);
        return;
    }

    MTLRegion center = MTLRegionMake2D(texture.width / 2U, texture.height / 2U, 1U, 1U);
    @try
    {
        if (texture.pixelFormat == MTLPixelFormatR32Float)
        {
            float depth = 0.0f;
            [texture getBytes:&depth bytesPerRow:sizeof(float) fromRegion:center mipmapLevel:0];
            printf("%s: %lux%lu R32Float center=%.4fm\n", label.UTF8String, (unsigned long)texture.width, (unsigned long)texture.height, depth);
        }
        else
        {
            uint8_t bgra[4] = {};
            [texture getBytes:bgra bytesPerRow:4U fromRegion:center mipmapLevel:0];
            printf("%s: %lux%lu fmt=%lu center BGRA=(%u,%u,%u,%u)\n",
                   label.UTF8String,
                   (unsigned long)texture.width,
                   (unsigned long)texture.height,
                   (unsigned long)texture.pixelFormat,
                   bgra[0], bgra[1], bgra[2], bgra[3]);
        }
    }
    @catch (NSException *exception)
    {
        printf("%s: could not read texture sample: %s\n", label.UTF8String, exception.reason.UTF8String);
    }
}

int main(int argc, const char * argv[])
{
    @autoreleasepool
    {
        (void)argc;
        (void)argv;
        signal(SIGINT, HandleSignal);
        signal(SIGTERM, HandleSignal);

        NSArray<NSString *> *arguments = [[NSProcessInfo processInfo] arguments];
        NSString *colorName = ArgumentValue(arguments, @"--color", @"Simple Syphon Server Color");
        NSString *depthName = ArgumentValue(arguments, @"--depth", @"Simple Syphon Server Depth");

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device)
        {
            fprintf(stderr, "Metal device is unavailable.\n");
            return 1;
        }

        NSDictionary *colorDescription = FindServer(colorName, SyphonFrameChannelColor);
        NSDictionary *depthDescription = FindServer(depthName, SyphonFrameChannelDepth);
        if (!colorDescription)
        {
            fprintf(stderr, "Could not find color server '%s'.\n", colorName.UTF8String);
            return 2;
        }

        printf("Color server: %s channel=%s pixelFormat=%s\n",
               [colorDescription[SyphonServerDescriptionNameKey] UTF8String],
               FrameChannel(colorDescription).UTF8String,
               PixelFormatLabel(colorDescription).UTF8String);
        if (depthDescription)
        {
            printf("Depth server: %s channel=%s pixelFormat=%s\n",
                   [depthDescription[SyphonServerDescriptionNameKey] UTF8String],
                   FrameChannel(depthDescription).UTF8String,
                   PixelFormatLabel(depthDescription).UTF8String);
        }
        else
        {
            printf("Depth server '%s' was not found; continuing color-only.\n", depthName.UTF8String);
        }

        SyphonMetalClient *colorClient = [[SyphonMetalClient alloc] initWithServerDescription:colorDescription device:device options:nil newFrameHandler:nil];
        SyphonMetalClient *depthClient = depthDescription ? [[SyphonMetalClient alloc] initWithServerDescription:depthDescription device:device options:nil newFrameHandler:nil] : nil;
        if (!colorClient || !colorClient.isValid)
        {
            fprintf(stderr, "Could not connect to color server.\n");
            return 3;
        }

        NSUInteger frameIndex = 0;
        while (gShouldRun)
        {
            @autoreleasepool
            {
                id<MTLTexture> colorTexture = [colorClient newFrameImage];
                id<MTLTexture> depthTexture = [depthClient newFrameImage];
                if ((frameIndex % 30U) == 0U)
                {
                    LogTextureSample(@"color", colorTexture);
                    LogTextureSample(@"depth", depthTexture);
                    printf("color diagnostics: %s\n", colorClient.diagnostics.description.UTF8String);
                    if (depthClient)
                    {
                        printf("depth diagnostics: %s\n", depthClient.diagnostics.description.UTF8String);
                    }
                }
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
                frameIndex++;
            }
            usleep(16666);
        }

        [colorClient stop];
        [depthClient stop];
    }
    return 0;
}
