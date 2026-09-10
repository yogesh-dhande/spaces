#!/usr/bin/env python3
"""Unit tests for ios_device_baseline_report.py.

Each test builds a small synthetic run root (device-perf.jsonl, shaper.jsonl, sessions.json) in
a temp directory, or hand-builds the equivalent in-memory event lists, and asserts on the parsed
windows, the per-scenario metric dicts, or the rendered markdown. Run with:

  python3 apps/macos/Tests/ios_device_baseline_report_test.py -v
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parent / "ios_device_baseline_report.py"
_spec = importlib.util.spec_from_file_location("ios_device_baseline_report", MODULE_PATH)
report = importlib.util.module_from_spec(_spec)
# dataclasses resolves field types by looking the defining module up in sys.modules, so the
# module must be registered there before exec_module runs its class bodies.
sys.modules[_spec.name] = report
_spec.loader.exec_module(report)


def write_jsonl(path: Path, records) -> None:
    path.write_text("\n".join(json.dumps(record) for record in records) + "\n", encoding="utf-8")


def app_event(session_id, source, name, at, uptime_ns, elapsed_ms=None, count=None, attributes=None):
    """Builds one device-perf.jsonl line for an app-level event (not a lane marker)."""
    record = {
        "sessionID": session_id,
        "source": source,
        "name": name,
        "emittedAt": at,
        "emittedUptimeNanoseconds": uptime_ns,
        "attributes": attributes or {},
    }
    if elapsed_ms is not None:
        record["elapsedMS"] = elapsed_ms
    if count is not None:
        record["count"] = count
    return record


def lane_marker(source, at, uptime_ns, profile, scenario, marker, extra=None):
    """Builds one device-perf.jsonl line for a lane marker, matching the shape the UI test
    (source "ios-uitest") and the runner (source "lane-runner") append into the same stream."""
    attributes = {"profile": profile, "scenario": scenario, "marker": marker}
    if extra:
        attributes.update(extra)
    return app_event("lane", source, "lane_marker", at, uptime_ns, attributes=attributes)


def shaper_bytes(at, up, down, uptime_ns=0):
    return {"event": "bytes", "at": at, "uptime_ns": uptime_ns, "up": up, "down": down}


def shaper_profile(name, at, delay_ms, bandwidth_mbit, uptime_ns=0):
    return {"event": "profile", "at": at, "uptime_ns": uptime_ns, "name": name, "delay_ms": delay_ms, "bandwidth_mbit": bandwidth_mbit}


def scenario_bracket(profile, scenario, begin_at, end_at, begin_ns=0, end_ns=0):
    """The scenario_begin/scenario_end pair every scenario's marker list starts and ends with."""
    return [
        lane_marker("ios-uitest", begin_at, begin_ns, profile, scenario, "scenario_begin"),
        lane_marker("ios-uitest", end_at, end_ns, profile, scenario, "scenario_end"),
    ]


def window_for(events, shaper_events, profile, scenario):
    windows = report.build_scenario_windows(events, shaper_events)
    return windows[(profile, scenario)]


class ParseISO8601Tests(unittest.TestCase):
    def test_parses_z_suffix_and_fractional_seconds(self) -> None:
        parsed = report.parse_iso8601("2026-09-08T10:00:00.123Z")
        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.microsecond, 123000)

    def test_returns_none_for_malformed_input(self) -> None:
        self.assertIsNone(report.parse_iso8601("not-a-timestamp"))
        self.assertIsNone(report.parse_iso8601(None))


class PercentileTests(unittest.TestCase):
    def test_nearest_rank_p50_and_max(self) -> None:
        values = [10.0, 20.0, 30.0, 40.0]
        self.assertEqual(report.percentile(values, 50), 20.0)
        self.assertEqual(report.percentile(values, 95), 40.0)
        self.assertEqual(max(values), 40.0)

    def test_empty_values_returns_none(self) -> None:
        self.assertIsNone(report.percentile([], 50))
        stats = report.stats([])
        self.assertEqual(stats, {"n": 0, "p50": None, "p95": None, "max": None})


