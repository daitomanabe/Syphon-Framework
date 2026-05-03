# FrameBus Development TODO

Working branch: `codex/framebus-metal-sync-ring`

This list tracks incremental work toward a more efficient, Metal-native frame sharing path while keeping existing Syphon behavior intact.

## Milestone 0: Baseline and Safety

- [x] Clone upstream `Syphon/Syphon-Framework`.
- [x] Create a fork-backed development branch.
- [x] Add a minimal diagnostics snapshot API for servers and clients.
- [x] Add documentation for diagnostic keys and intended benchmark usage.
- [ ] Add a repeatable benchmark harness for Syphon Metal server/client.

## Milestone 1: Metal-Native Ring Buffer Prototype

- [ ] Define shared stream and slot metadata.
- [ ] Add a Metal-only experimental server path with triple-buffered IOSurface-backed slots.
- [ ] Add a Metal-only experimental client path that consumes the latest ready slot.
- [ ] Add producer drop and overwrite policy for `latest` mode.
- [ ] Add telemetry for slot depth, overwritten frames, repeated frames, and consumer lag.

## Milestone 2: Explicit GPU Synchronization

- [ ] Add availability-gated `MTLSharedEvent` support.
- [ ] Publish frame readiness as a GPU event value instead of only a CPU callback.
- [ ] Add fallback sync for OS/device combinations without shared event support.
- [ ] Measure GPU wait time and producer stall time.

## Milestone 3: Notification Coalescing

- [ ] Separate discovery/control messages from per-frame hot path.
- [ ] Add shared atomic sequence counters for frame availability.
- [ ] Coalesce frame wakeups so slow consumers do not force one IPC per frame.
- [ ] Preserve current Syphon callback behavior through compatibility wrappers.

## Milestone 4: Format Negotiation

- [ ] Keep BGRA8 as the Syphon-compatible fallback.
- [ ] Add RGBA16F support for HDR and high-precision pipelines.
- [ ] Define color space, transfer function, alpha mode, and timestamp metadata.
- [ ] Investigate YCbCr / NV12 / P010 multi-plane support.

## Milestone 5: Compatibility and Migration

- [ ] Add a Syphon-to-FrameBus bridge.
- [ ] Add a FrameBus-to-Syphon bridge.
- [ ] Keep OpenGL compatibility as an adapter, not the core path.
- [ ] Document migration strategy for existing Syphon integrations.

## Milestone 6: Validation

- [ ] Compare Syphon and FrameBus at 1080p60, 4K60, 4K120, and HDR/float.
- [ ] Test 1, 2, 4, and 8 consumer scenarios.
- [ ] Test slow-consumer behavior and dropped frame accounting.
- [ ] Verify no CPU readback in the fast path.
- [ ] Publish benchmark results and trace captures.
