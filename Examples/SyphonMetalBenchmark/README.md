# Syphon Metal Benchmark

This benchmark captures the current Syphon Metal server/client baseline before FrameBus work changes the transport.

The hot path avoids CPU texture readback. The server publishes a prefilled Metal texture through `SyphonMetalServer`, and clients observe new frames through `SyphonMetalClient` without calling `getBytes`.

## Build

```sh
cd Examples/SyphonMetalBenchmark
make apps
```

The Makefile uses the local `../../build/Release/Syphon.framework` by default. Override `FRAMEWORK_DIR` if needed.

## Run

```sh
python3 scripts/run_benchmark.py --matrix 1080p60 --duration 10 --warmup 2 --clients 1
```

Compare Syphon and the experimental FrameBus transport:

```sh
python3 scripts/run_benchmark.py --transport both --matrix 1080p60,4k60 --duration 10 --warmup 2 --clients 1
python3 scripts/run_benchmark.py --transport both --matrix 1080pmax,4kmax --duration 3 --warmup 1 --clients 1 --poll-us 0 --csv-every 100
```

## Protocol

Baseline comparisons use:

- matrices: `1080p60`, `4k60`, optional `4k120`, optional `4k60-rgba16f`; `1080pmax` and `4kmax` are unthrottled throughput runs
- warmup: 2 seconds by default
- measured duration: 10 seconds by default
- clients: 1 by default; repeat with 2, 4, and 8 for fan-out behavior
- slow consumer: `--slow-consumer-ms` injects per-frame client delay
- no CPU texture readback in the measured hot path

The experimental FrameBus path uses a shared state file plus IOSurface-backed ring slots. It is a benchmark transport, not a production API surface yet.

Artifacts are written under `benchmark-results/`:

- `environment.json`
- one JSON summary per server/client process
- one CSV frame-sample file per server/client process
- `manifest.json`
- optional `traces/` output when `--sample-seconds` is set

Use the same protocol for Syphon and FrameBus comparisons.
