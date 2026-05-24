# FrameBus Productionization Plan

This checklist promotes the current benchmark transport into a production-quality, Metal-native frame sharing path while preserving existing Syphon compatibility.

Current status:

- Prototype location: `Examples/SyphonMetalBenchmark`.
- Baseline result: FrameBus is faster than Syphon in max-throughput benchmark runs, while fixed 60/120 FPS runs reach target on both transports.
- Current limitation: the prototype uses benchmark-local shared state and global IOSurface IDs. It is not yet a framework API.
- Current sync limitation: `MTLSharedEvent` creation is implemented, but command-line file handoff falls back to atomic sequence polling. Production handoff should use XPC.

## Production Goals

- Keep existing `SyphonMetalServer`, `SyphonMetalClient`, `SyphonOpenGLServer`, and `SyphonOpenGLClient` behavior source-compatible.
- Add a Metal-first transport that avoids per-frame IPC and CPU texture readback in the fast path.
- Support latest-frame semantics for live visuals: slow consumers drop old frames instead of slowing producers.
- Provide explicit telemetry for dropped frames, repeated reads, consumer lag, GPU waits, and producer stalls.
- Keep BGRA8 as the default compatibility format, with RGBA16F/HDR as an opt-in format.

## Non-Goals For First Production Cut

- Do not remove OpenGL Syphon compatibility.
- Do not make FrameBus the default transport until app-level compatibility tests pass.
- Do not require all existing Syphon clients to understand FrameBus.
- Do not implement multi-plane YCbCr/P010 as part of the first public API unless a real production app needs it immediately.

## Milestone 1: Framework API Shape

- [ ] Add public Objective-C classes for the new transport:
  - `SyphonFrameBusMetalServer`
  - `SyphonFrameBusMetalClient`
  - `SyphonFrameBusFrame`
  - `SyphonFrameBusStreamDescription`
- [ ] Keep the benchmark structs private; expose immutable Objective-C descriptions instead of raw shared memory structs.
- [ ] Add Swift-friendly nullability annotations and lightweight generics to all new public headers.
- [ ] Add public options:
  - stream name
  - privacy mode
  - pixel format
  - color primaries
  - transfer function
  - alpha mode
  - ring slot count
  - sync mode preference
  - latest-frame versus bounded-latency policy
- [ ] Add explicit availability gates for `MTLSharedEvent` and newer IOSurface/XPC APIs.
- [ ] Add new public headers to the Xcode project, module map, umbrella header, and exported symbols.
- [ ] Document that FrameBus is Metal-native and that OpenGL compatibility is provided through adapters.

## Milestone 2: Control Plane And Discovery

- [ ] Add a production `SyphonFrameBusConnectionManager` separate from the existing Syphon CFMessage connection manager.
- [ ] Keep discovery and lifecycle messages off the per-frame hot path.
- [ ] Use XPC or a private per-user control channel to exchange:
  - stream metadata
  - IOSurface references or secure lookup handles
  - `MTLSharedEventHandle`
  - client registration and retirement
  - stream retirement
- [ ] Replace benchmark-local state file discovery with per-stream lifecycle management owned by the framework.
- [ ] Ensure every stream has a stable UUID, name, app name, and transport capabilities dictionary.
- [ ] Add cleanup for crashed producers and consumers.
- [ ] Add timeout handling for stale client registrations.
- [ ] Preserve existing `SyphonServerDirectory` behavior and add FrameBus capability metadata without breaking old clients.

## Milestone 3: Secure Shared Memory And IOSurface Handoff

- [ ] Move `FrameBusSharedState` into a private framework header with a versioned ABI.
- [ ] Replace world-discoverable benchmark state paths with per-user, permission-limited storage or XPC-provided shared memory.
- [ ] Stop relying on deprecated global IOSurface handoff for production FrameBus where a secure XPC/IOSurface object handoff is available.
- [ ] Add compatibility fallback for systems that only support global IOSurface IDs, guarded by availability and explicit diagnostics.
- [ ] Validate stream header size, version, pixel format, slot count, and surface dimensions before accepting a stream.
- [ ] Add bounds checks for slot and client counts.
- [ ] Add robust cleanup for IOSurface, Metal texture, shared event, and mmap/shared memory lifetime.
- [ ] Add fuzz-style validation tests for malformed stream headers and stale handles.

## Milestone 4: GPU Synchronization And Slot Safety

- [ ] Use `MTLSharedEvent` for producer-ready signaling when available.
- [ ] Pass `MTLSharedEventHandle` through XPC rather than file archiving.
- [ ] Add a sequence-poll fallback for systems without shared event support.
- [ ] Track one ready sequence per slot.
- [ ] Track producer command-buffer completion separately from client consumption.
- [ ] Prevent producer writes into a slot that is still in use by a consumer GPU command buffer.
- [ ] Define the all-slots-busy policy:
  - latest mode: skip publishing a new frame or overwrite only a proven-safe slot
  - bounded-latency mode: wait up to a configured budget, then drop
- [ ] Add client-side GPU wait and timeout telemetry.
- [ ] Add producer-side stall telemetry.
- [ ] Add tests for fast producer, slow consumer, client disconnect during GPU work, and producer shutdown during client wait.

