# FrameBus Development TODO

Working branch: `codex/framebus-metal-sync-ring`

This list tracks incremental work toward a more efficient, Metal-native frame sharing path while keeping existing Syphon behavior intact.

## Milestone 0: Baseline and Safety

- [x] Clone upstream `Syphon/Syphon-Framework`.
- [x] Create a fork-backed development branch.
- [x] Add a minimal diagnostics snapshot API for servers and clients.
- [x] Add documentation for diagnostic keys and intended benchmark usage.
- [x] Add simple color/depth compatibility test apps.
- [x] Define benchmark matrix: 1920x1080@60, 3840x2160@60, optional 3840x2160@120, optional HDR/float when hardware supports it.
- [x] Define run protocol: warmup seconds, measured seconds, client count, slow-consumer mode, and target FPS.
- [x] Define benchmark artifacts: JSON summary, CSV frame samples, environment metadata, and trace/sample output path.
- [x] Add build/toolchain preflight for Xcode, MetalToolchain, `Syphon.framework`, and benchmark/sample app binaries.
- [x] Add a repeatable benchmark harness for Syphon Metal server/client.
- [x] Capture current Syphon Metal baseline before implementing FrameBus.

## Milestone 1: Metal-Native Ring Buffer Prototype

- [x] Define shared stream and slot metadata.
- [x] Add a Metal-only experimental server path with triple-buffered IOSurface-backed slots.
- [x] Add a Metal-only experimental client path that consumes the latest ready slot.
- [x] Add producer drop and overwrite policy for `latest` mode.
- [x] Add telemetry for slot depth, overwritten frames, repeated frames, and consumer lag.

## Milestone 2: Explicit GPU Synchronization

- [x] Add availability-gated `MTLSharedEvent` support.
- [x] Publish frame readiness as a GPU event value instead of only a CPU callback.
- [x] Add fallback sync for OS/device combinations without shared event support.
- [x] Measure GPU wait time and producer stall time.

## Milestone 3: Notification Coalescing

- [x] Separate discovery/control messages from per-frame hot path.
- [x] Add shared atomic sequence counters for frame availability.
- [x] Coalesce frame wakeups so slow consumers do not force one IPC per frame.
- [x] Preserve current Syphon callback behavior through compatibility wrappers.

## Milestone 4: Format Negotiation

- [x] Keep BGRA8 as the Syphon-compatible fallback.
- [x] Add RGBA16F support for HDR and high-precision pipelines.
- [x] Define color space, transfer function, alpha mode, and timestamp metadata.
- [x] Investigate YCbCr / NV12 / P010 multi-plane support.

## Milestone 5: Compatibility and Migration

- [x] Add a Syphon-to-FrameBus bridge.
- [x] Add a FrameBus-to-Syphon bridge.
- [x] Keep OpenGL compatibility as an adapter, not the core path.
- [x] Document migration strategy for existing Syphon integrations.

## Milestone 6: Validation

- [x] Compare Syphon and FrameBus at 1080p60, 4K60, 4K120, and HDR/float using the Milestone 0 run protocol.
- [x] Test 1, 2, 4, and 8 consumer scenarios.
- [x] Test slow-consumer behavior and dropped frame accounting.
- [x] Verify no CPU readback in the fast path.
- [x] Publish benchmark results and trace captures.

## Notes

- Results and validation notes: `Examples/SyphonMetalBenchmark/FRAMEBUS_RESULTS_20260524.md` and `Examples/SyphonMetalBenchmark/FRAMEBUS_VALIDATION.md`.
- Productionization plan and checklist: `FRAMEBUS_PRODUCTION_TODO.md`.
- The command-line shared-event handoff falls back to atomic sequence polling because `MTLSharedEventHandle` is XPC-oriented; production shared-event handoff should use XPC.
- The current bridge coverage is benchmark-adapter level. Production application bridges should wrap the same FrameBus state/slot contract with app-level discovery and lifecycle management.
