#!/usr/bin/env python3
import argparse
import json
import os
import platform
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
BENCHMARK_DIR = SCRIPT_DIR.parent
ROOT = BENCHMARK_DIR.parent.parent
FRAMEWORK_DIR = ROOT / "build" / "Release"
SERVER_EXE = BENCHMARK_DIR / "build" / "Syphon Metal Benchmark Server.app" / "Contents" / "MacOS" / "SyphonMetalBenchmarkServer"
CLIENT_EXE = BENCHMARK_DIR / "build" / "Syphon Metal Benchmark Client.app" / "Contents" / "MacOS" / "SyphonMetalBenchmarkClient"

MATRICES = {
    "1080p60": {"width": 1920, "height": 1080, "fps": 60, "pixel_format": "bgra8"},
    "1080pmax": {"width": 1920, "height": 1080, "fps": 0, "pixel_format": "bgra8"},
    "4k60": {"width": 3840, "height": 2160, "fps": 60, "pixel_format": "bgra8"},
    "4kmax": {"width": 3840, "height": 2160, "fps": 0, "pixel_format": "bgra8"},
    "4k120": {"width": 3840, "height": 2160, "fps": 120, "pixel_format": "bgra8"},
    "4k60-rgba16f": {"width": 3840, "height": 2160, "fps": 60, "pixel_format": "rgba16f"},
}


def run_capture(args, env=None):
    try:
        completed = subprocess.run(args, check=False, text=True, capture_output=True, env=env)
        return {
            "command": args,
            "returncode": completed.returncode,
            "stdout": completed.stdout.strip(),
            "stderr": completed.stderr.strip(),
        }
    except FileNotFoundError as exc:
        return {
            "command": args,
            "returncode": 127,
            "stdout": "",
            "stderr": str(exc),
        }


def developer_dir():
    for candidate in ("/Applications/Xcode.app/Contents/Developer", "/Applications/Xcode-beta.app/Contents/Developer"):
        if Path(candidate, "usr/bin/xcodebuild").exists():
            return candidate
    selected = run_capture(["xcode-select", "-p"])
    return selected["stdout"] if selected["returncode"] == 0 else ""


