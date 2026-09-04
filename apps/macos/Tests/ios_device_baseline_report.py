#!/usr/bin/env python3
"""Renders a markdown performance report for one iOS device baseline run.

Reads the runner's own event stamps (runner-events.jsonl) and the device-side
performance log pulled off the phone (device-perf.jsonl, plus a rotated
device-perf.jsonl.1 when present) from a run root produced by
apps/macos/Tests/ios_device_baseline.sh, and prints one markdown report to
stdout.

This script only measures; it never judges pass or fail. Every section
degrades to "n/a" rather than raising when the data it needs is missing, and
an unrecognized event name or a malformed JSONL line is skipped rather than
treated as an error, so a partial or interrupted run still produces a report.
"""

import argparse
import json
import math
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Device events within this much of a scenario's begin/end stamp still count as
# belonging to that scenario. The runner's own stamps and the phone's emittedAt
# both carry real (if small) clock and I/O latency around the moment the user
# actually performs the step, so a hard boundary would misfile the very events
# nearest the edges most likely to matter (the first paint right after open,
# the last frame right before back).
ASSIGNMENT_SLACK = timedelta(seconds=2)

ISO8601_PATTERN = re.compile(
    r"^(?P<y>\d{4})-(?P<mo>\d{2})-(?P<d>\d{2})T(?P<h>\d{2}):(?P<mi>\d{2}):(?P<s>\d{2})"
    r"(?:\.(?P<frac>\d+))?(?P<tz>Z|[+-]\d{2}:?\d{2})?$"
)

THERMAL_STATE_ORDER = {"nominal": 0, "fair": 1, "serious": 2, "critical": 3}


def parse_iso8601(value):
    """Parses an ISO 8601 timestamp with 'Z' or an offset and any fractional-second width.

    Python's stdlib `datetime.fromisoformat` did not accept 'Z' or variable-width
    fractional seconds until 3.11, and this script runs under whatever python3 the
    developer machine has, so it parses the format by hand instead of assuming 3.11.
    Returns None for anything that does not match rather than raising, matching this
    report's "missing data degrades to n/a" contract.
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


def load_device_events(run_root: Path) -> list[dict]:
    # The rotated file is the older half of the log, so it is read first; this keeps
    # every consumer of the returned list (uptime-ordered pairing in particular) in
    # chronological order without a second sort pass.
    events: list[dict] = []
    events.extend(iter_jsonl(run_root / "device-perf.jsonl.1"))
    events.extend(iter_jsonl(run_root / "device-perf.jsonl"))
    return events


@dataclass
class ScenarioWindow:
    scenario: str
    begin: datetime
    end: "datetime | None"


def load_scenario_windows(run_root: Path) -> list[ScenarioWindow]:
    """Builds each scenario's [begin, end] wall-clock window from the runner's own stamps.

    A scenario whose `scenario_end` stamp is missing (the run was interrupted mid-scenario)
    keeps an open window that runs to the next scenario's begin, or to no bound at all for
    the last scenario in the run: better to over-assign device events to an interrupted
    scenario than to silently drop them.
    """
    windows: list[ScenarioWindow] = []
    open_by_scenario: dict[str, ScenarioWindow] = {}
    for obj in iter_jsonl(run_root / "runner-events.jsonl"):
        kind = obj.get("kind")
        scenario = obj.get("scenario")
        stamped_at = parse_iso8601(obj.get("t"))
        if not scenario or stamped_at is None:
            continue
        if kind == "scenario_begin":
            window = ScenarioWindow(scenario=scenario, begin=stamped_at, end=None)
            windows.append(window)
            open_by_scenario[scenario] = window
        elif kind == "scenario_end":
            window = open_by_scenario.pop(scenario, None)
            if window is not None:
                window.end = stamped_at
    windows.sort(key=lambda window: window.begin)
    for index, window in enumerate(windows):
        if window.end is None:
            window.end = windows[index + 1].begin if index + 1 < len(windows) else None
    return windows


def scenario_order(windows: list[ScenarioWindow]) -> list[str]:
    return [window.scenario for window in windows]


def assign_scenario(at, windows: list[ScenarioWindow]):
    """Assigns a device-side timestamp to the scenario window it belongs to.

    A window that contains `at` with no slack always wins outright: the runner stamps the
    next scenario's begin right at the previous scenario's end, so an event just after that
    shared boundary is inside the later window for real and must not be pulled back into the
    earlier one just because it is also within slack of the earlier window's end. Only when no
    window contains `at` for real does the slack-expanded search run, and there the LAST
    (latest-begin) matching window wins: for two adjacent windows, a time within slack of both
    the earlier window's end and the later window's begin is closer, in real-world terms, to
    the window it is about to (or just did) begin.
    """
    if at is None:
        return None
    for window in windows:
        if at >= window.begin and (window.end is None or at <= window.end):
            return window.scenario
    match = None
    for window in windows:
        begin = window.begin - ASSIGNMENT_SLACK
        end = window.end + ASSIGNMENT_SLACK if window.end is not None else None
        if at >= begin and (end is None or at <= end):
            match = window.scenario
    return match


def event_time(event: dict):
    return parse_iso8601(event.get("emittedAt"))


def event_uptime_ns(event: dict):
    try:
        return int(event["emittedUptimeNanoseconds"])
    except (KeyError, TypeError, ValueError):
        return None


def numeric(value):
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def elapsed_ms(event: dict):
    return numeric(event.get("elapsedMS"))


def percentile(values: list[float], pct: float):
    """Nearest-rank percentile: rank = ceil(pct/100 * n), clamped into [1, n]."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, min(len(ordered), math.ceil(pct / 100 * len(ordered))))
    return ordered[rank - 1]


