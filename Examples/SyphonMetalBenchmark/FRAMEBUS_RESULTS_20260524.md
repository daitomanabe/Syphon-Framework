# FrameBus Results - 2026-05-24

All runs were executed from `Examples/SyphonMetalBenchmark` with the local `../../build/Release/Syphon.framework`.

## Final Comparison

Artifact: `benchmark-results/final-validation-comparison/manifest.json`

| Run | Transport | Size | Server FPS | Client FPS | Client Frames | Missed | Max Lag |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| 20260524-142500-syphon-1080p60-c1 | Syphon | 1920x1080@60 | 59.98 | 59.97 | 300 | n/a | n/a |
| 20260524-142506-framebus-1080p60-c1 | FrameBus | 1920x1080@60 | 59.95 | 59.99 | 300 | 0 | 0 |
| 20260524-142512-syphon-4k60-c1 | Syphon | 3840x2160@60 | 59.97 | 59.57 | 298 | n/a | n/a |
| 20260524-142519-framebus-4k60-c1 | FrameBus | 3840x2160@60 | 59.94 | 59.78 | 299 | 0 | 0 |

## Throughput

Artifact: `benchmark-results/final-validation-throughput-120/manifest.json`

| Run | Transport | Size | Target FPS | Server FPS | Client FPS | Missed | Max Lag |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| 20260524-142641-syphon-1080pmax-c1 | Syphon | 1920x1080 | max | 576.38 | 572.89 | n/a | n/a |
| 20260524-142646-framebus-1080pmax-c1 | FrameBus | 1920x1080 | max | 5677.71 | 5679.00 | 0 | 0 |
| 20260524-142650-syphon-4kmax-c1 | Syphon | 3840x2160 | max | 472.28 | 471.93 | n/a | n/a |
| 20260524-142654-framebus-4kmax-c1 | FrameBus | 3840x2160 | max | 3214.82 | 3219.00 | 0 | 0 |
| 20260524-142659-syphon-4k120-c1 | Syphon | 3840x2160 | 120 | 119.92 | 119.95 | n/a | n/a |
| 20260524-142703-framebus-4k120-c1 | FrameBus | 3840x2160 | 120 | 119.94 | 120.00 | 0 | 0 |

FrameBus throughput ratios in this run:

- 1920x1080 max: about 9.9x Syphon client FPS.
- 3840x2160 max: about 6.8x Syphon client FPS.

## Fan-Out

Artifacts:

- `benchmark-results/final-validation-fanout-c1/manifest.json`
- `benchmark-results/final-validation-fanout-c2/manifest.json`
- `benchmark-results/final-validation-fanout-c4/manifest.json`
- `benchmark-results/final-validation-fanout-c8/manifest.json`

All FrameBus 1080p60 fan-out runs completed with client/server exit code 0. The minimum observed client FPS stayed near 59.97 FPS for 1, 2, 4, and 8 clients with max missed frames 0.

## Slow Consumer

Artifact: `benchmark-results/final-validation-slow-consumer/manifest.json`

`1080pmax`, one client, `--slow-consumer-ms 5`:

- Server: 5602.98 FPS.
- Client: 151.63 FPS.
- Missed frames: 15210.
- Max consumer lag: 1 frame.

This confirms latest-frame semantics: slow consumers drop old frames instead of applying backpressure to the producer.

## RGBA16F

Artifact: `benchmark-results/final-validation-rgba16f/manifest.json`

`4k60-rgba16f` completed at approximately 59.98 client FPS with 0 missed frames.

## Shared Event Fallback

Artifact: `benchmark-results/final-validation-shared-event/manifest.json`

The `--sync shared-event` run completed, but `MTLSharedEventHandle` file archival failed in this command-line harness, so the run recorded `syncMode=sequence-poll`. The code path is availability-gated and records shared-event metrics; production handoff should use XPC.

## Trace Captures

`sample` traces were captured under:

- `benchmark-results/final-validation-comparison/*/traces/server.sample.txt`
