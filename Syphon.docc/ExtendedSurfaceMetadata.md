# Extended Surface Metadata

Publish optional color/depth companion streams without breaking existing Syphon clients.

## Overview

The default Syphon path remains a BGRA8 color stream. Existing clients can continue to ignore surface metadata and connect as before.

Extended clients can inspect `SyphonServerDescriptionSurfacesKey` for surface metadata:

- `SyphonSurfaceDescriptionFrameChannelKey`: `color`, `depth`, `disparity`, or `auxiliary`.
- `SyphonSurfaceDescriptionPixelFormatKey`: CoreVideo pixel format (`OSType`) used by the IOSurface.
- `SyphonSurfaceDescriptionBytesPerElementKey`: IOSurface bytes per element.

## Depth Companion Streams

Depth should be published as a companion Syphon server instead of replacing the color stream. This keeps the primary color stream compatible with existing Syphon tools.

```objc
NSDictionary *depthOptions = @{
    SyphonServerOptionFrameChannel: SyphonFrameChannelDepth,
    SyphonServerOptionPixelFormat: @(kCVPixelFormatType_DepthFloat32)
};

SyphonMetalServer *depthServer = [[SyphonMetalServer alloc] initWithName:@"Scene Depth"
                                                                  device:device
                                                                 options:depthOptions];
```

When the source texture is `MTLPixelFormatR32Float`, `SyphonMetalServer` allocates an R32Float IOSurface-backed destination texture for the depth stream.

## Compatibility Rules

- Do not change the primary color stream format unless all consumers are known to support it.
- Publish depth, disparity, masks, and auxiliary data as separate named companion streams.
- Tag companion streams with `SyphonServerOptionFrameChannel` so extended clients can discover them without relying only on names.
- Prefer `kCVPixelFormatType_DepthFloat32` for depth in meters.
- Keep BGRA8 as the default fallback for old clients.