def stats_row(values: list[float]) -> dict:
    return {
        "n": len(values),
        "p50": percentile(values, 50),
        "p95": percentile(values, 95),
        "max": max(values) if values else None,
    }


def fmt_num(value, decimals: int = 1) -> str:
    return "n/a" if value is None else f"{value:.{decimals}f}"


def fmt_bytes(value) -> str:
    return "n/a" if value is None else f"{int(value):,}"


def markdown_table(headers: list[str], rows: list[list[str]]) -> str:
    if not rows:
        return "n/a"
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(headers)) + " |"]
    for row in rows:
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


def group_by_scenario(events, windows, name, predicate=None, value_fn=elapsed_ms) -> dict[str, list]:
    grouped: dict[str, list] = {scenario: [] for scenario in scenario_order(windows)}
    for event in events:
        if event.get("name") != name:
            continue
        if predicate is not None and not predicate(event):
            continue
        scenario = assign_scenario(event_time(event), windows)
        if scenario not in grouped:
            continue
        value = value_fn(event)
        if value is not None:
            grouped[scenario].append(value)
    return grouped


def stats_rows(grouped: dict[str, list], windows: list[ScenarioWindow]) -> list[list[str]]:
    rows = []
    for scenario in scenario_order(windows):
        stats = stats_row(grouped.get(scenario, []))
        rows.append([scenario, str(stats["n"]), fmt_num(stats["p50"]), fmt_num(stats["p95"]), fmt_num(stats["max"])])
    return rows


def _pick_app_launch(events: list[dict], windows: list[ScenarioWindow]):
    """Picks the app_launch event that describes this run's build.

    The device log persists across installs and the rotated `.1` file loads first, so the
    first app_launch in `events` can describe a previous build rather than the one this run
    exercised. Instead this picks the LAST app_launch at or after the run's earliest scenario
    window begin (minus the shared ASSIGNMENT_SLACK, for the same clock/IO latency reasons
    assign_scenario allows it at a window edge); a run with no scenario windows, or whose
    app_launch events all predate that bound, falls back to the last app_launch in the log.
    """
    app_launches = [event for event in events if event.get("name") == "app_launch"]
    earliest_begin = min((window.begin for window in windows), default=None)
    if earliest_begin is not None:
        run_start = earliest_begin - ASSIGNMENT_SLACK
        in_run = [event for event in app_launches if (event_time(event) or run_start) >= run_start]
        if in_run:
            return in_run[-1]
    return app_launches[-1] if app_launches else None


