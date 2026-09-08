#!/usr/bin/env python3
"""Renders a markdown performance report for one iOS performance baseline lane run.

Reads a run root produced by apps/macos/Tests/e2e_mobile_baseline.sh:
- device-perf.jsonl: the app's own performance events plus the lane markers the UI test and
  the runner append into the same stream (source "ios-uitest" / "lane-runner", name
  "lane_marker").
- shaper.jsonl: the shaping proxy's own log (profile, connection, and byte-accounting events).
- sessions.json: {"target": {"kind": "local"|"remote", "host": ...}, "scenarios": [...]}.

and prints one markdown report to stdout (header plus the cold-open table) while writing the
full report to <run root>/report.md.

This script only measures; it never judges pass or fail. A run root missing one or more of its
three input files still produces a report (each missing file is called out in the header and
every metric that needed it degrades to "n/a" or "no data" rather than raising), so a partial or
interrupted run is still readable.
"""

import argparse
import json
import math
import re
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROFILES = ["good", "constrained", "poor"]

# Fixed report/section order, matching the lane contract's marker list.
SCENARIOS = [
    "cold-open",
    "back-and-forth",
    "keyboard",
    "streaming",
    "scrollback",
    "background-terminal",
    "background-list",
    "reconnect",
    "idle",
]

ISO8601_PATTERN = re.compile(
    r"^(?P<y>\d{4})-(?P<mo>\d{2})-(?P<d>\d{2})T(?P<h>\d{2}):(?P<mi>\d{2}):(?P<s>\d{2})"
    r"(?:\.(?P<frac>\d+))?(?P<tz>Z|[+-]\d{2}:?\d{2})?$"
)


def parse_iso8601(value):
    """Parses an ISO 8601 timestamp with 'Z' or an offset and any fractional-second width.

    Python's stdlib `datetime.fromisoformat` did not accept 'Z' or variable-width fractional
    seconds until 3.11, and this script runs under whatever python3 the developer machine has,
    so it parses the format by hand instead of assuming 3.11. Returns None for anything that
    does not match rather than raising, matching this report's "missing data degrades" contract.
    """
    if not value:
        return None
    match = ISO8601_PATTERN.match(value.strip())
    if not match:
        return None
    fractional = match.group("frac") or "0"
    microsecond = int((fractional + "000000")[:6])
    tz = match.group("tz")
    if tz in (None, "Z"):
        tzinfo = timezone.utc
    else:
        sign = 1 if tz[0] == "+" else -1
        digits = tz[1:].replace(":", "")
        hours = int(digits[0:2])
        minutes = int(digits[2:4]) if len(digits) >= 4 else 0
        tzinfo = timezone(sign * timedelta(hours=hours, minutes=minutes))
    return datetime(
        int(match.group("y")),
        int(match.group("mo")),
        int(match.group("d")),
        int(match.group("h")),
        int(match.group("mi")),
        int(match.group("s")),
        microsecond,
        tzinfo=tzinfo,
    )


def iter_jsonl(path: Path):
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            yield json.loads(raw_line)
        except json.JSONDecodeError:
            continue


