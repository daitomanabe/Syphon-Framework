# Diagnostics

Inspect lightweight runtime counters for benchmark and profiling workflows.

## Overview

Servers and clients expose a `diagnostics` dictionary containing NSNumber counters. These counters are intentionally lightweight and are intended for comparing transport behavior, not for producing a complete performance trace.

Use diagnostics together with host timestamps, GPU timestamps, and Instruments when evaluating more efficient frame-sharing paths such as Metal-native ring buffers and explicit GPU synchronization.

## Server Keys

- `SyphonDiagnosticsPublishedFrameCountKey`: frame publish operations completed by the server.
- `SyphonDiagnosticsSurfaceCreateCountKey`: IOSurfaces created by the server.
- `SyphonDiagnosticsSurfaceResizeCountKey`: IOSurface replacements caused by size changes.
- `SyphonDiagnosticsSurfaceUpdateCountKey`: surface ID updates sent to clients.
- `SyphonDiagnosticsInfoClientCountKey`: clients registered for server info updates.
- `SyphonDiagnosticsFrameClientCountKey`: clients registered for frame callbacks.
- `SyphonDiagnosticsHasClientsKey`: current has-clients state.
- `SyphonDiagnosticsLastSurfaceIDKey`: last IOSurfaceID published by the server.

## Client Keys

- `SyphonDiagnosticsReceivedFrameNotificationCountKey`: frame notifications received by the client.
- `SyphonDiagnosticsNewSurfaceRequestCountKey`: IOSurface requests made by the client.
- `SyphonDiagnosticsHasNewFrameKey`: current has-new-frame state.
- `SyphonDiagnosticsIsValidKey`: current client validity state.
- `SyphonDiagnosticsLastFrameIDKey`: last frame identifier observed by the client.

## Example

```objc
NSDictionary<NSString *, NSNumber *> *serverDiagnostics = server.diagnostics;
NSLog(@"published frames: %@", serverDiagnostics[SyphonDiagnosticsPublishedFrameCountKey]);

NSDictionary<NSString *, NSNumber *> *clientDiagnostics = client.diagnostics;
NSLog(@"frame notifications: %@", clientDiagnostics[SyphonDiagnosticsReceivedFrameNotificationCountKey]);
```