def build_header(events: list[dict], windows: list[ScenarioWindow], run_root: Path) -> str:
    app_launch = _pick_app_launch(events, windows)
    attrs = (app_launch or {}).get("attributes") or {}
    times = [window.begin for window in windows] + [window.end for window in windows if window.end is not None]
    run_time = f"{min(times).isoformat()} to {max(times).isoformat()}" if times else "n/a"
    scenarios_run = ", ".join(scenario_order(windows)) if windows else "n/a"
    lines = [
        f"# iOS device performance baseline: {run_root.name}",
        "",
        "| Field | Value |",
        "| --- | --- |",
        f"| Device model | {attrs.get('device_model', 'n/a')} |",
        f"| iOS version | {attrs.get('ios_version', 'n/a')} |",
        f"| Build | {attrs.get('build', 'n/a')} |",
        f"| Run time (UTC) | {run_time} |",
        f"| Scenarios run | {scenarios_run} |",
        "",
    ]
    return "\n".join(lines)


def build_list_load_section(events: list[dict], windows: list[ScenarioWindow]) -> str:
    ok = group_by_scenario(events, windows, "overview_refresh_end", predicate=lambda e: (e.get("attributes") or {}).get("success") == "1")
    failed = group_by_scenario(
        events,
        windows,
        "overview_refresh_end",
        predicate=lambda e: (e.get("attributes") or {}).get("success") != "1",
        value_fn=lambda e: 1,
    )
    rows = []
    for scenario in scenario_order(windows):
        stats = stats_row(ok.get(scenario, []))
        rows.append(
            [
                scenario,
                str(stats["n"]),
                fmt_num(stats["p50"]),
                fmt_num(stats["p95"]),
                fmt_num(stats["max"]),
                str(len(failed.get(scenario, []))),
            ]
        )
    body = markdown_table(["Scenario", "n", "p50 ms", "p95 ms", "max ms", "failures"], rows)
    return "## List load\n\n" + body + "\n"


def _terminal_back_opened_in_window(event: dict, windows: list[ScenarioWindow]) -> bool:
    """Keeps a terminal_back sample only when the terminal it closes was also opened in the
    same scenario window as the back itself.

    A terminal_back's elapsedMS is dwell time since terminal_open_begin, not since the
    scenario began. In back-and-forth the terminal is already open when the scenario starts
    (from cold-open or the runner's open prompt), so that first back's elapsedMS spans the
    prompt delay before the scenario and would inflate p95/max if counted. Missing timing data
    is let through unfiltered; group_by_scenario's own value_fn check drops it regardless.
    """
    at = event_time(event)
    elapsed = elapsed_ms(event)
    if at is None or elapsed is None:
        return True
    opened_at = at - timedelta(milliseconds=elapsed)
    return assign_scenario(opened_at, windows) == assign_scenario(at, windows)


def build_open_to_first_paint_section(events: list[dict], windows: list[ScenarioWindow]) -> str:
    lines = ["## Open to first paint", ""]
    # One table per release reason seen in this run, the requested-frame case first: `matching_frame` is
    # the number an open is judged by, and the other reasons explain the opens that did not get there.
    seen = {(e.get("attributes") or {}).get("hold_released_by") for e in events if e.get("name") == "terminal_first_paint"}
    holds = ["matching_frame"] + sorted(hold for hold in seen if hold and hold != "matching_frame")
    for hold in holds:
        grouped = group_by_scenario(
            events,
            windows,
            "terminal_first_paint",
            predicate=lambda e, hold=hold: (e.get("attributes") or {}).get("hold_released_by") == hold,
        )
        lines.append(f"### First paint (hold_released_by={hold})")
        lines.append("")
        lines.append(markdown_table(["Scenario", "n", "p50 ms", "p95 ms", "max ms"], stats_rows(grouped, windows)))
        lines.append("")
    dwell = group_by_scenario(
        events,
        windows,
        "terminal_back",
        predicate=lambda e: _terminal_back_opened_in_window(e, windows),
    )
    lines.append("### Dwell before back (terminal_back)")
    lines.append("")
    lines.append(markdown_table(["Scenario", "n", "p50 ms", "p95 ms", "max ms"], stats_rows(dwell, windows)))
    lines.append("")
    return "\n".join(lines)