## Milestone 5: Format Negotiation

- [ ] Keep BGRA8/sRGB/opaque as the default Syphon-compatible path.
- [ ] Promote RGBA16F/linear metadata from the benchmark into public stream descriptions.
- [ ] Add explicit rejection paths for unsupported pixel formats.
- [ ] Add color metadata fields:
  - color primaries
  - transfer function
  - matrix coefficients when relevant
  - alpha mode
  - content light metadata when HDR workflows require it
- [ ] Add CVPixelBuffer and CVMetalTextureCache interoperability tests for supported formats.
- [ ] Decide whether NV12/P010 multi-plane support is required for the first production release.
- [ ] If multi-plane support is required, add per-plane IOSurface metadata and per-plane Metal texture creation.

## Milestone 6: Compatibility Bridges

- [ ] Add a Syphon-to-FrameBus bridge that republishes an existing Syphon Metal stream as FrameBus.
- [ ] Add a FrameBus-to-Syphon bridge that republishes FrameBus as standard Syphon BGRA8.
- [ ] Keep bridge apps and adapters outside the core hot path.
- [ ] Preserve existing Syphon callback behavior for compatibility wrappers.
- [ ] Add tests where old Syphon clients consume a FrameBus source through the bridge.
- [ ] Add tests where FrameBus clients consume an old Syphon source through the bridge.
- [ ] Add clear diagnostics when a bridge introduces format conversion or copy cost.

## Milestone 7: Diagnostics And Instrumentation

- [ ] Add public diagnostics snapshots for FrameBus server and client objects.
- [ ] Include:
  - published frames
  - observed frames
  - missed frames
  - repeated reads
  - overwritten frames
  - current lag
  - max lag
  - slot depth
  - producer stall time
  - GPU wait time
  - sync fallback reason
  - active client count
- [ ] Add signposts for publish, acquire, wait, drop, overwrite, and retire events.
- [ ] Add a sample/instruments run profile to the benchmark artifact set.
- [ ] Add a debug environment variable to force fallback sync and fallback IOSurface handoff.

## Milestone 8: Tests And CI

- [ ] Add unit tests for stream description validation.
- [ ] Add unit tests for ring slot selection and overwrite policy.
- [ ] Add unit tests for client registration, retirement, timeout, and crash cleanup.
- [ ] Add integration tests for one producer with 1, 2, 4, 8, and 16 clients.
- [ ] Add slow-consumer integration tests.
- [ ] Add format tests for BGRA8 and RGBA16F.
- [ ] Add no-CPU-readback regression checks using sample traces.
- [ ] Add Xcode scheme coverage for framework, benchmark apps, and bridge apps.
- [ ] Add CI-friendly smoke tests that skip GPU-only tests when Metal is unavailable.

## Milestone 9: Benchmark Gates

- [ ] Keep the current Syphon and FrameBus benchmark harness as a release gate.
- [ ] Required benchmark matrix:
  - 1920x1080@60 BGRA8
  - 3840x2160@60 BGRA8
  - 3840x2160@120 BGRA8 when display/GPU supports it
  - 3840x2160@60 RGBA16F
  - 1920x1080 max throughput
  - 3840x2160 max throughput
- [ ] Required fan-out matrix: 1, 2, 4, 8, and 16 clients.
- [ ] Required slow-consumer matrix: 1 ms, 5 ms, and 16 ms consumer delay.
- [ ] Release gate: fixed FPS tests must not regress versus Syphon.
- [ ] Release gate: max-throughput tests should remain materially faster than Syphon on the same machine.
- [ ] Release gate: no CPU readback symbols in the fast path.
- [ ] Release gate: no producer backpressure in latest-frame mode unless all slots are busy and unsafe to overwrite.

## Milestone 10: Documentation And Migration

- [ ] Add DocC pages for FrameBus concepts and API usage.
- [ ] Add sample code for Swift/AppKit/Metal producers and consumers.
- [ ] Add Objective-C sample code matching existing Syphon examples.
- [ ] Add migration notes:
  - keep Syphon for broad compatibility
  - use FrameBus for local Metal-native low-latency pipelines
  - use bridges when crossing old/new app boundaries
- [ ] Document sandboxing, entitlements, and XPC requirements.
- [ ] Document known fallback modes and their performance impact.
- [ ] Document how to compare local results with the benchmark artifacts.

## First Implementation Slice

The smallest production-oriented slice should be:

- [ ] Add private framework transport files by moving the benchmark `FrameBusSharedState` and ring logic into framework-private classes.
- [ ] Add `SyphonFrameBusMetalServer` and `SyphonFrameBusMetalClient` as opt-in public classes.
- [ ] Add XPC handoff for `MTLSharedEventHandle` and IOSurface references.
- [ ] Keep sequence polling as a fallback and expose the fallback reason in diagnostics.
- [ ] Add BGRA8 only for the first API pass.
- [ ] Run existing Syphon baseline plus FrameBus fixed 1080p60/4K60 and max-throughput benchmarks.
- [ ] Add a FrameBus-to-Syphon bridge after the native FrameBus API is stable.