class WindowSlicingTests(unittest.TestCase):
    def test_test_markers_define_the_window_and_scope_app_events(self) -> None:
        events = [
            *scenario_bracket("good", "cold-open", "2026-09-08T10:00:00.000Z", "2026-09-08T10:00:10.000Z"),
            # Before the window: must not be assigned to it.
            app_event("app", "ios-app", "overview_refresh_end", "2026-09-08T09:59:00.000Z", 1, attributes={"success": "1"}),
            # Inside the window: must be assigned to it.
            app_event("app", "ios-app", "overview_refresh_end", "2026-09-08T10:00:05.000Z", 2, attributes={"success": "1"}),
            # After the window: must not be assigned to it.
            app_event("app", "ios-app", "overview_refresh_end", "2026-09-08T10:01:00.000Z", 3, attributes={"success": "1"}),
        ]
        window = window_for(events, [], "good", "cold-open")
        self.assertIsNotNone(window)
        self.assertEqual(window.source, "test")
        self.assertEqual(len(window.app_events), 1)
        self.assertEqual(window.app_events[0]["emittedUptimeNanoseconds"], 2)

    def test_markers_are_grouped_by_name_regardless_of_wall_time(self) -> None:
        events = [
            *scenario_bracket("good", "back-and-forth", "2026-09-08T10:00:00.000Z", "2026-09-08T10:00:10.000Z"),
            lane_marker("ios-uitest", "2026-09-08T10:00:01.000Z", 0, "good", "back-and-forth", "open_tap", {"iteration": "1"}),
            lane_marker("ios-uitest", "2026-09-08T10:00:02.000Z", 0, "good", "back-and-forth", "open_tap", {"iteration": "2"}),
        ]
        window = window_for(events, [], "good", "back-and-forth")
        self.assertEqual(len(window.markers["open_tap"]), 2)
        keyed = report.markers_keyed(window, "open_tap", "iteration")
        self.assertEqual(set(keyed.keys()), {"1", "2"})


class RunnerFallbackTests(unittest.TestCase):
    def test_falls_back_to_runner_markers_when_test_markers_are_missing(self) -> None:
        events = [
            lane_marker("lane-runner", "2026-09-08T10:00:00.000Z", 0, "poor", "idle", "runner_scenario_start"),
            lane_marker("lane-runner", "2026-09-08T10:02:00.000Z", 0, "poor", "idle", "runner_scenario_finish", {"status": "failed"}),
        ]
        window = window_for(events, [], "poor", "idle")
        self.assertIsNotNone(window)
        self.assertEqual(window.source, "runner")
        self.assertEqual(window.begin.isoformat(), "2026-09-08T10:00:00+00:00")

    def test_no_markers_at_all_is_no_data(self) -> None:
        window = window_for([], [], "poor", "idle")
        self.assertIsNone(window)

    def test_incomplete_test_markers_fall_back_to_runner(self) -> None:
        # The test crashed mid-scenario (scenario_end never written), but the runner's own
        # start/finish stamps still bracket the attempt.
        events = [
            lane_marker("ios-uitest", "2026-09-08T10:00:00.500Z", 0, "good", "reconnect", "scenario_begin"),
            lane_marker("lane-runner", "2026-09-08T10:00:00.000Z", 0, "good", "reconnect", "runner_scenario_start"),
            lane_marker("lane-runner", "2026-09-08T10:00:05.000Z", 0, "good", "reconnect", "runner_scenario_finish", {"status": "failed"}),
        ]
        window = window_for(events, [], "good", "reconnect")
        self.assertEqual(window.source, "runner")