def build_keyboard_section(events: list[dict], windows: list[ScenarioWindow]) -> str:
    grouped = group_by_scenario(events, windows, "viewport_resize_frame_visible")
    body = markdown_table(["Scenario", "n", "p50 ms", "p95 ms", "max ms"], stats_rows(grouped, windows))
    return "## Keyboard\n\n" + body + "\n"


def build_input_section(events: list[dict], windows: list[ScenarioWindow]) -> str:
    # `input_command_rpc_end` is emitted for failed sends too (attributes["success"] == "0"), so
    # latency percentiles are computed over successful events only; failures are reported as a
    # separate count so a scenario with retries or drops is still visible in the table.
    ok = group_by_scenario(
        events, windows, "input_command_rpc_end", predicate=lambda e: (e.get("attributes") or {}).get("success") == "1"
    )
    failed = group_by_scenario(
        events,
        windows,
        "input_command_rpc_end",
        predicate=lambda e: (e.get("attributes") or {}).get("success") != "1",
        value_fn=lambda e: 1,
    )
    rows = []
    for scenario in scenario_order(windows):
        stats = stats_row(ok.get(scenario, []))
        rows.append(
            [
                scenario,
                str(stats["n"]),
                fmt_num(stats["p50"]),
                fmt_num(stats["p95"]),
                fmt_num(stats["max"]),
                str(len(failed.get(scenario, []))),
            ]
        )
    body = markdown_table(["Scenario", "n", "p50 ms", "p95 ms", "max ms", "failed"], rows)
    return "## Input\n\n" + body + "\n"


def _next_matching(
    ordered: list[dict],
    start_index: int,
    names: tuple,
    at_or_after_ns: int,
    windows: list[ScenarioWindow],
    scenario: str,
    session_id=None,
):
    """Finds the next event of one of `names` at or after a device uptime, bounded to the
    source event's own scenario window.

    A resume or handoff whose target event never arrives before the scenario ends must not
    fall through to a frame from a later scenario: pairing across scenarios would attribute a
    misleadingly huge duration to the source scenario. So a candidate is skipped unless the
    shared scenario-window assignment (assign_scenario) places it in `scenario`, and the
    search stops once a candidate's wall-clock time passes the window's end (plus the shared
    ASSIGNMENT_SLACK). Returns None, and the pair is dropped, when nothing qualifies.
    """
    window = next((w for w in windows if w.scenario == scenario), None)
    deadline = window.end + ASSIGNMENT_SLACK if window is not None and window.end is not None else None
    for candidate in ordered[start_index + 1 :]:
        candidate_at = event_time(candidate)
        if deadline is not None and candidate_at is not None and candidate_at > deadline:
            break
        if assign_scenario(candidate_at, windows) != scenario:
            continue
        if candidate.get("name") not in names:
            continue
        if session_id is not None and candidate.get("sessionID") != session_id:
            continue
        candidate_ns = event_uptime_ns(candidate)
        if candidate_ns is None or candidate_ns < at_or_after_ns:
            continue
        return candidate
    return None


