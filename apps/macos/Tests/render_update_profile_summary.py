#!/usr/bin/env python3
import argparse
import json
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Summarize terminal render-update performance JSONL logs.")
    parser.add_argument("--performance-log", required=True, help="JSONL file written by SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH.")
    parser.add_argument("--summary-json", help="Optional latency summary JSON from e2e_terminal_latency.sh or e2e_mobile_latency.sh.")
    parser.add_argument("--output-dir", default="apps/macos/.artifacts/terminal-render-profiles")
    parser.add_argument("--render-mode", default="")
    parser.add_argument("--terminal-size", default="")
    parser.add_argument("--sample-count", type=int, default=0)
    parser.add_argument("--warmup-count", type=int, default=0)
    parser.add_argument("--fixture-command", default="")
    parser.add_argument("--network-profile", default="local")
    parser.add_argument("--target", default="")
    parser.add_argument("--baseline-summary", help="Optional earlier render-update summary JSON to compare against.")
    parser.add_argument("--timestamp", default=datetime.now(timezone.utc).isoformat())
    return parser.parse_args()


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def git_output(args: list[str], cwd: Path) -> str:
    try:
        return subprocess.check_output(args, cwd=cwd, text=True, stderr=subprocess.DEVNULL).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unknown"


def load_json_lines(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            records.append({"name": "json_decode_failure", "attributes": {"decode_failed": "1"}})
            continue
        if isinstance(record, dict):
            records.append(record)
    return records


def load_json(path: Path | None) -> dict[str, Any]:
    if path is None or not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def attr(record: dict[str, Any], key: str) -> str | None:
    attributes = record.get("attributes") or {}
    value = attributes.get(key)
    return None if value is None else str(value)


def number(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def int_attr(record: dict[str, Any], key: str) -> int | None:
    value = number(attr(record, key))
    return None if value is None else int(value)


def event_bytes(record: dict[str, Any]) -> int:
    for key in ("network_send_bytes", "payload_bytes", "render_update_bytes", "frame_bytes"):
        value = int_attr(record, key)
        if value is not None:
            return value
    count = number(record.get("count"))
    return int(count or 0)


def percentile(values: list[float], percent: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return round(ordered[0], 3)
    rank = (len(ordered) - 1) * percent
    lower = int(rank)
    upper = min(lower + 1, len(ordered) - 1)
    weight = rank - lower
    return round((ordered[lower] * (1 - weight)) + (ordered[upper] * weight), 3)


def stats(values: list[float]) -> dict[str, Any]:
    return {
        "count": len(values),
        "total": round(sum(values), 3),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "p99": percentile(values, 0.99),
        "avg": round(sum(values) / len(values), 3) if values else None,
        "max": round(max(values), 3) if values else None,
    }


def peak_bytes_per_second(records: list[dict[str, Any]], window_seconds: int) -> int:
    timed = [
        (int(record.get("emittedUptimeNanoseconds") or 0), event_bytes(record))
        for record in records
        if int(record.get("emittedUptimeNanoseconds") or 0) > 0
    ]
    timed = [(timestamp, byte_count) for timestamp, byte_count in sorted(timed) if byte_count > 0]
    if not timed:
        return 0
    window_ns = window_seconds * 1_000_000_000
    left = 0
    running = 0
    peak = 0
    for right, (timestamp, byte_count) in enumerate(timed):
        running += byte_count
        while timestamp - timed[left][0] > window_ns:
            running -= timed[left][1]
            left += 1
        peak = max(peak, running)
    return int(peak / window_seconds)


def latency_values(summary: dict[str, Any]) -> list[float]:
    values: list[float] = []
    for scenario in (summary.get("scenarios") or {}).values():
        for measurement in scenario.get("measurements") or []:
            value = number(measurement.get("visible_latency_ms") or measurement.get("event_to_visible_ms"))
            if value is not None:
                values.append(value)
    return values


def summarize(args: argparse.Namespace, events: list[dict[str, Any]], latency_summary: dict[str, Any]) -> dict[str, Any]:
    network_events = [
        record for record in events
        if record.get("source") == "mobile-bridge" and record.get("name") == "stream_network_send_begin"
    ]
    payload_events = network_events or [
        record for record in events
        if record.get("name") in ("render_frame_payload_publish", "render_frame_payload_receive", "stream_relay_read")
    ]
    frame_events = [
        record for record in events
        if record.get("name") in ("render_frame_export_end", "render_frame_payload_publish")
    ]
    if not frame_events:
        frame_events = payload_events

    total_bytes = sum(event_bytes(record) for record in payload_events)
    render_frame_count = len(frame_events)
    full_frame_count = sum(1 for record in frame_events if (attr(record, "frame_kind") or "full") == "full")
    delta_frame_count = sum(1 for record in frame_events if attr(record, "frame_kind") == "delta")
    resync_frame_count = sum(1 for record in frame_events if attr(record, "frame_kind") == "resync_required")

    encode_ms = [value for record in events for value in [number(attr(record, "frame_encode_ms") or attr(record, "render_update_encode_ms"))] if value is not None]
    decode_ms = [value for record in events for value in [number(attr(record, "decode_ms"))] if value is not None]
    apply_ms = [value for record in events for value in [number(attr(record, "apply_ms"))] if value is not None]
    latency_ms = latency_values(latency_summary)

    dropped_frames = sum(int_attr(record, "dropped_delta_count") or 0 for record in events)
    dropped_frames += sum(1 for record in events if attr(record, "dropped") == "1")
    resync_count = sum(int_attr(record, "resync_count") or 0 for record in events) + resync_frame_count
    decode_failures = sum(1 for record in events if attr(record, "drop_reason") == "decode_failed" or attr(record, "decode_failed") == "1")
    apply_failures = sum(1 for record in events if (attr(record, "drop_reason") or "").endswith("apply_failed"))
    explicit_refresh_count = sum(1 for record in events if record.get("name") == "explicit_state_refresh_begin")

    return {
        "parameters": {
            "timestamp": args.timestamp,
            "git_sha": git_output(["git", "rev-parse", "HEAD"], repo_root()),
            "ghostty_submodule_sha": git_output(["git", "-C", "apps/macos/vendor/ghostty", "rev-parse", "HEAD"], repo_root()),
            "render_mode": args.render_mode or "auto",
            "terminal_size": args.terminal_size or "unknown",
            "sample_count": args.sample_count,
            "warmup_count": args.warmup_count,
            "fixture_command": args.fixture_command,
            "network_profile": args.network_profile,
            "target": args.target or latency_summary.get("suite") or "unknown",
        },
        "artifacts": {
            "performance_log": "",
            "source_summary": str(Path(args.summary_json).resolve()) if args.summary_json else None,
        },
        "metrics": {
            "total_bytes": total_bytes,
            "average_bytes_per_frame": round(total_bytes / render_frame_count, 1) if render_frame_count else 0,
            "peak_1s_bytes_per_second": peak_bytes_per_second(payload_events, 1),
            "peak_10s_bytes_per_second": peak_bytes_per_second(payload_events, 10),
            "full_frame_count": full_frame_count,
            "delta_frame_count": delta_frame_count,
            "resync_frame_count": resync_frame_count,
            "render_frame_count": render_frame_count,
            "output_to_visible_latency_ms": stats(latency_ms),
            "encode_ms": stats(encode_ms),
            "decode_ms": stats(decode_ms),
            "apply_ms": stats(apply_ms),
            "total_encode_decode_apply_ms": round(sum(encode_ms) + sum(decode_ms) + sum(apply_ms), 3),
            "decode_failures": decode_failures,
            "apply_failures": apply_failures,
            "dropped_frames": dropped_frames,
            "resync_count": resync_count,
            "explicit_refresh_count": explicit_refresh_count,
            "operation_count": sum(int_attr(record, "operation_count") or 0 for record in frame_events),
            "changed_cell_count": sum(int_attr(record, "changed_cell_count") or 0 for record in frame_events),
            "scroll_operation_count": sum(int_attr(record, "scroll_operation_count") or 0 for record in frame_events),
            "full_frame_fallback_reasons": sorted(
                {
                    attr(record, "full_frame_fallback_reason")
                    for record in frame_events
                    if attr(record, "full_frame_fallback_reason") not in (None, "", "none")
                }
            ),
        },
    }


def comparison(current: dict[str, Any], baseline: dict[str, Any]) -> dict[str, Any]:
    current_metrics = current.get("metrics") or {}
    baseline_metrics = baseline.get("metrics") or {}

    def ratio(key: str) -> float | None:
        base = number(baseline_metrics.get(key))
        cur = number(current_metrics.get(key))
        if base in (None, 0) or cur is None:
            return None
        return round(cur / base, 4)

    def reduction(key: str) -> float | None:
        value = ratio(key)
        return None if value is None else round(1 - value, 4)

    latency_base = ((baseline_metrics.get("output_to_visible_latency_ms") or {}).get("p95"))
    latency_current = ((current_metrics.get("output_to_visible_latency_ms") or {}).get("p95"))
    latency_delta = None
    if latency_base is not None and latency_current is not None:
        latency_delta = round(float(latency_current) - float(latency_base), 3)

    return {
        "total_bytes_reduction": reduction("total_bytes"),
        "average_bytes_per_frame_reduction": reduction("average_bytes_per_frame"),
        "peak_1s_bytes_per_second_reduction": reduction("peak_1s_bytes_per_second"),
        "peak_10s_bytes_per_second_reduction": reduction("peak_10s_bytes_per_second"),
        "latency_p95_delta_ms": latency_delta,
        "encode_decode_apply_ratio": ratio("total_encode_decode_apply_ms"),
        "compression_ratio": ratio("total_bytes"),
    }


def write_outputs(args: argparse.Namespace, summary: dict[str, Any]) -> Path:
    output_dir = repo_root() / args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    timestamp_slug = args.timestamp.replace(":", "").replace("+", "Z").replace(".", "-")
    mode = (args.render_mode or "auto").replace("/", "-")
    target = (args.target or summary["parameters"]["target"]).replace("/", "-")
    output_path = output_dir / f"render-update-{target}-{mode}-{timestamp_slug}.json"
    log_copy = output_path.with_suffix(".jsonl")
    shutil.copyfile(args.performance_log, log_copy)
    summary["artifacts"]["performance_log"] = str(log_copy)
    output_path.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    return output_path


def fmt(value: Any) -> str:
    if value is None:
        return "n/a"
    return str(value)


def print_table(summary: dict[str, Any], compare: dict[str, Any] | None, output_path: Path) -> None:
    metrics = summary["metrics"]
    rows = [
        ("total bytes", metrics["total_bytes"]),
        ("avg bytes/frame", metrics["average_bytes_per_frame"]),
        ("peak 1s B/s", metrics["peak_1s_bytes_per_second"]),
        ("peak 10s B/s", metrics["peak_10s_bytes_per_second"]),
        ("frames full/delta/resync", f"{metrics['full_frame_count']}/{metrics['delta_frame_count']}/{metrics['resync_frame_count']}"),
        ("latency p50/p95/p99 ms", f"{fmt(metrics['output_to_visible_latency_ms']['p50'])}/{fmt(metrics['output_to_visible_latency_ms']['p95'])}/{fmt(metrics['output_to_visible_latency_ms']['p99'])}"),
        ("encode p50/p95 ms", f"{fmt(metrics['encode_ms']['p50'])}/{fmt(metrics['encode_ms']['p95'])}"),
        ("decode p50/p95 ms", f"{fmt(metrics['decode_ms']['p50'])}/{fmt(metrics['decode_ms']['p95'])}"),
        ("apply p50/p95 ms", f"{fmt(metrics['apply_ms']['p50'])}/{fmt(metrics['apply_ms']['p95'])}"),
        ("failures/drop/resync/refresh", f"{metrics['decode_failures'] + metrics['apply_failures']}/{metrics['dropped_frames']}/{metrics['resync_count']}/{metrics['explicit_refresh_count']}"),
    ]
    width = max(len(label) for label, _ in rows)
    print(f"render update summary: {output_path}")
    for label, value in rows:
        print(f"  {label:<{width}}  {value}")
    if compare:
        print("comparison:")
        for key, value in compare.items():
            print(f"  {key:<34} {fmt(value)}")


def main() -> None:
    args = parse_args()
    events = load_json_lines(Path(args.performance_log))
    latency_summary = load_json(Path(args.summary_json) if args.summary_json else None)
    summary = summarize(args, events, latency_summary)
    compare = None
    if args.baseline_summary:
        baseline = load_json(Path(args.baseline_summary))
        compare = comparison(summary, baseline)
        summary["comparison"] = compare
    output_path = write_outputs(args, summary)
    print_table(summary, compare, output_path)


if __name__ == "__main__":
    main()