def build_apps(env):
    if not (FRAMEWORK_DIR / "Syphon.framework").is_dir():
        raise RuntimeError(f"Missing Syphon.framework at {FRAMEWORK_DIR / 'Syphon.framework'}")
    subprocess.run(["make", "apps"], cwd=BENCHMARK_DIR, env=env, check=True)


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def terminate_process(process):
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def collect_environment(env):
    metal = run_capture(["xcrun", "--find", "metal"], env=env)
    xcodebuild_version = run_capture(["xcodebuild", "-version"], env=env)
    clang = run_capture(["xcrun", "--find", "clang"], env=env)
    sdk_path = run_capture(["xcrun", "--show-sdk-path"], env=env)
    return {
        "createdAt": datetime.now().isoformat(timespec="seconds"),
        "host": platform.node(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": sys.version,
        "root": str(ROOT),
        "benchmarkDir": str(BENCHMARK_DIR),
        "frameworkDir": str(FRAMEWORK_DIR),
        "developerDir": env.get("DEVELOPER_DIR", ""),
        "preflight": {
            "xcodebuildAvailable": xcodebuild_version["returncode"] == 0,
            "clangAvailable": clang["returncode"] == 0,
            "metalCompilerAvailable": metal["returncode"] == 0,
            "sdkAvailable": sdk_path["returncode"] == 0,
            "frameworkExists": (FRAMEWORK_DIR / "Syphon.framework").is_dir(),
            "serverBinaryExists": SERVER_EXE.exists(),
            "clientBinaryExists": CLIENT_EXE.exists(),
        },
        "xcodebuildVersion": xcodebuild_version,
        "clang": clang,
        "metal": metal,
        "sdkPath": sdk_path,
        "swVers": run_capture(["sw_vers"]),
        "hwModel": run_capture(["sysctl", "-n", "hw.model"]),
        "cpuBrand": run_capture(["sysctl", "-n", "machdep.cpu.brand_string"]),
    }


def parse_matrices(value):
    names = []
    for item in value.split(","):
        name = item.strip()
        if name:
            names.append(name)
    unknown = [name for name in names if name not in MATRICES]
    if unknown:
        raise SystemExit(f"Unknown matrix name(s): {', '.join(unknown)}. Known: {', '.join(sorted(MATRICES))}")
    return names


def parse_transports(value):
    if value == "both":
        return ["syphon", "framebus"]
    names = []
    for item in value.split(","):
        name = item.strip().lower()
        if name:
            names.append(name)
    unknown = [name for name in names if name not in {"syphon", "framebus"}]
    if unknown:
        raise SystemExit(f"Unknown transport name(s): {', '.join(unknown)}. Known: syphon, framebus, both")
    return names


def run_sample(pid, seconds, output_path):
    if seconds <= 0:
        return None
    output_path.parent.mkdir(parents=True, exist_ok=True)
    return run_capture(["sample", str(pid), str(seconds), "-file", str(output_path)])


def run_one(transport, matrix_name, matrix, args, env, base_output):
    run_id = f"{datetime.now().strftime('%Y%m%d-%H%M%S')}-{transport}-{matrix_name}-c{args.clients}"
    run_dir = base_output / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    log_dir = run_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    trace_dir = run_dir / "traces"
    trace_dir.mkdir(parents=True, exist_ok=True)

    server_name = f"Metal Transport Benchmark {run_id}"
    state_path = run_dir / "framebus.state"
    event_path = run_dir / "framebus.event"
    server_summary = run_dir / "server.json"
    server_csv = run_dir / "server.csv"
    server_log = open(log_dir / "server.log", "w", encoding="utf-8")
    server_cmd = [
        str(SERVER_EXE),
        "--name", server_name,
        "--width", str(matrix["width"]),
        "--height", str(matrix["height"]),
        "--fps", str(matrix["fps"]),
        "--pixel-format", matrix["pixel_format"],
        "--transport", transport,
        "--warmup", str(args.warmup),
        "--duration", str(args.duration),
        "--wait-for-clients", str(args.clients),
        "--wait-timeout", str(args.find_timeout),
        "--slots", str(args.slots),
        "--state", str(state_path),
        "--event", str(event_path),
        "--sync", args.sync,
        "--csv-every", str(args.csv_every),
        "--summary", str(server_summary),
        "--csv", str(server_csv),
    ]

    server = subprocess.Popen(server_cmd, stdout=server_log, stderr=subprocess.STDOUT, env=env)
    time.sleep(0.25)

    client_processes = []
    client_logs = []
    for index in range(args.clients):
        client_summary = run_dir / f"client-{index}.json"
        client_csv = run_dir / f"client-{index}.csv"
        client_log = open(log_dir / f"client-{index}.log", "w", encoding="utf-8")
        client_logs.append(client_log)
        client_cmd = [
            str(CLIENT_EXE),
            "--name", server_name,
            "--find-timeout", str(args.find_timeout),
            "--transport", transport,
            "--state", str(state_path),
            "--event", str(event_path),
            "--sync", args.sync,
            "--warmup", str(args.warmup),
            "--duration", str(args.duration),
            "--poll-us", str(args.poll_us),
            "--slow-consumer-ms", str(args.slow_consumer_ms),
            "--csv-every", str(args.csv_every),
            "--summary", str(client_summary),
            "--csv", str(client_csv),
        ]
        client_processes.append({
            "index": index,
            "summary": str(client_summary),
            "csv": str(client_csv),
            "command": client_cmd,
            "process": subprocess.Popen(client_cmd, stdout=client_log, stderr=subprocess.STDOUT, env=env),
        })

    time.sleep(1.0)
    sample_result = run_sample(server.pid, args.sample_seconds, trace_dir / "server.sample.txt")

    timeout = args.find_timeout + args.warmup + args.duration + 15
    statuses = []
    try:
        for item in client_processes:
            process = item["process"]
            try:
                returncode = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                terminate_process(process)
                returncode = process.returncode
            statuses.append({"role": "client", "index": item["index"], "returncode": returncode})

        try:
            server_returncode = server.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            terminate_process(server)
            server_returncode = server.returncode
        statuses.append({"role": "server", "returncode": server_returncode})
    finally:
        terminate_process(server)
        for item in client_processes:
            terminate_process(item["process"])
        server_log.close()
        for handle in client_logs:
            handle.close()

    summary_paths = [server_summary] + [Path(item["summary"]) for item in client_processes]
    summaries = []
    for path in summary_paths:
        if path.exists():
            summaries.append(json.loads(path.read_text(encoding="utf-8")))

    manifest = {
        "runId": run_id,
        "transport": transport,
        "serverName": server_name,
        "matrix": matrix,
        "clients": args.clients,
        "warmupSeconds": args.warmup,
        "durationSeconds": args.duration,
        "slowConsumerMillis": args.slow_consumer_ms,
        "pollMicros": args.poll_us,
        "sync": args.sync,
        "serverCommand": server_cmd,
        "clientCommands": [item["command"] for item in client_processes],
        "statuses": statuses,
        "sample": sample_result,
        "artifacts": {
            "serverSummary": str(server_summary),
            "serverCsv": str(server_csv),
            "clientSummaries": [item["summary"] for item in client_processes],
            "clientCsvs": [item["csv"] for item in client_processes],
            "logs": str(log_dir),
            "traces": str(trace_dir),
            "state": str(state_path) if transport == "framebus" else None,
            "event": str(event_path) if transport == "framebus" else None,
        },
        "summaries": summaries,
    }
    write_json(run_dir / "manifest.json", manifest)
    return manifest


def main():
    parser = argparse.ArgumentParser(description="Run Syphon/FrameBus Metal benchmarks.")
    parser.add_argument("--transport", default="syphon", help="syphon, framebus, both, or comma-separated transport names")
    parser.add_argument("--matrix", default="1080p60", help=f"Comma-separated matrix names. Known: {', '.join(sorted(MATRICES))}")
    parser.add_argument("--clients", type=int, default=1)
    parser.add_argument("--duration", type=float, default=10.0)
    parser.add_argument("--warmup", type=float, default=2.0)
    parser.add_argument("--find-timeout", type=float, default=10.0)
    parser.add_argument("--poll-us", type=int, default=1000)
    parser.add_argument("--slow-consumer-ms", type=float, default=0.0)
    parser.add_argument("--slots", type=int, default=3)
    parser.add_argument("--csv-every", type=int, default=1)
    parser.add_argument("--sync", default="poll", choices=["poll", "shared-event"])
    parser.add_argument("--sample-seconds", type=int, default=0)
    parser.add_argument("--output-dir", default=str(BENCHMARK_DIR / "benchmark-results"))
    parser.add_argument("--no-build", action="store_true")
    args = parser.parse_args()

    if args.clients < 1:
        raise SystemExit("--clients must be >= 1")
    if args.slots < 2:
        raise SystemExit("--slots must be >= 2")
    if args.csv_every < 1:
        raise SystemExit("--csv-every must be >= 1")

    dev_dir = developer_dir()
    env = os.environ.copy()
    if dev_dir:
        env["DEVELOPER_DIR"] = dev_dir

    if not args.no_build:
        build_apps(env)

    if not SERVER_EXE.exists() or not CLIENT_EXE.exists():
        raise SystemExit("Benchmark binaries are missing. Run without --no-build first.")

    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    write_json(output_dir / "environment.json", collect_environment(env))

    manifests = []
    for matrix_name in parse_matrices(args.matrix):
        for transport in parse_transports(args.transport):
            manifests.append(run_one(transport, matrix_name, MATRICES[matrix_name], args, env, output_dir))

    top_manifest = {
        "createdAt": datetime.now().isoformat(timespec="seconds"),
        "outputDir": str(output_dir),
        "runs": [
            {
                "runId": manifest["runId"],
                "transport": manifest["transport"],
                "manifest": str(output_dir / manifest["runId"] / "manifest.json"),
                "statuses": manifest["statuses"],
            }
            for manifest in manifests
        ],
    }
    write_json(output_dir / "manifest.json", top_manifest)
    print(json.dumps(top_manifest, indent=2, sort_keys=True))

    failed = [
        status
        for manifest in manifests
        for status in manifest["statuses"]
        if status.get("returncode") != 0
    ]
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