def build_foreground_resume_section(events: list[dict], windows: list[ScenarioWindow]) -> str:
    ordered = sorted((event for event in events if event_uptime_ns(event) is not None), key=event_uptime_ns)
    to_terminal: dict[str, list[float]] = {scenario: [] for scenario in scenario_order(windows)}
    to_list: dict[str, list[float]] = {scenario: [] for scenario in scenario_order(windows)}
    for index, event in enumerate(ordered):
        if event.get("name") != "app_scene_phase":
            continue
        attrs = event.get("attributes") or {}
        if attrs.get("phase") != "active":
            continue
        phase_ns = event_uptime_ns(event)
        scenario = assign_scenario(event_time(event), windows)
        if scenario not in to_terminal:
            continue
        if attrs.get("open_terminal") == "1":
            target = _next_matching(
                ordered, index, ("stream_first_frame", "render_frame_payload_receive"), phase_ns, windows, scenario
            )
            if target is not None:
                to_terminal[scenario].append((event_uptime_ns(target) - phase_ns) / 1_000_000)
        elif attrs.get("open_terminal") == "0":
            target = _next_matching(ordered, index, ("overview_refresh_end",), phase_ns, windows, scenario)
            if target is not None:
                to_list[scenario].append((event_uptime_ns(target) - phase_ns) / 1_000_000)

    lines = ["## Foreground resume", ""]
    lines.append("### Resume to terminal (open_terminal=1 to next stream_first_frame/render_frame_payload_receive)")
    lines.append("")
    lines.append(markdown_table(["Scenario", "n", "p50 ms", "p95 ms", "max ms"], stats_rows(to_terminal, windows)))
    lines.append("")
    lines.append("### Resume to list (open_terminal=0 to next overview_refresh_end)")
    lines.append("")
    lines.append(markdown_table(["Scenario", "n", "p50 ms", "p95 ms", "max ms"], stats_rows(to_list, windows)))
    lines.append("")
    return "\n".join(lines)


def build_handoff_section(events: list[dict], windows: list[ScenarioWindow]) -> str:
    ordered = sorted((event for event in events if event_uptime_ns(event) is not None), key=event_uptime_ns)
    recovery: dict[str, list[float]] = {scenario: [] for scenario in scenario_order(windows)}
    hosts_seen: dict[str, set] = {scenario: set() for scenario in scenario_order(windows)}
    # Per session id, the uptime (ns) of the stream_first_frame most recently turned into a
    # recovery sample. An outage that spans failed redials emits one stream_disconnect per
    # failed attempt, and every one of them would pair with the same eventual stream_first_frame,
    # turning one outage into several samples all biased short. A disconnect that precedes an
    # already-consumed recovery frame (the failed-redial disconnects, which all happen before that
    # frame arrives) or whose own matched frame is that same consumed frame adds no sample, so only
    # an outage's first disconnect ever produces one, measured from that first disconnect.
    consumed_frame_ns: dict = {}
    for index, event in enumerate(ordered):
        if event.get("name") != "stream_disconnect":
            continue
        disconnect_ns = event_uptime_ns(event)
        session = event.get("sessionID")
        scenario = assign_scenario(event_time(event), windows)
        if scenario not in recovery:
            continue
        already_consumed_ns = consumed_frame_ns.get(session)
        if already_consumed_ns is not None and disconnect_ns <= already_consumed_ns:
            continue
        target = _next_matching(
            ordered, index, ("stream_first_frame",), disconnect_ns, windows, scenario, session_id=session
        )
        if target is not None:
            target_ns = event_uptime_ns(target)
            if already_consumed_ns is not None and target_ns == already_consumed_ns:
                continue
            recovery[scenario].append((target_ns - disconnect_ns) / 1_000_000)
            consumed_frame_ns[session] = target_ns
            host = (target.get("attributes") or {}).get("host")
            if host:
                hosts_seen[scenario].add(host)

    rows = []
    for scenario in scenario_order(windows):
        stats = stats_row(recovery.get(scenario, []))
        hosts = ", ".join(sorted(hosts_seen.get(scenario, ()))) or "n/a"
        rows.append([scenario, str(stats["n"]), fmt_num(stats["p50"]), fmt_num(stats["p95"]), fmt_num(stats["max"]), hosts])

    lines = ["## Handoff", ""]
    lines.append("### Disconnect to next first frame")
    lines.append("")
    lines.append(markdown_table(["Scenario", "n", "p50 ms", "p95 ms", "max ms", "hosts seen"], rows))
    lines.append("")

    stage_rows = []
    for window in windows:
        stage_events = sorted(
            (e for e in ordered if e.get("name") == "connection_stage" and assign_scenario(event_time(e), windows) == window.scenario),
            key=event_uptime_ns,
        )
        if not stage_events:
            continue
        base_ns = event_uptime_ns(stage_events[0])
        for stage_event in stage_events:
            attrs = stage_event.get("attributes") or {}
            offset_ms = (event_uptime_ns(stage_event) - base_ns) / 1_000_000
            stage_rows.append([window.scenario, fmt_num(offset_ms), attrs.get("stage", "n/a"), attrs.get("banner", "n/a")])
    lines.append("### Connection stage sequence")
    lines.append("")
    lines.append(markdown_table(["Scenario", "offset ms", "stage", "banner"], stage_rows))
    lines.append("")
    return "\n".join(lines)