class MissingShaperFileTests(unittest.TestCase):
    def test_missing_shaper_file_yields_zero_bytes_not_missing_metric(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            events = [
                *scenario_bracket("good", "cold-open", "2026-09-08T10:00:00.000Z", "2026-09-08T10:00:10.000Z"),
                app_event(
                    "app", "ios-app", "app_launch", "2026-09-08T10:00:00.010Z", 1,
                    attributes={"device_model": "iPhone15,3", "ios_version": "18.0", "build": "1"},
                ),
                lane_marker("ios-uitest", "2026-09-08T10:00:01.000Z", 0, "good", "cold-open", "open_tap"),
                app_event(
                    "s1", "ios-viewer", "terminal_first_paint", "2026-09-08T10:00:01.200Z", 2,
                    elapsed_ms=200, attributes={"hold_released_by": "matching_frame"},
                ),
            ]
            write_jsonl(run_root / "device-perf.jsonl", events)
            # No shaper.jsonl written at all.
            self.assertFalse((run_root / "shaper.jsonl").exists())

            shaper_events = report.load_shaper_events(run_root)
            self.assertEqual(shaper_events, [])

            windows = report.build_scenario_windows(report.load_device_events(run_root), shaper_events)
            metrics = report.metric_cold_open(windows[("good", "cold-open")])
            # A real window with no shaper samples is a measured zero, not "no data" for the field.
            self.assertEqual(metrics["wire_kb_down"], 0.0)


class ColdOpenMetricTests(unittest.TestCase):
    def test_computes_every_column(self) -> None:
        events = [
            *scenario_bracket("good", "cold-open", "2026-09-08T10:00:00.100Z", "2026-09-08T10:00:04.100Z"),
            app_event(
                "app", "ios-app", "app_launch", "2026-09-08T10:00:00.050Z", 1_000_000_000,
                attributes={"device_model": "iPhone15,3", "ios_version": "18.0", "build": "42"},
            ),
            app_event(
                "app", "ios-app", "overview_refresh_end", "2026-09-08T10:00:00.400Z", 1_350_000_000,
                attributes={"success": "1"},
            ),
            lane_marker("ios-uitest", "2026-09-08T10:00:00.500Z", 0, "good", "cold-open", "open_tap"),
            app_event("s1", "ios-viewer", "terminal_open_begin", "2026-09-08T10:00:00.500Z", 1_450_000_000, attributes={"source": "list"}),
            # Two full frames land before the paint: both count toward the open's own cost.
            app_event(
                "s1", "ios-viewer", "render_frame_payload_receive", "2026-09-08T10:00:00.600Z", 1_550_000_000,
                count=27_000, attributes={"render_update": "1"},
            ),
            app_event(
                "s1", "ios-viewer", "render_frame_payload_receive", "2026-09-08T10:00:00.700Z", 1_650_000_000,
                count=30_000, attributes={"render_update": "1"},
            ),
            app_event(
                "s1", "ios-viewer", "terminal_first_paint", "2026-09-08T10:00:00.700Z", 1_650_000_000,
                elapsed_ms=200, attributes={"hold_released_by": "matching_frame"},
            ),
            app_event(
                "s1", "ios-viewer", "render_frame_payload_receive", "2026-09-08T10:00:01.000Z", 1_950_000_000,
                count=2048, attributes={"render_update": "1"},
            ),
            # Outside the 3s post-paint window (1_650_000_000 + 3s = 4_650_000_000): must not count.
            app_event(
                "s1", "ios-viewer", "render_frame_payload_receive", "2026-09-08T10:00:05.000Z", 5_650_000_000,
                count=9000, attributes={"render_update": "1"},
            ),
        ]
        shaper_events = [
            shaper_bytes("2026-09-08T10:00:00.500Z", up=100, down=5000),
            shaper_bytes("2026-09-08T10:00:01.500Z", up=50, down=3000),
        ]
        window = window_for(events, shaper_events, "good", "cold-open")
        metrics = report.metric_cold_open(window)
        self.assertEqual(metrics["launch_to_list_ms"], 350.0)
        self.assertEqual(metrics["open_to_paint_ms"], 200.0)
        self.assertEqual(metrics["paint_elapsed_ms"], 200.0)
        self.assertEqual(metrics["hold_released_by"], "matching_frame")
        self.assertEqual(metrics["frames_to_paint"], 2)
        self.assertAlmostEqual(metrics["decoded_kb_to_paint"], 57_000 / 1024.0)
        self.assertEqual(metrics["frames_3s"], 1)
        self.assertAlmostEqual(metrics["decoded_kb_3s"], 2.0)
        self.assertAlmostEqual(metrics["wire_kb_down"], 8000 / 1024.0)

    def test_no_data_scenario_returns_none(self) -> None:
        self.assertIsNone(report.metric_cold_open(None))


class ColdOpenOwnedMetricTests(unittest.TestCase):
    """cold-open-owned reuses metric_cold_open unchanged (parametrized by scenario name in
    build_report_sections), so this only needs to prove the scenario is wired into SCENARIOS --
    build_scenario_windows only builds a window for a scenario listed there -- and that the shared
    metric function computes the same columns against that window."""

    def test_computes_every_column(self) -> None:
        events = [
            *scenario_bracket("good", "cold-open-owned", "2026-09-08T10:00:00.100Z", "2026-09-08T10:00:04.100Z"),
            app_event(
                "app", "ios-app", "app_launch", "2026-09-08T10:00:00.050Z", 1_000_000_000,
                attributes={"device_model": "iPhone15,3", "ios_version": "18.0", "build": "42"},
            ),
            app_event(
                "app", "ios-app", "overview_refresh_end", "2026-09-08T10:00:00.400Z", 1_350_000_000,
                attributes={"success": "1"},
            ),
            lane_marker("ios-uitest", "2026-09-08T10:00:00.500Z", 0, "good", "cold-open-owned", "open_tap"),
            app_event(
                "s1", "ios-viewer", "terminal_open_begin", "2026-09-08T10:00:00.500Z", 1_450_000_000, attributes={"source": "list"}
            ),
            app_event(
                "s1", "ios-viewer", "render_frame_payload_receive", "2026-09-08T10:00:00.600Z", 1_550_000_000,
                count=27_000, attributes={"render_update": "1"},
            ),
            app_event(
                "s1", "ios-viewer", "terminal_first_paint", "2026-09-08T10:00:00.700Z", 1_650_000_000,
                elapsed_ms=200, attributes={"hold_released_by": "matching_frame"},
            ),
        ]
        shaper_events = [shaper_bytes("2026-09-08T10:00:00.500Z", up=100, down=5000)]
        window = window_for(events, shaper_events, "good", "cold-open-owned")
        self.assertIsNotNone(window)
        metrics = report.metric_cold_open(window)
        self.assertEqual(metrics["launch_to_list_ms"], 350.0)
        self.assertEqual(metrics["open_to_paint_ms"], 200.0)
        self.assertEqual(metrics["hold_released_by"], "matching_frame")
        self.assertEqual(metrics["frames_to_paint"], 1)
        self.assertAlmostEqual(metrics["wire_kb_down"], 5000 / 1024.0)


class BackAndForthMetricTests(unittest.TestCase):
    def test_per_reopen_stats_across_two_iterations(self) -> None:
        events = [
            *scenario_bracket("constrained", "back-and-forth", "2026-09-08T10:00:00.000Z", "2026-09-08T10:00:20.000Z"),
            lane_marker("ios-uitest", "2026-09-08T10:00:01.000Z", 0, "constrained", "back-and-forth", "open_tap", {"iteration": "1"}),
            app_event("s1", "ios-viewer", "terminal_first_paint", "2026-09-08T10:00:01.300Z", 0, elapsed_ms=300),
            app_event(
                "s1", "ios-viewer", "render_frame_payload_receive", "2026-09-08T10:00:01.400Z", 0,
                count=1024, attributes={"render_update": "1"},
            ),
            lane_marker("ios-uitest", "2026-09-08T10:00:02.000Z", 0, "constrained", "back-and-forth", "back_tap", {"iteration": "1"}),
            lane_marker("ios-uitest", "2026-09-08T10:00:03.000Z", 0, "constrained", "back-and-forth", "open_tap", {"iteration": "2"}),
            app_event("s1", "ios-viewer", "terminal_first_paint", "2026-09-08T10:00:03.500Z", 0, elapsed_ms=500),
            lane_marker("ios-uitest", "2026-09-08T10:00:04.000Z", 0, "constrained", "back-and-forth", "back_tap", {"iteration": "2"}),
        ]
        window = window_for(events, [], "constrained", "back-and-forth")
        metrics = report.metric_back_and_forth(window)
        # Reopen 1: 300ms, reopen 2: 500ms -> p50 is the smaller (nearest-rank rank 1 of 2), max is 500.
        self.assertEqual(metrics["open_paint_p50"], 300.0)
        self.assertEqual(metrics["open_paint_max"], 500.0)
        # Reopen 1 has one frame, reopen 2 has none.
        self.assertEqual(metrics["frames_p50"], 0)
        self.assertEqual(metrics["frames_max"], 1)


class KeyboardMetricTests(unittest.TestCase):
    def test_show_and_hide_directions_and_input_rpc(self) -> None:
        events = [
            *scenario_bracket("good", "keyboard", "2026-09-08T10:00:00.000Z", "2026-09-08T10:00:20.000Z"),
            lane_marker("ios-uitest", "2026-09-08T10:00:01.000Z", 0, "good", "keyboard", "keyboard_show_tap", {"cycle": "1"}),
            app_event("s1", "ios-viewer", "keyboard_toggle", "2026-09-08T10:00:01.100Z", 1_000_000_000, attributes={"visible": "1"}),
            app_event(
                "s1", "ios-viewer", "keyboard_shift_applied", "2026-09-08T10:00:01.250Z", 1_150_000_000,
                elapsed_ms=150, attributes={"offset_rows": "12", "visible_rows": "18", "columns": "40", "rows": "30", "visible": "1"},
            ),
            app_event(
                "s1", "ios-viewer", "input_command_rpc_end", "2026-09-08T10:00:01.400Z", 1_300_000_000,
                elapsed_ms=40, attributes={"success": "1", "input_kind": "composer_send"},
            ),
            lane_marker("ios-uitest", "2026-09-08T10:00:02.000Z", 0, "good", "keyboard", "keyboard_hide_tap", {"cycle": "1"}),
            app_event("s1", "ios-viewer", "keyboard_toggle", "2026-09-08T10:00:02.100Z", 2_000_000_000, attributes={"visible": "0"}),
            app_event(
                "s1", "ios-viewer", "keyboard_shift_applied", "2026-09-08T10:00:02.300Z", 2_200_000_000,
                elapsed_ms=200, attributes={"offset_rows": "0", "visible_rows": "30", "columns": "40", "rows": "30", "visible": "0"},
            ),
        ]
        window = window_for(events, [], "good", "keyboard")
        metrics = report.metric_keyboard(window)
        self.assertEqual(metrics["show_p50"], 150.0)
        self.assertEqual(metrics["hide_p50"], 200.0)
        self.assertEqual(metrics["input_p50"], 40.0)
        self.assertEqual(metrics["input_max"], 40.0)

    def test_toggle_without_shift_does_not_shift_later_pairs(self) -> None:
        events = [
            *scenario_bracket("good", "keyboard", "2026-09-08T10:00:00.000Z", "2026-09-08T10:00:20.000Z"),
            # A toggle that leaves the rendered window the same size emits no shift event of its own.
            app_event("s1", "ios-viewer", "keyboard_toggle", "2026-09-08T10:00:01.000Z", 1_000_000_000, attributes={"visible": "1"}),
            app_event("s1", "ios-viewer", "keyboard_toggle", "2026-09-08T10:00:05.000Z", 5_000_000_000, attributes={"visible": "0"}),
            app_event("s1", "ios-viewer", "keyboard_shift_applied", "2026-09-08T10:00:05.500Z", 5_500_000_000, elapsed_ms=500),
            app_event("s1", "ios-viewer", "keyboard_toggle", "2026-09-08T10:00:08.000Z", 8_000_000_000, attributes={"visible": "1"}),
            app_event("s1", "ios-viewer", "keyboard_shift_applied", "2026-09-08T10:00:08.400Z", 8_400_000_000, elapsed_ms=400),
        ]
        metrics = report.metric_keyboard(window_for(events, [], "good", "keyboard"))
        self.assertEqual(metrics["show_p50"], 400.0)
        self.assertEqual(metrics["hide_p50"], 500.0)


class StreamingMetricTests(unittest.TestCase):
    def test_per_burst_columns(self) -> None:
        events = [
            *scenario_bracket("poor", "streaming", "2026-09-08T10:00:00.000Z", "2026-09-08T10:01:00.000Z"),
            lane_marker("ios-uitest", "2026-09-08T10:00:01.000Z", 0, "poor", "streaming", "streaming_ready"),
            lane_marker("lane-runner", "2026-09-08T10:00:02.000Z", 0, "poor", "streaming", "burst_sent", {"burst": "1"}),
            app_event(
                "s1", "ios-viewer", "render_frame_payload_receive", "2026-09-08T10:00:02.100Z", 2_100_000_000,
                count=1024, attributes={"render_update": "1"},
            ),
            app_event(
                "s1", "ios-viewer", "render_frame_payload_receive", "2026-09-08T10:00:03.100Z", 3_100_000_000,
                count=1024, attributes={"render_update": "1"},
            ),
            lane_marker("ios-uitest", "2026-09-08T10:00:04.000Z", 0, "poor", "streaming", "burst_wait_end", {"burst": "1"}),
        ]
        shaper_events = [shaper_bytes("2026-09-08T10:00:02.500Z", up=0, down=4096)]
        window = window_for(events, shaper_events, "poor", "streaming")
        metrics = report.metric_streaming(window)
        self.assertEqual(metrics["burst1_frames"], 2)
        self.assertAlmostEqual(metrics["burst1_decoded_kb"], 2.0)
        self.assertAlmostEqual(metrics["burst1_wire_kb"], 4.0)
        self.assertAlmostEqual(metrics["burst1_duration_ms"], 1000.0)
        self.assertAlmostEqual(metrics["burst1_kb_per_frame"], 1.0)
        # Burst 2 never happened in this fixture.
        self.assertIsNone(metrics["burst2_frames"])


class ScrollbackMetricTests(unittest.TestCase):
    def test_per_flick_scroll_rpc_and_frames(self) -> None:
        events = [
            *scenario_bracket("good", "scrollback", "2026-09-08T10:00:00.000Z", "2026-09-08T10:00:20.000Z"),
            lane_marker("ios-uitest", "2026-09-08T10:00:01.000Z", 0, "good", "scrollback", "flick", {"index": "1", "direction": "down"}),
            app_event(
                "s1", "ios-viewer", "input_command_rpc_end", "2026-09-08T10:00:01.050Z", 0,
                elapsed_ms=25, attributes={"success": "1", "input_kind": "send_scroll"},
            ),
            app_event(
                "s1", "ios-viewer", "render_frame_payload_receive", "2026-09-08T10:00:01.100Z", 0,
                count=512, attributes={"render_update": "1"},
            ),
            lane_marker("ios-uitest", "2026-09-08T10:00:03.000Z", 0, "good", "scrollback", "flick", {"index": "2", "direction": "down"}),
            app_event(
                "s1", "ios-viewer", "input_command_rpc_end", "2026-09-08T10:00:03.075Z", 0,
                elapsed_ms=75, attributes={"success": "1", "input_kind": "send_scroll"},
            ),
        ]
        window = window_for(events, [], "good", "scrollback")
        metrics = report.metric_scrollback(window)
        self.assertEqual(metrics["rpc_p50"], 25.0)
        self.assertEqual(metrics["rpc_max"], 75.0)
        self.assertEqual(metrics["frames_p50"], 0)
        self.assertEqual(metrics["frames_max"], 1)

    def test_return_flicks_reusing_indices_stay_separate(self) -> None:
        events = [
            *scenario_bracket("good", "scrollback", "2026-09-08T10:00:00.000Z", "2026-09-08T10:00:20.000Z"),
            lane_marker("ios-uitest", "2026-09-08T10:00:01.000Z", 0, "good", "scrollback", "flick", {"index": "1", "direction": "down"}),
            app_event(
                "s1", "ios-viewer", "render_frame_payload_receive", "2026-09-08T10:00:01.100Z", 0,
                count=1024, attributes={"render_update": "1"},
            ),
            lane_marker("ios-uitest", "2026-09-08T10:00:03.000Z", 0, "good", "scrollback", "flick", {"index": "1", "direction": "up"}),
            app_event(
                "s1", "ios-viewer", "render_frame_payload_receive", "2026-09-08T10:00:03.100Z", 0,
                count=2048, attributes={"render_update": "1"},
            ),
            app_event(
                "s1", "ios-viewer", "render_frame_payload_receive", "2026-09-08T10:00:03.200Z", 0,
                count=2048, attributes={"render_update": "1"},
            ),
        ]
        metrics = report.metric_scrollback(window_for(events, [], "good", "scrollback"))
        self.assertEqual(metrics["frames_p50"], 1)
        self.assertEqual(metrics["frames_max"], 2)
        self.assertAlmostEqual(metrics["kb_max"], 4.0)


class BackgroundMetricTests(unittest.TestCase):
    def test_terminal_mode_resumes_to_next_frame(self) -> None:
        events = [
            *scenario_bracket("good", "background-terminal", "2026-09-08T10:00:00.000Z", "2026-09-08T10:00:20.000Z"),
            lane_marker("ios-uitest", "2026-09-08T10:00:01.000Z", 0, "good", "background-terminal", "background", {"iteration": "1"}),
            lane_marker("ios-uitest", "2026-09-08T10:00:06.000Z", 0, "good", "background-terminal", "foreground", {"iteration": "1"}),
            app_event("s1", "ios-viewer", "stream_first_frame", "2026-09-08T10:00:06.400Z", 0, elapsed_ms=400, attributes={"host": "h"}),
        ]
        window = window_for(events, [], "good", "background-terminal")
        metrics = report.metric_background(window, "terminal")
        self.assertEqual(metrics["resume_p50"], 400.0)

    def test_terminal_mode_settles_on_the_resume_read_when_no_frame_is_owed(self) -> None:
        """An unchanged screen is confirmed with no render update at all, so the resume's own state
        read completing is the settle point."""
        events = [
            *scenario_bracket("good", "background-terminal", "2026-09-08T10:00:00.000Z", "2026-09-08T10:00:20.000Z"),
            lane_marker("ios-uitest", "2026-09-08T10:00:01.000Z", 0, "good", "background-terminal", "background", {"iteration": "1"}),
            lane_marker("ios-uitest", "2026-09-08T10:00:06.000Z", 0, "good", "background-terminal", "foreground", {"iteration": "1"}),
            app_event(
                "s1",
                "ios-viewer",
                "explicit_state_refresh_end",
                "2026-09-08T10:00:06.300Z",
                0,
                elapsed_ms=300,
                attributes={"reason": "foreground_resume", "render_update": "0"},
            ),
        ]
        window = window_for(events, [], "good", "background-terminal")
        metrics = report.metric_background(window, "terminal")
        self.assertEqual(metrics["resume_p50"], 300.0)
        self.assertEqual(metrics["frames_p50"], 0)
        self.assertEqual(metrics["kb_p50"], 0.0)

    def test_terminal_mode_settles_on_the_frame_when_the_resume_read_carries_an_update(self) -> None:
        """A resume heartbeat that carries a changed screen fires its own refresh-end event before
        the frame is decoded and applied, so the settle point stays the frame, not the refresh end."""
        events = [
            *scenario_bracket("good", "background-terminal", "2026-09-08T10:00:00.000Z", "2026-09-08T10:00:20.000Z"),
            lane_marker("ios-uitest", "2026-09-08T10:00:01.000Z", 0, "good", "background-terminal", "background", {"iteration": "1"}),
            lane_marker("ios-uitest", "2026-09-08T10:00:06.000Z", 0, "good", "background-terminal", "foreground", {"iteration": "1"}),
            app_event(
                "s1",
                "ios-viewer",
                "explicit_state_refresh_end",
                "2026-09-08T10:00:06.300Z",
                0,
                elapsed_ms=300,
                attributes={"reason": "foreground_resume", "render_update": "1"},
            ),
            app_event(
                "s1", "ios-viewer", "render_frame_payload_receive", "2026-09-08T10:00:06.450Z", 0,
                elapsed_ms=450, count=1024, attributes={"render_update": "1"},
            ),
        ]
        window = window_for(events, [], "good", "background-terminal")
        metrics = report.metric_background(window, "terminal")
        self.assertEqual(metrics["resume_p50"], 450.0)

    def test_terminal_mode_ignores_a_state_refresh_end_from_another_reason(self) -> None:
        events = [
            *scenario_bracket("good", "background-terminal", "2026-09-08T10:00:00.000Z", "2026-09-08T10:00:20.000Z"),
            lane_marker("ios-uitest", "2026-09-08T10:00:01.000Z", 0, "good", "background-terminal", "background", {"iteration": "1"}),
            lane_marker("ios-uitest", "2026-09-08T10:00:06.000Z", 0, "good", "background-terminal", "foreground", {"iteration": "1"}),
            app_event(
                "s1",
                "ios-viewer",
                "explicit_state_refresh_end",
                "2026-09-08T10:00:06.100Z",
                0,
                attributes={"reason": "state_refresh"},
            ),
            app_event("s1", "ios-viewer", "stream_first_frame", "2026-09-08T10:00:06.400Z", 0, elapsed_ms=400, attributes={"host": "h"}),
        ]
        window = window_for(events, [], "good", "background-terminal")
        metrics = report.metric_background(window, "terminal")
        self.assertEqual(metrics["resume_p50"], 400.0)

    def test_list_mode_resumes_to_successful_overview_refresh(self) -> None:
        events = [
            *scenario_bracket("good", "background-list", "2026-09-08T10:00:00.000Z", "2026-09-08T10:00:20.000Z"),
            lane_marker("ios-uitest", "2026-09-08T10:00:01.000Z", 0, "good", "background-list", "background", {"iteration": "1"}),
            lane_marker("ios-uitest", "2026-09-08T10:00:06.000Z", 0, "good", "background-list", "foreground", {"iteration": "1"}),
            # A failed refresh right after foreground must not be picked; the successful one wins.
            app_event(
                "app", "ios-app", "overview_refresh_end", "2026-09-08T10:00:06.200Z", 0, attributes={"success": "0"}
            ),
            app_event(
                "app", "ios-app", "overview_refresh_end", "2026-09-08T10:00:06.500Z", 0, attributes={"success": "1"}
            ),
        ]
        window = window_for(events, [], "good", "background-list")
        metrics = report.metric_background(window, "list")
        self.assertEqual(metrics["resume_p50"], 500.0)


class ReconnectMetricTests(unittest.TestCase):
    def test_full_cycle(self) -> None:
        events = [
            *scenario_bracket("poor", "reconnect", "2026-09-08T10:00:00.000Z", "2026-09-08T10:01:00.000Z"),
            lane_marker("ios-uitest", "2026-09-08T10:00:10.000Z", 0, "poor", "reconnect", "link_down"),
            app_event(
                "s1", "ios-viewer", "connection_stage", "2026-09-08T10:00:11.500Z", 0,
                attributes={"stage": "reconnecting", "banner": "1"},
            ),
            lane_marker("ios-uitest", "2026-09-08T10:00:20.000Z", 0, "poor", "reconnect", "link_up"),
            app_event(
                "s1", "ios-viewer", "stream_first_frame", "2026-09-08T10:00:22.000Z", 0, elapsed_ms=2000,
                attributes={"host": "h"},
            ),
            app_event(
                "s1", "ios-viewer", "connection_stage", "2026-09-08T10:00:22.500Z", 0,
                attributes={"stage": "connected", "banner": "0"},
            ),
            app_event(
                "s1", "ios-viewer", "render_frame_payload_receive", "2026-09-08T10:00:22.100Z", 0,
                count=1024, attributes={"render_update": "1"},
            ),
            lane_marker("ios-uitest", "2026-09-08T10:00:23.000Z", 0, "poor", "reconnect", "recovered"),
        ]
        window = window_for(events, [], "poor", "reconnect")
        metrics = report.metric_reconnect(window)
        self.assertAlmostEqual(metrics["link_down_to_banner_ms"], 1500.0)
        self.assertAlmostEqual(metrics["link_up_to_first_frame_ms"], 2000.0)
        self.assertAlmostEqual(metrics["link_up_to_banner_clear_ms"], 2500.0)
        self.assertEqual(metrics["recovery_frames"], 1)
        self.assertAlmostEqual(metrics["recovery_kb"], 1.0)
        self.assertEqual(metrics["connection_error_alerts"], 0)


class IdleMetricTests(unittest.TestCase):
    def test_bytes_per_second_and_frame_count_over_the_idle_window(self) -> None:
        events = [
            *scenario_bracket("good", "idle", "2026-09-08T10:00:00.000Z", "2026-09-08T10:02:10.000Z"),
            lane_marker("ios-uitest", "2026-09-08T10:00:05.000Z", 0, "good", "idle", "idle_begin"),
            app_event(
                "s1", "ios-viewer", "render_frame_payload_receive", "2026-09-08T10:01:00.000Z", 0,
                count=1024, attributes={"render_update": "1"},
            ),
            lane_marker("ios-uitest", "2026-09-08T10:02:05.000Z", 0, "good", "idle", "idle_end"),
        ]
        shaper_events = [shaper_bytes("2026-09-08T10:01:00.000Z", up=1200, down=2400)]
        window = window_for(events, shaper_events, "good", "idle")
        metrics = report.metric_idle(window)
        # idle window is exactly 120s (10:00:05 to 10:02:05).
        self.assertAlmostEqual(metrics["up_bytes_per_sec"], 10.0)
        self.assertAlmostEqual(metrics["down_bytes_per_sec"], 20.0)
        self.assertEqual(metrics["decoded_frames"], 1)


class FullRenderSmokeTest(unittest.TestCase):
    def test_report_has_every_section_and_one_computed_cell(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            events = [
                *scenario_bracket("good", "cold-open", "2026-09-08T10:00:00.100Z", "2026-09-08T10:00:04.100Z"),
                app_event(
                    "app", "ios-app", "app_launch", "2026-09-08T10:00:00.050Z", 1_000_000_000,
                    attributes={"device_model": "iPhone15,3", "ios_version": "18.0", "build": "42"},
                ),
                app_event(
                    "app", "ios-app", "overview_refresh_end", "2026-09-08T10:00:00.400Z", 1_350_000_000,
                    attributes={"success": "1"},
                ),
                lane_marker("ios-uitest", "2026-09-08T10:00:00.500Z", 0, "good", "cold-open", "open_tap"),
                app_event(
                    "s1", "ios-viewer", "terminal_first_paint", "2026-09-08T10:00:00.700Z", 1_650_000_000,
                    elapsed_ms=200, attributes={"hold_released_by": "matching_frame"},
                ),
            ]
            write_jsonl(run_root / "device-perf.jsonl", events)
            write_jsonl(run_root / "shaper.jsonl", [shaper_profile("good", "2026-09-08T09:59:59.000Z", 10, 50)])
            (run_root / "sessions.json").write_text(
                json.dumps({"target": {"kind": "local", "host": "127.0.0.1"}, "scenarios": []}), encoding="utf-8"
            )

            report_text = report.build_report(run_root)
            for heading in (
                "# iOS performance baseline:",
                "## Cold open",
                "## Cold open (Mac-owned session)",
                "## Back and forth",
                "## Keyboard",
                "## Streaming",
                "## Scrollback",
                "## Background/foreground: terminal",
                "## Background/foreground: list",
                "## Reconnect",
                "## Idle",
            ):
                self.assertIn(heading, report_text)
            # launch_to_list_ms = 350.0, computed from the app_launch/overview_refresh_end pair above.
            self.assertIn("| good | 350.0 | 200.0 | 200.0 | matching_frame | n/a | n/a | 0 | 0.0 | 0.0 |", report_text)


class EmptyRunRootTests(unittest.TestCase):
    def test_missing_files_render_no_data_without_raising(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            report_text = report.build_report(run_root)
            self.assertIn("Missing input files | device-perf.jsonl, shaper.jsonl, sessions.json", report_text)
            self.assertIn("no data", report_text)


if __name__ == "__main__":
    unittest.main()