def numeric(value):
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def percentile(values, pct):
    """Nearest-rank percentile: rank = ceil(pct/100 * n), clamped into [1, n]."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, min(len(ordered), math.ceil(pct / 100 * len(ordered))))
    return ordered[rank - 1]


def stats(values):
    values = [v for v in values if v is not None]
    if not values:
        return {"n": 0, "p50": None, "p95": None, "max": None}
    return {"n": len(values), "p50": percentile(values, 50), "p95": percentile(values, 95), "max": max(values)}


def numeric_sort_key(value):
    """Sorts marker attribute values (iteration/cycle/index/burst, always small integers stored
    as strings) numerically when possible, falling back to lexical order for anything else."""
    try:
        return (0, int(value))
    except (TypeError, ValueError):
        return (1, str(value))


def fmt_num(value, decimals=1):
    return "n/a" if value is None else f"{value:.{decimals}f}"


def fmt_count(value):
    return "n/a" if value is None else str(int(value))


def fmt_str(value):
    return value if value else "n/a"


fmt_ms = fmt_num
fmt_kb = fmt_num


def markdown_table(headers, rows):
    if not rows:
        return "n/a"
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(headers)) + " |"]
    for row in rows:
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------


def event_time(event):
    if not event:
        return None
    return parse_iso8601(event.get("emittedAt") or event.get("at"))


def event_uptime_ns(event):
    try:
        return int(event["emittedUptimeNanoseconds"])
    except (KeyError, TypeError, ValueError):
        return None


def attr(event, key):
    if not event:
        return None
    return (event.get("attributes") or {}).get(key)


def event_elapsed_ms(event):
    return numeric(event.get("elapsedMS")) if event else None


def is_marker(event):
    return event.get("name") == "lane_marker"


def load_device_events(run_root: Path):
    events = list(iter_jsonl(run_root / "device-perf.jsonl"))
    events.sort(key=lambda e: event_time(e) or datetime.min.replace(tzinfo=timezone.utc))
    return events


def load_shaper_events(run_root: Path):
    events = list(iter_jsonl(run_root / "shaper.jsonl"))
    events.sort(key=lambda e: event_time(e) or datetime.min.replace(tzinfo=timezone.utc))
    return events


def load_sessions(run_root: Path):
    path = run_root / "sessions.json"
    if not path.exists():
        return {"target": None, "scenarios": []}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"target": None, "scenarios": []}
    if not isinstance(data, dict):
        return {"target": None, "scenarios": []}
    data.setdefault("target", None)
    data.setdefault("scenarios", [])
    return data


# ---------------------------------------------------------------------------
# Scenario windows
# ---------------------------------------------------------------------------


@dataclass
class ScenarioWindow:
    profile: str
    scenario: str
    begin: "datetime"
    end: "datetime"
    source: str  # "test" (ios-uitest scenario_begin/end) or "runner" (lane-runner fallback)
    app_events: list = field(default_factory=list)
    app_events_by_uptime: list = field(default_factory=list)
    markers: dict = field(default_factory=dict)  # marker name -> list of lane_marker events
    shaper_bytes: list = field(default_factory=list)  # shaper "bytes" events within [begin, end]
    # The app_launch closest to (at or before) this window's end, searched across the WHOLE run
    # rather than scoped to [begin, end]: whether the test writes its scenario_begin marker before
    # or after the app finishes launching is not specified by the lane contract, and app_launch
    # fires from deep inside app startup, so pinning the search to the window risks silently
    # missing it. Searching the whole run and taking the latest one at-or-before window.end is
    # correct under either ordering, since each scenario's own launch is definitionally the most
    # recent one before that scenario's window closes (scenarios run strictly one at a time).
    app_launch_event: dict = None


def marker(window, name):
    events = window.markers.get(name) if window else None
    return events[0] if events else None


def markers_keyed(window, name, key_attr):
    result = {}
    for event in (window.markers.get(name) if window else None) or []:
        key = attr(event, key_attr)
        if key is not None:
            result[key] = event
    return result


def build_scenario_windows(device_events, shaper_events):
    test_begin, test_end, runner_begin, runner_end = {}, {}, {}, {}
    for event in device_events:
        if not is_marker(event):
            continue
        attrs = event.get("attributes") or {}
        profile, scenario, marker_name = attrs.get("profile"), attrs.get("scenario"), attrs.get("marker")
        if not profile or not scenario or not marker_name:
            continue
        at = event_time(event)
        if at is None:
            continue
        key = (profile, scenario)
        source = event.get("source")
        if source == "ios-uitest" and marker_name == "scenario_begin":
            test_begin.setdefault(key, at)
        elif source == "ios-uitest" and marker_name == "scenario_end":
            test_end[key] = at
        elif source == "lane-runner" and marker_name == "runner_scenario_start":
            runner_begin.setdefault(key, at)
        elif source == "lane-runner" and marker_name == "runner_scenario_finish":
            runner_end[key] = at

    all_app_launches = sorted(
        (e for e in device_events if e.get("name") == "app_launch" and event_time(e) is not None), key=event_time
    )

    windows = {}
    for profile in PROFILES:
        for scenario in SCENARIOS:
            key = (profile, scenario)
            if key in test_begin and key in test_end:
                begin, end, source = test_begin[key], test_end[key], "test"
            elif key in runner_begin and key in runner_end:
                begin, end, source = runner_begin[key], runner_end[key], "runner"
            else:
                windows[key] = None
                continue

            window = ScenarioWindow(profile=profile, scenario=scenario, begin=begin, end=end, source=source)
            for event in device_events:
                if is_marker(event):
                    continue
                at = event_time(event)
                if at is not None and begin <= at <= end:
                    window.app_events.append(event)
            window.app_events_by_uptime = sorted(
                (e for e in window.app_events if event_uptime_ns(e) is not None), key=event_uptime_ns
            )
            for event in device_events:
                if not is_marker(event):
                    continue
                attrs = event.get("attributes") or {}
                if attrs.get("profile") != profile or attrs.get("scenario") != scenario:
                    continue
                window.markers.setdefault(attrs.get("marker"), []).append(event)
            for marker_list in window.markers.values():
                marker_list.sort(key=lambda e: event_time(e) or begin)
            window.shaper_bytes = [
                s
                for s in shaper_events
                if s.get("event") == "bytes" and event_time(s) is not None and begin <= event_time(s) <= end
            ]
            candidates = [launch for launch in all_app_launches if event_time(launch) <= end]
            window.app_launch_event = candidates[-1] if candidates else None
            windows[key] = window
    return windows


# ---------------------------------------------------------------------------
# Shared metric helpers
# ---------------------------------------------------------------------------


def first_named(events, name, predicate=None):
    for event in events:
        if event.get("name") != name:
            continue
        if predicate is not None and not predicate(event):
            continue
        return event
    return None


def first_named_any(events, names, predicate=None):
    """Like `first_named`, but matches any of `names`: whichever name occurs first in `events`
    wins, rather than searching for one name and only falling back to the next on a total miss."""
    for event in events:
        if event.get("name") not in names:
            continue
        if predicate is not None and not predicate(event):
            continue
        return event
    return None


def first_after_uptime(events_by_uptime, after_ns, names, predicate=None):
    for event in events_by_uptime:
        ns = event_uptime_ns(event)
        if ns is None or (after_ns is not None and ns < after_ns):
            continue
        if event.get("name") not in names:
            continue
        if predicate is not None and not predicate(event):
            continue
        return event
    return None


def uptime_delta_ms(event_a, event_b):
    ns_a, ns_b = event_uptime_ns(event_a), event_uptime_ns(event_b)
    if ns_a is None or ns_b is None:
        return None
    return (ns_b - ns_a) / 1_000_000.0


def wall_delta_ms(event_a, event_b):
    at_a, at_b = event_time(event_a), event_time(event_b)
    if at_a is None or at_b is None:
        return None
    return (at_b - at_a).total_seconds() * 1000.0


def render_frames_in_wall_range(app_events, start_t, end_t):
    if start_t is None or end_t is None:
        return []
    return [
        e
        for e in app_events
        if e.get("name") == "render_frame_payload_receive"
        and attr(e, "render_update") == "1"
        and event_time(e) is not None
        and start_t <= event_time(e) <= end_t
    ]


def decoded_kb(frames):
    return sum((numeric(e.get("count")) or 0) for e in frames) / 1024.0


def shaper_bytes_in_range(window, start_t, end_t, direction):
    if start_t is None or end_t is None:
        return 0.0
    return sum(
        (numeric(s.get(direction)) or 0)
        for s in window.shaper_bytes
        if event_time(s) is not None and start_t <= event_time(s) <= end_t
    )


def shaper_kb(window, direction):
    return shaper_bytes_in_range(window, window.begin, window.end, direction) / 1024.0


# ---------------------------------------------------------------------------
# Per-scenario metrics: each function takes the scenario's ScenarioWindow (or None for "no
# data") and returns a small dict of raw values; rendering (formatting, table layout) happens
# separately in the render_* section below.
# ---------------------------------------------------------------------------


def metric_cold_open(window):
    if window is None:
        return None
    overview_ok = None
    if window.app_launch_event is not None:
        overview_ok = first_after_uptime(
            window.app_events_by_uptime,
            event_uptime_ns(window.app_launch_event),
            ("overview_refresh_end",),
            predicate=lambda e: attr(e, "success") == "1",
        )
    launch_to_list_ms = uptime_delta_ms(window.app_launch_event, overview_ok) if overview_ok is not None else None

    open_tap = marker(window, "open_tap")
    first_paint = first_named(window.app_events, "terminal_first_paint")
    open_to_paint_ms = wall_delta_ms(open_tap, first_paint) if open_tap and first_paint else None

    def render_frames(start_ns, end_ns):
        return [
            e
            for e in window.app_events_by_uptime
            if e.get("name") == "render_frame_payload_receive"
            and attr(e, "render_update") == "1"
            and start_ns <= event_uptime_ns(e) <= end_ns
        ]

    # The frames that make up the open itself (every full frame between the open beginning and the
    # first paint) are the cost a user waits for; the 3 s after the paint show what the open still
    # pays once the screen is already up (resize round trips, duplicate frames).
    frames_to_paint, kb_to_paint, frames_3s, kb_3s = None, None, None, None
    open_begin = first_named(window.app_events, "terminal_open_begin")
    if first_paint is not None and event_uptime_ns(first_paint) is not None:
        paint_ns = event_uptime_ns(first_paint)
        if open_begin is not None and event_uptime_ns(open_begin) is not None:
            frames = render_frames(event_uptime_ns(open_begin), paint_ns)
            frames_to_paint, kb_to_paint = len(frames), decoded_kb(frames)
        frames = render_frames(paint_ns + 1, paint_ns + 3_000_000_000)
        frames_3s, kb_3s = len(frames), decoded_kb(frames)

    return {
        "launch_to_list_ms": launch_to_list_ms,
        "open_to_paint_ms": open_to_paint_ms,
        "paint_elapsed_ms": event_elapsed_ms(first_paint),
        "hold_released_by": attr(first_paint, "hold_released_by"),
        "frames_to_paint": frames_to_paint,
        "decoded_kb_to_paint": kb_to_paint,
        "frames_3s": frames_3s,
        "decoded_kb_3s": kb_3s,
        "wire_kb_down": shaper_kb(window, "down"),
    }


def metric_back_and_forth(window):
    if window is None:
        return None
    open_taps = markers_keyed(window, "open_tap", "iteration")
    back_taps = markers_keyed(window, "back_tap", "iteration")
    first_paints = sorted(
        (e for e in window.app_events if e.get("name") == "terminal_first_paint"),
        key=lambda e: event_time(e) or window.begin,
    )

    open_to_paint, frames_per_reopen, kb_per_reopen = [], [], []
    paint_cursor = 0
    for iteration in sorted(open_taps, key=numeric_sort_key):
        open_tap = open_taps[iteration]
        open_time = event_time(open_tap)
        if open_time is None:
            continue
        # Consume paints in chronological order rather than re-searching from the start each time,
        # so a missing paint for one iteration cannot get matched to a later iteration's paint.
        paint = None
        while paint_cursor < len(first_paints):
            candidate = first_paints[paint_cursor]
            paint_cursor += 1
            candidate_time = event_time(candidate)
            if candidate_time is not None and candidate_time >= open_time:
                paint = candidate
                break
        if paint is not None:
            open_to_paint.append(wall_delta_ms(open_tap, paint))
        back_tap = back_taps.get(iteration)
        window_end = event_time(back_tap) if back_tap is not None else window.end
        frames = render_frames_in_wall_range(window.app_events, open_time, window_end)
        frames_per_reopen.append(len(frames))
        kb_per_reopen.append(decoded_kb(frames))

    open_stats, frame_stats, kb_stats = stats(open_to_paint), stats(frames_per_reopen), stats(kb_per_reopen)
    return {
        "open_paint_p50": open_stats["p50"],
        "open_paint_max": open_stats["max"],
        "frames_p50": frame_stats["p50"],
        "frames_max": frame_stats["max"],
        "kb_p50": kb_stats["p50"],
        "kb_max": kb_stats["max"],
    }


def metric_keyboard(window):
    if window is None:
        return None
    toggles = sorted(
        (e for e in window.app_events if e.get("name") == "keyboard_toggle" and event_uptime_ns(e) is not None),
        key=event_uptime_ns,
    )
    resizes = sorted(
        (
            e
            for e in window.app_events
            if e.get("name") == "viewport_resize_frame_visible" and event_uptime_ns(e) is not None
        ),
        key=event_uptime_ns,
    )
    # A toggle pairs only with a resize that lands before the next toggle. The first show after an
    # open has no resize event of its own (the frame for the reduced grid arrives before the viewport
    # target is armed), and a running cursor would hand that show the following hide's resize and shift
    # every later pair by one.
    show_ms, hide_ms = [], []
    for position, toggle in enumerate(toggles):
        toggle_ns = event_uptime_ns(toggle)
        next_toggle_ns = event_uptime_ns(toggles[position + 1]) if position + 1 < len(toggles) else None
        resize = next(
            (
                candidate
                for candidate in resizes
                if event_uptime_ns(candidate) >= toggle_ns and (next_toggle_ns is None or event_uptime_ns(candidate) < next_toggle_ns)
            ),
            None,
        )
        if resize is None:
            continue
        # The resize event's own `elapsedMS` is the toggle-to-frame time the app measured; the event is
        # logged 500 ms later, after its quiet window, so its timestamp would overstate every transition.
        delta = event_elapsed_ms(resize)
        if delta is None:
            continue
        (show_ms if attr(toggle, "visible") == "1" else hide_ms).append(delta)

    show_taps = markers_keyed(window, "keyboard_show_tap", "cycle")
    cycles = sorted(show_taps, key=numeric_sort_key)
    frames_per_cycle, kb_per_cycle = [], []
    for index, cycle in enumerate(cycles):
        start_t = event_time(show_taps[cycle])
        if start_t is None:
            continue
        end_t = event_time(show_taps[cycles[index + 1]]) if index + 1 < len(cycles) else window.end
        frames = render_frames_in_wall_range(window.app_events, start_t, end_t or window.end)
        frames_per_cycle.append(len(frames))
        kb_per_cycle.append(decoded_kb(frames))

    input_rpc_ms = [
        event_elapsed_ms(e)
        for e in window.app_events
        if e.get("name") == "input_command_rpc_end" and attr(e, "success") == "1"
    ]

    show_stats, hide_stats = stats(show_ms), stats(hide_ms)
    frame_stats, kb_stats, input_stats = stats(frames_per_cycle), stats(kb_per_cycle), stats(input_rpc_ms)
    return {
        "show_p50": show_stats["p50"],
        "show_max": show_stats["max"],
        "hide_p50": hide_stats["p50"],
        "hide_max": hide_stats["max"],
        "frames_p50": frame_stats["p50"],
        "frames_max": frame_stats["max"],
        "kb_p50": kb_stats["p50"],
        "kb_max": kb_stats["max"],
        "input_p50": input_stats["p50"],
        "input_p95": input_stats["p95"],
        "input_max": input_stats["max"],
    }


BURST_SETTLE_SECONDS = 1.0


def _streaming_burst(window, burst_sent, burst_wait_end, streaming_ready, burst):
    start_marker = burst_sent.get(burst)
    start_t = event_time(start_marker) if start_marker is not None else event_time(streaming_ready)
    end_marker = burst_wait_end.get(burst)
    end_t = event_time(end_marker)
    # `burst_wait_end` is stamped when BURST_DONE shows on screen; the prompt repaint that follows it
    # still belongs to the burst, so the window keeps one settle second after the marker.
    if end_t is not None:
        end_t = end_t + timedelta(seconds=BURST_SETTLE_SECONDS)
    if start_t is None or end_t is None:
        return {"frames": None, "decoded_kb": None, "wire_kb": None, "duration_ms": None, "frames_per_sec": None, "kb_per_frame": None}

    frames = render_frames_in_wall_range(window.app_events, start_t, end_t)
    kb = decoded_kb(frames)
    wire_kb = shaper_bytes_in_range(window, start_t, end_t, "down") / 1024.0

    # Duration between the first and last frame of the burst pairs two app events, so uptime ns
    # is the right clock even though the burst's own start/end come from wall-clock markers.
    frame_ns = sorted(ns for ns in (event_uptime_ns(f) for f in frames) if ns is not None)
    if len(frame_ns) >= 2:
        duration_ms = (frame_ns[-1] - frame_ns[0]) / 1_000_000.0
    elif frame_ns:
        duration_ms = 0.0
    else:
        duration_ms = None

    return {
        "frames": len(frames),
        "decoded_kb": kb,
        "wire_kb": wire_kb,
        "duration_ms": duration_ms,
        "frames_per_sec": (len(frames) / (duration_ms / 1000.0)) if duration_ms else None,
        "kb_per_frame": (kb / len(frames)) if frames else None,
    }


def metric_streaming(window):
    if window is None:
        return None
    burst_sent = markers_keyed(window, "burst_sent", "burst")
    burst_wait_end = markers_keyed(window, "burst_wait_end", "burst")
    streaming_ready = marker(window, "streaming_ready")
    result = {}
    for burst in ("1", "2"):
        for key, value in _streaming_burst(window, burst_sent, burst_wait_end, streaming_ready, burst).items():
            result[f"burst{burst}_{key}"] = value
    return result


def metric_scrollback(window):
    if window is None:
        return None
    # Flicks are ordered by time, not by their `index` attribute: the flicks back toward the bottom
    # restart at index 1, so keying by index would collapse them onto the history flicks.
    flicks = sorted((m for m in (window.markers.get("flick") or []) if event_time(m) is not None), key=event_time)
    rpc_ms, frames_per_flick, kb_per_flick, settle_ms = [], [], [], []
    for position, flick in enumerate(flicks):
        start_t = event_time(flick)
        end_t = event_time(flicks[position + 1]) if position + 1 < len(flicks) else window.end
        end_t = end_t or window.end

        # Every scroll round trip the flick caused counts, since a flick decelerates through dozens of
        # scroll requests and each one is a full round trip the user waits on.
        rpc_ms.extend(
            event_elapsed_ms(e)
            for e in window.app_events
            if e.get("name") == "input_command_rpc_end"
            and attr(e, "input_kind") == "send_scroll"
            and attr(e, "success") == "1"
            and event_time(e) is not None
            and start_t <= event_time(e) <= end_t
            and event_elapsed_ms(e) is not None
        )

        frames = render_frames_in_wall_range(window.app_events, start_t, end_t)
        frames_per_flick.append(len(frames))
        kb_per_flick.append(decoded_kb(frames))
        # "flick -> settled" is approximated as the flick's own start to its last in-window frame:
        # a true 500 ms trailing-quiet check would need to look past this flick's own end boundary
        # into the next flick's frames to rule out a frame arriving just after this slice, which
        # this per-flick slicing does not attempt.
        if frames:
            last_frame_t = max(event_time(f) for f in frames if event_time(f) is not None)
            settle_ms.append((last_frame_t - start_t).total_seconds() * 1000.0)

    rpc_stats, frame_stats, kb_stats, settle_stats = stats(rpc_ms), stats(frames_per_flick), stats(kb_per_flick), stats(settle_ms)
    return {
        "rpc_p50": rpc_stats["p50"],
        "rpc_max": rpc_stats["max"],
        "frames_p50": frame_stats["p50"],
        "frames_max": frame_stats["max"],
        "kb_p50": kb_stats["p50"],
        "kb_max": kb_stats["max"],
        "settle_p50": settle_stats["p50"],
        "settle_max": settle_stats["max"],
    }


def metric_background(window, mode):
    """mode "terminal": foreground -> next stream_first_frame/render_frame_payload_receive.
    mode "list": foreground -> next successful overview_refresh_end."""
    if window is None:
        return None
    backgrounds = markers_keyed(window, "background", "iteration")
    foregrounds = markers_keyed(window, "foreground", "iteration")
    iterations = sorted(foregrounds, key=numeric_sort_key)

    resume_ms, frames_per_resume, kb_per_resume = [], [], []
    for iteration in iterations:
        fg = foregrounds[iteration]
        fg_time = event_time(fg)
        if fg_time is None:
            continue
        candidates = [e for e in window.app_events if event_time(e) is not None and event_time(e) >= fg_time]
        if mode == "terminal":
            target = first_named_any(
                candidates,
                ("stream_first_frame", "render_frame_payload_receive"),
                predicate=lambda e: e.get("name") != "render_frame_payload_receive" or attr(e, "render_update") == "1",
            )
        else:
            target = first_named(candidates, "overview_refresh_end", predicate=lambda e: attr(e, "success") == "1")
        if target is not None:
            resume_ms.append(wall_delta_ms(fg, target))

        next_iteration = str(int(iteration) + 1) if numeric_sort_key(iteration)[0] == 0 else None
        next_bg = backgrounds.get(next_iteration) if next_iteration is not None else None
        end_t = event_time(next_bg) if next_bg is not None else window.end
        frames = render_frames_in_wall_range(window.app_events, fg_time, end_t or window.end)
        frames_per_resume.append(len(frames))
        kb_per_resume.append(decoded_kb(frames))

    resume_stats, frame_stats, kb_stats = stats(resume_ms), stats(frames_per_resume), stats(kb_per_resume)
    return {
        "resume_p50": resume_stats["p50"],
        "resume_max": resume_stats["max"],
        "frames_p50": frame_stats["p50"],
        "frames_max": frame_stats["max"],
        "kb_p50": kb_stats["p50"],
        "kb_max": kb_stats["max"],
        "connection_stage_events": len([e for e in window.app_events if e.get("name") == "connection_stage"]),
    }


def metric_reconnect(window):
    if window is None:
        return None
    link_down, link_up, recovered = marker(window, "link_down"), marker(window, "link_up"), marker(window, "recovered")

    banner_event = None
    if link_down is not None and event_time(link_down) is not None:
        down_time = event_time(link_down)
        banner_event = first_named(
            [e for e in window.app_events if event_time(e) is not None and event_time(e) >= down_time],
            "connection_stage",
            predicate=lambda e: attr(e, "stage") == "reconnecting",
        )

    first_frame_after_up, banner_clear_event = None, None
    if link_up is not None and event_time(link_up) is not None:
        up_time = event_time(link_up)
        candidates = [e for e in window.app_events if event_time(e) is not None and event_time(e) >= up_time]
        first_frame_after_up = first_named(candidates, "stream_first_frame")
        banner_clear_event = first_named(
            candidates, "connection_stage", predicate=lambda e: attr(e, "banner") == "0"
        )

    recovery_frames, recovery_kb = None, None
    if link_down is not None and recovered is not None:
        frames = render_frames_in_wall_range(window.app_events, event_time(link_down), event_time(recovered))
        recovery_frames, recovery_kb = len(frames), decoded_kb(frames)

    return {
        "link_down_to_banner_ms": wall_delta_ms(link_down, banner_event) if banner_event else None,
        "link_up_to_first_frame_ms": wall_delta_ms(link_up, first_frame_after_up) if first_frame_after_up else None,
        "link_up_to_banner_clear_ms": wall_delta_ms(link_up, banner_clear_event) if banner_clear_event else None,
        "recovery_frames": recovery_frames,
        "recovery_kb": recovery_kb,
        "connection_error_alerts": len([e for e in window.app_events if e.get("name") == "connection_error_alert"]),
    }


def metric_idle(window):
    if window is None:
        return None
    idle_begin, idle_end = marker(window, "idle_begin"), marker(window, "idle_end")
    start_t = event_time(idle_begin) if idle_begin is not None else window.begin
    end_t = event_time(idle_end) if idle_end is not None else window.end
    if start_t is None or end_t is None or end_t <= start_t:
        return {"up_bytes_per_sec": None, "down_bytes_per_sec": None, "decoded_frames": None, "connection_events": None}

    duration_s = (end_t - start_t).total_seconds()
    up_total = shaper_bytes_in_range(window, start_t, end_t, "up")
    down_total = shaper_bytes_in_range(window, start_t, end_t, "down")
    frames = render_frames_in_wall_range(window.app_events, start_t, end_t)
    connection_events = [
        e for e in window.app_events if e.get("name") in ("connection_stage", "stream_disconnect", "stream_first_frame")
    ]
    return {
        "up_bytes_per_sec": up_total / duration_s,
        "down_bytes_per_sec": down_total / duration_s,
        "decoded_frames": len(frames),
        "connection_events": len(connection_events),
    }


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

COLD_OPEN_COLUMNS = [
    ("launch_to_list_ms", "launch to list ms", fmt_ms),
    ("open_to_paint_ms", "open tap to paint ms", fmt_ms),
    ("paint_elapsed_ms", "open begin to paint ms (device)", fmt_ms),
    ("hold_released_by", "hold released by", fmt_str),
    ("frames_to_paint", "frames to paint", fmt_count),
    ("decoded_kb_to_paint", "decoded KB to paint", fmt_kb),
    ("frames_3s", "frames (3s after paint)", fmt_count),
    ("decoded_kb_3s", "decoded KB (3s after paint)", fmt_kb),
    ("wire_kb_down", "wire KB down", fmt_kb),
]

BACK_AND_FORTH_COLUMNS = [
    ("open_paint_p50", "open->paint p50 ms", fmt_ms),
    ("open_paint_max", "open->paint max ms", fmt_ms),
    ("frames_p50", "frames/reopen p50", fmt_count),
    ("frames_max", "frames/reopen max", fmt_count),
    ("kb_p50", "decoded KB/reopen p50", fmt_kb),
    ("kb_max", "decoded KB/reopen max", fmt_kb),
]

KEYBOARD_COLUMNS = [
    ("show_p50", "show->resize p50 ms", fmt_ms),
    ("show_max", "show->resize max ms", fmt_ms),
    ("hide_p50", "hide->resize p50 ms", fmt_ms),
    ("hide_max", "hide->resize max ms", fmt_ms),
    ("frames_p50", "frames/cycle p50", fmt_count),
    ("frames_max", "frames/cycle max", fmt_count),
    ("kb_p50", "decoded KB/cycle p50", fmt_kb),
    ("kb_max", "decoded KB/cycle max", fmt_kb),
    ("input_p50", "input rpc p50 ms", fmt_ms),
    ("input_p95", "input rpc p95 ms", fmt_ms),
    ("input_max", "input rpc max ms", fmt_ms),
]

STREAMING_COLUMNS = []
for _burst in ("1", "2"):
    STREAMING_COLUMNS.extend(
        [
            (f"burst{_burst}_frames", f"burst {_burst} frames", fmt_count),
            (f"burst{_burst}_decoded_kb", f"burst {_burst} decoded KB", fmt_kb),
            (f"burst{_burst}_wire_kb", f"burst {_burst} wire KB", fmt_kb),
            (f"burst{_burst}_duration_ms", f"burst {_burst} duration ms", fmt_ms),
            (f"burst{_burst}_frames_per_sec", f"burst {_burst} frames/s", fmt_num),
            (f"burst{_burst}_kb_per_frame", f"burst {_burst} KB/frame", fmt_kb),
        ]
    )

SCROLLBACK_COLUMNS = [
    ("rpc_p50", "scroll rpc p50 ms", fmt_ms),
    ("rpc_max", "scroll rpc max ms", fmt_ms),
    ("frames_p50", "frames/flick p50", fmt_count),
    ("frames_max", "frames/flick max", fmt_count),
    ("kb_p50", "decoded KB/flick p50", fmt_kb),
    ("kb_max", "decoded KB/flick max", fmt_kb),
    ("settle_p50", "flick->settled p50 ms", fmt_ms),
    ("settle_max", "flick->settled max ms", fmt_ms),
]

BACKGROUND_COLUMNS = [
    ("resume_p50", "foreground->frame p50 ms", fmt_ms),
    ("resume_max", "foreground->frame max ms", fmt_ms),
    ("frames_p50", "frames/resume p50", fmt_count),
    ("frames_max", "frames/resume max", fmt_count),
    ("kb_p50", "decoded KB/resume p50", fmt_kb),
    ("kb_max", "decoded KB/resume max", fmt_kb),
    ("connection_stage_events", "connection_stage events", fmt_count),
]

RECONNECT_COLUMNS = [
    ("link_down_to_banner_ms", "link down->banner ms", fmt_ms),
    ("link_up_to_first_frame_ms", "link up->first frame ms", fmt_ms),
    ("link_up_to_banner_clear_ms", "link up->banner clear ms", fmt_ms),
    ("recovery_frames", "frames during recovery", fmt_count),
    ("recovery_kb", "decoded KB during recovery", fmt_kb),
    ("connection_error_alerts", "connection_error_alert count", fmt_count),
]

IDLE_COLUMNS = [
    ("up_bytes_per_sec", "wire KB/s up", lambda v: fmt_num(v / 1024.0) if v is not None else "n/a"),
    ("down_bytes_per_sec", "wire KB/s down", lambda v: fmt_num(v / 1024.0) if v is not None else "n/a"),
    ("decoded_frames", "decoded frames", fmt_count),
    ("connection_events", "connection events", fmt_count),
]


def render_table(title, columns, metrics_by_profile):
    headers = ["Profile"] + [header for _, header, _ in columns]
    rows = []
    for profile in PROFILES:
        metrics = metrics_by_profile.get(profile)
        if metrics is None:
            rows.append([profile] + ["no data"] * len(columns))
            continue
        rows.append([profile] + [fmt(metrics.get(key)) for key, _, fmt in columns])
    return f"## {title}\n\n" + markdown_table(headers, rows) + "\n"


def build_header(run_root: Path, device_events, shaper_events, sessions, windows) -> str:
    app_launch = next((e for e in device_events if e.get("name") == "app_launch"), None)
    attrs = (app_launch.get("attributes") if app_launch else None) or {}

    target = sessions.get("target") or {}
    if target.get("kind") == "remote":
        target_desc = f"remote ({target.get('host', 'n/a')})"
    elif target.get("kind") == "local":
        target_desc = "local"
    else:
        target_desc = "n/a"

    bounds = [w.begin for w in windows.values() if w is not None] + [w.end for w in windows.values() if w is not None]
    run_time = f"{min(bounds).isoformat()} to {max(bounds).isoformat()}" if bounds else "n/a"

    missing = [
        name
        for name in ("device-perf.jsonl", "shaper.jsonl", "sessions.json")
        if not (run_root / name).exists()
    ]
    missing_note = ", ".join(missing) if missing else "none"

    profile_events = {}
    for event in shaper_events:
        if event.get("event") == "profile" and event.get("name") not in profile_events:
            profile_events[event.get("name")] = event
    profile_rows = []
    for profile in PROFILES:
        event = profile_events.get(profile)
        if event is None:
            profile_rows.append([profile, "n/a", "n/a"])
            continue
        delay_ms = numeric(event.get("delay_ms"))
        bandwidth_mbit = numeric(event.get("bandwidth_mbit"))
        profile_rows.append(
            [
                profile,
                fmt_num(delay_ms, 0) if delay_ms is not None else "n/a",
                f"{bandwidth_mbit:.0f} Mbit/s" if bandwidth_mbit is not None else "n/a",
            ]
        )

    lines = [
        f"# iOS performance baseline: {run_root.name}",
        "",
        "| Field | Value |",
        "| --- | --- |",
        f"| Target | {target_desc} |",
        f"| Device model | {attrs.get('device_model', 'n/a')} |",
        f"| iOS version | {attrs.get('ios_version', 'n/a')} |",
        f"| Build | {attrs.get('build', 'n/a')} |",
        f"| Run time (UTC) | {run_time} |",
        f"| Missing input files | {missing_note} |",
        "",
        "### Network profiles",
        "",
        markdown_table(["Profile", "one-way delay ms", "bandwidth"], profile_rows),
        "",
    ]
    return "\n".join(lines)


def build_report_sections(run_root: Path):
    device_events = load_device_events(run_root)
    shaper_events = load_shaper_events(run_root)
    sessions = load_sessions(run_root)
    windows = build_scenario_windows(device_events, shaper_events)

    def metrics_for(scenario, metric_fn, *extra_args):
        return {profile: metric_fn(windows.get((profile, scenario)), *extra_args) for profile in PROFILES}

    return [
        build_header(run_root, device_events, shaper_events, sessions, windows),
        render_table("Cold open", COLD_OPEN_COLUMNS, metrics_for("cold-open", metric_cold_open)),
        render_table("Back and forth", BACK_AND_FORTH_COLUMNS, metrics_for("back-and-forth", metric_back_and_forth)),
        render_table("Keyboard", KEYBOARD_COLUMNS, metrics_for("keyboard", metric_keyboard)),
        render_table("Streaming", STREAMING_COLUMNS, metrics_for("streaming", metric_streaming)),
        render_table("Scrollback", SCROLLBACK_COLUMNS, metrics_for("scrollback", metric_scrollback)),
        render_table(
            "Background/foreground: terminal", BACKGROUND_COLUMNS, metrics_for("background-terminal", metric_background, "terminal")
        ),
        render_table(
            "Background/foreground: list", BACKGROUND_COLUMNS, metrics_for("background-list", metric_background, "list")
        ),
        render_table("Reconnect", RECONNECT_COLUMNS, metrics_for("reconnect", metric_reconnect)),
        render_table("Idle", IDLE_COLUMNS, metrics_for("idle", metric_idle)),
    ]


def build_report(run_root: Path) -> str:
    return "\n".join(build_report_sections(run_root))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render a markdown performance report for one iOS performance baseline lane run.")
    parser.add_argument("--run-root", required=True, help="Run root directory produced by e2e_mobile_baseline.sh.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    run_root = Path(args.run_root)
    run_root.mkdir(parents=True, exist_ok=True)
    sections = build_report_sections(run_root)
    (run_root / "report.md").write_text("\n".join(sections) + "\n", encoding="utf-8")
    print(sections[0])
    print(sections[1])


if __name__ == "__main__":
    main()