def build_payload_section(events: list[dict], windows: list[ScenarioWindow]) -> str:
    def render_update_bytes(event: dict):
        attrs = event.get("attributes") or {}
        wire_bytes = numeric(attrs.get("wire_bytes"))
        return wire_bytes if wire_bytes is not None else numeric(event.get("count"))

    # `render_frame_payload_receive` is also emitted for state payloads that carried no render
    # update (attributes["render_update"] == "0"), so the byte/frame statistics here are scoped
    # to events that actually carried one; a frameless event would otherwise pad the frame count
    # and drag the byte percentiles toward zero without representing any rendered frame.
    grouped = group_by_scenario(
        events,
        windows,
        "render_frame_payload_receive",
        predicate=lambda e: (e.get("attributes") or {}).get("render_update") == "1",
        value_fn=render_update_bytes,
    )
    rows = []
    for window in windows:
        values = grouped.get(window.scenario, [])
        stats = stats_row(values)
        total = sum(values) if values else 0
        duration_s = (window.end - window.begin).total_seconds() if window.begin and window.end else None
        bytes_per_sec = total / duration_s if values and duration_s else None
        frames_per_sec = len(values) / duration_s if values and duration_s else None
        rows.append(
            [
                window.scenario,
                str(stats["n"]),
                fmt_bytes(stats["p50"]),
                fmt_bytes(stats["p95"]),
                fmt_bytes(stats["max"]),
                fmt_bytes(total) if values else "n/a",
                fmt_num(bytes_per_sec),
                fmt_num(frames_per_sec),
            ]
        )
    body = markdown_table(
        ["Scenario", "frames", "p50 bytes", "p95 bytes", "max bytes", "total bytes", "bytes/sec", "frames/sec"], rows
    )
    return "## Payload\n\n" + body + "\n"


def _battery_attrs(event: dict):
    attrs = event.get("attributes") or {}
    return attrs if "battery_level" in attrs else None


