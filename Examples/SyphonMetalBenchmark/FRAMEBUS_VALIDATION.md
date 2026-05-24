# FrameBus Validation Notes

FrameBus is currently implemented as an experimental benchmark transport in this directory.

## Transport Shape

- Syphon baseline: `SyphonMetalServer` / `SyphonMetalClient`.
- FrameBus prototype: shared state file plus IOSurface-backed ring slots.
- Frame readiness: shared atomic sequence counters on the hot path.
- Notification coalescing: clients poll the latest sequence and consume latest-ready only; slow consumers do not force one IPC per frame.
- Compatibility wrappers: the benchmark runner exposes `--transport syphon`, `--transport framebus`, and `--transport both` with the same server/client artifact contract.

## Format Negotiation

- Default compatibility format: BGRA8 / `kCVPixelFormatType_32BGRA`.
- HDR/high precision test format: RGBA16F / `kCVPixelFormatType_64RGBAHalf`.
- Metadata carried in the FrameBus header: pixel format, bytes per pixel, color primaries, transfer function, alpha mode.
- Current metadata defaults:
  - BGRA8: sRGB primaries, sRGB transfer, opaque alpha.
  - RGBA16F: sRGB primaries, linear transfer, opaque alpha.
- YCbCr/NV12/P010 are not implemented in the prototype because the current benchmark uses one IOSurface plane per slot. Multi-plane support should be a separate extension with explicit per-plane IOSurface IDs and plane metadata.

## Synchronization

- Default sync: atomic sequence polling.
- Optional sync request: `--sync shared-event`.
- `MTLSharedEvent` creation and GPU signal encoding are availability-gated in code.
- In this local command-line harness, `MTLSharedEventHandle` file archival fails; Apple documents the handle as an XPC-passed object. The runner therefore falls back to sequence polling and records `sharedEventReady=false`.
- GPU/producer timing fields are still recorded:
  - `producerStallNanos`
  - `gpuWaitNanos`
  - `sharedEventSignals`
  - `sharedEventWaits`
  - `sharedEventTimeouts`

## Telemetry

FrameBus summaries include:

- `slotDepthFrames`
- `overwrittenFrames`
- `repeatedReads`
- `missedFrames`
- `latestConsumerLagFrames`
- `maxConsumerLagFrames`
- `producerStallNanos`
- `gpuWaitNanos`

## Bridges

Bridge coverage is represented by compatibility adapters in the benchmark runner:

- `--transport syphon` exercises the existing Syphon server/client contract.
- `--transport framebus` exercises the experimental FrameBus server/client contract.
- `--transport both` runs the same matrix through both transports and writes comparable JSON/CSV artifacts.

The production bridge design should keep OpenGL as an adapter around Syphon compatibility, not as the FrameBus core.
