# Simple Syphon Apps

These standalone test apps exercise standard Syphon color publishing plus an optional depth companion stream.

The compatibility model is deliberate:

- `Simple Syphon Server Color` is a normal BGRA8 Syphon stream.
- `Simple Syphon Server Depth` is a companion stream tagged with `SyphonFrameChannelDepth` and `kCVPixelFormatType_DepthFloat32`.
- Existing Syphon clients can keep using the color stream.
- Extended clients can inspect `SyphonServerDescriptionSurfacesKey` and `SyphonSurfaceDescriptionFrameChannelKey` to pair color and depth streams.

## Build

Build `Syphon.framework` first, then build the sample apps:

```sh
cd Examples/SimpleSyphonApps
make framework
make apps
```

If `Syphon.framework` already exists, point the Makefile at it:

```sh
make apps FRAMEWORK_DIR=/path/to/framework/parent
```

The Makefile creates:

- `build/Simple Syphon Server.app`
- `build/Simple Syphon Client.app`

## Run

In one terminal:

```sh
./build/Simple\ Syphon\ Server.app/Contents/MacOS/SimpleSyphonServer
```

In another terminal:

```sh
./build/Simple\ Syphon\ Client.app/Contents/MacOS/SimpleSyphonClient
```

Server options:

```sh
SimpleSyphonServer --name "Simple Syphon Server" --width 1280 --height 720 --fps 60
```

Client options:

```sh
SimpleSyphonClient --color "Simple Syphon Server Color" --depth "Simple Syphon Server Depth"
```

## Notes

The server fills Metal textures from CPU memory to keep the sample deterministic and independent from shader compilation. It is intended for compatibility and diagnostics testing, not as the optimized FrameBus path.