def build_battery_section(events: list[dict], windows: list[ScenarioWindow]) -> str:
    drain_rows = []
    thermal_rows = []
    for window in windows:
        samples = []
        for event in events:
            attrs = _battery_attrs(event)
            if attrs is None:
                continue
            if assign_scenario(event_time(event), windows) != window.scenario:
                continue
            at = event_time(event)
            if at is None:
                continue
            samples.append((at, attrs))
        samples.sort(key=lambda item: item[0])

        if not samples:
            drain_rows.append([window.scenario, "n/a", "n/a", "n/a", "n/a"])
        else:
            first_at, first_attrs = samples[0]
            last_at, last_attrs = samples[-1]
            was_charging = any(attrs.get("battery_state") in ("charging", "full") for _, attrs in samples)
            level_first = numeric(first_attrs.get("battery_level"))
            level_last = numeric(last_attrs.get("battery_level"))
            if was_charging or level_first is None or level_last is None:
                drain_rows.append(
                    [
                        window.scenario,
                        fmt_num(level_first, 2) if level_first is not None else "n/a",
                        fmt_num(level_last, 2) if level_last is not None else "n/a",
                        "n/a",
                        "charging" if was_charging else "n/a",
                    ]
                )
            else:
                hours = (last_at - first_at).total_seconds() / 3600
                drain_per_hour_pct = ((level_first - level_last) * 100 / hours) if hours > 0 else None
                drain_rows.append(
                    [
                        window.scenario,
                        fmt_num(level_first, 2),
                        fmt_num(level_last, 2),
                        fmt_num(hours, 2),
                        f"{fmt_num(drain_per_hour_pct)}%/hr" if drain_per_hour_pct is not None else "n/a",
                    ]
                )

        changes = [
            event
            for event in events
            if event.get("name") == "thermal_state_change" and assign_scenario(event_time(event), windows) == window.scenario
        ]
        # A thermal excursion that begins and ends between two 60-second battery samples is invisible to
        # those samples alone, but `thermal_state_change` events capture it as it happens, so their states
        # are folded into the set before taking the max.
        thermal_states_seen = {attrs.get("thermal_state") for _, attrs in samples if attrs.get("thermal_state")}
        thermal_states_seen |= {(event.get("attributes") or {}).get("thermal_state") for event in changes} - {None}
        max_thermal = max(thermal_states_seen, key=lambda state: THERMAL_STATE_ORDER.get(state, -1), default=None)
        change_summary = ", ".join((event.get("attributes") or {}).get("thermal_state", "n/a") for event in changes) or "none"
        thermal_rows.append([window.scenario, max_thermal or "n/a", change_summary])

    lines = ["## Battery", ""]
    lines.append(markdown_table(["Scenario", "level first", "level last", "elapsed hours", "drain/hr"], drain_rows))
    lines.append("")
    lines.append("### Thermal")
    lines.append("")
    lines.append(markdown_table(["Scenario", "max thermal state", "thermal_state_change events"], thermal_rows))
    lines.append("")
    return "\n".join(lines)


def build_alerts_section(events: list[dict], windows: list[ScenarioWindow]) -> str:
    rows = []
    for window in windows:
        alerts = sorted(
            (event for event in events if event.get("name") == "connection_error_alert" and assign_scenario(event_time(event), windows) == window.scenario),
            key=lambda event: event_time(event) or window.begin,
        )
        for event in alerts:
            at = event_time(event)
            offset_ms = (at - window.begin).total_seconds() * 1000 if at is not None else None
            attrs = event.get("attributes") or {}
            detail = ", ".join(f"{key}={value}" for key, value in sorted(attrs.items()) if key != "message") or "n/a"
            rows.append([window.scenario, fmt_num(offset_ms), attrs.get("message", "n/a"), detail])
    return "## Alerts\n\n" + markdown_table(["Scenario", "offset ms", "message", "attributes"], rows) + "\n"


def build_report(run_root: Path) -> str:
    windows = load_scenario_windows(run_root)
    events = load_device_events(run_root)
    sections = [
        build_header(events, windows, run_root),
        build_list_load_section(events, windows),
        build_open_to_first_paint_section(events, windows),
        build_keyboard_section(events, windows),
        build_input_section(events, windows),
        build_foreground_resume_section(events, windows),
        build_handoff_section(events, windows),
        build_payload_section(events, windows),
        build_battery_section(events, windows),
        build_alerts_section(events, windows),
    ]
    return "\n".join(sections)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render a markdown performance report for one iOS device baseline run.")
    parser.add_argument("--run-root", required=True, help="Run root directory produced by ios_device_baseline.sh.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    print(build_report(Path(args.run_root)))


if __name__ == "__main__":
    main()
