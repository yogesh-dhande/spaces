#!/usr/bin/env python3
"""Unit tests for ios_device_baseline_report.py.

Each test builds a small fixture run root (runner-events.jsonl plus
device-perf.jsonl and, where relevant, a rotated device-perf.jsonl.1) in a
temp directory and asserts on the rendered markdown. Run with:

  python3 apps/macos/Tests/ios_device_baseline_report_test.py
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


def write_jsonl(path: Path, records: list[dict]) -> None:
    path.write_text("\n".join(json.dumps(record) for record in records) + "\n", encoding="utf-8")


def runner_event(t: str, kind: str, scenario: str | None = None, detail: str | None = None) -> dict:
    return {"t": t, "kind": kind, "scenario": scenario, "detail": detail}


def device_event(
    session_id: str,
    source: str,
    name: str,
    emitted_at: str,
    uptime_ns: int,
    elapsed_ms=None,
    count=None,
    attributes: dict | None = None,
) -> dict:
    record = {
        "sessionID": session_id,
        "source": source,
        "name": name,
        "emittedAt": emitted_at,
        "emittedUptimeNanoseconds": uptime_ns,
        "attributes": attributes or {},
    }
    if elapsed_ms is not None:
        record["elapsedMS"] = elapsed_ms
    if count is not None:
        record["count"] = count
    return record


class ParseISO8601Tests(unittest.TestCase):
    def test_parses_z_suffix_and_fractional_seconds(self) -> None:
        parsed = report.parse_iso8601("2026-09-02T10:00:00.123Z")
        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.microsecond, 123000)

    def test_returns_none_for_malformed_input(self) -> None:
        self.assertIsNone(report.parse_iso8601("not-a-timestamp"))
        self.assertIsNone(report.parse_iso8601(None))


class ScenarioAssignmentTests(unittest.TestCase):
    def test_assigns_events_inside_window_and_within_slack(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:00:00.000Z", "scenario_begin", "cold-open"),
                    runner_event("2026-09-02T10:05:00.000Z", "scenario_end", "cold-open"),
                    runner_event("2026-09-02T10:05:00.000Z", "scenario_begin", "back-and-forth"),
                    runner_event("2026-09-02T10:10:00.000Z", "scenario_end", "back-and-forth"),
                ],
            )
            windows = report.load_scenario_windows(run_root)
            self.assertEqual([window.scenario for window in windows], ["cold-open", "back-and-forth"])

            # 1.5s before the window begin is inside the 2s slack.
            just_before = report.parse_iso8601("2026-09-02T09:59:58.500Z")
            self.assertEqual(report.assign_scenario(just_before, windows), "cold-open")

            # 3s before the window begin is outside the slack, so it is unassigned.
            too_early = report.parse_iso8601("2026-09-02T09:59:57.000Z")
            self.assertIsNone(report.assign_scenario(too_early, windows))

            # Squarely inside the second window.
            mid_second = report.parse_iso8601("2026-09-02T10:07:00.000Z")
            self.assertEqual(report.assign_scenario(mid_second, windows), "back-and-forth")

    def test_adjacent_windows_prefer_the_real_window_over_slack(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:00:00.000Z", "scenario_begin", "cold-open"),
                    # back-and-forth's begin is stamped right at cold-open's end: the runner
                    # always produces adjacent windows with no gap between them.
                    runner_event("2026-09-02T10:05:00.000Z", "scenario_end", "cold-open"),
                    runner_event("2026-09-02T10:05:00.000Z", "scenario_begin", "back-and-forth"),
                    runner_event("2026-09-02T10:10:00.000Z", "scenario_end", "back-and-forth"),
                ],
            )
            windows = report.load_scenario_windows(run_root)

            # 0.5s after back-and-forth's real begin: squarely inside back-and-forth's own
            # window, even though it is also within slack of cold-open's end. The real window
            # must win outright, not the first-match-wins scan order.
            just_after_begin = report.parse_iso8601("2026-09-02T10:05:00.500Z")
            self.assertEqual(report.assign_scenario(just_after_begin, windows), "back-and-forth")

            # 0.5s before cold-open's real begin: outside every real window (cold-open is the
            # first scenario), but inside cold-open's slack. Falls back to the slack search.
            just_before_begin = report.parse_iso8601("2026-09-02T09:59:59.500Z")
            self.assertEqual(report.assign_scenario(just_before_begin, windows), "cold-open")

    def test_missing_end_stamp_extends_to_next_scenario_begin(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:00:00.000Z", "scenario_begin", "cold-open"),
                    # No scenario_end for cold-open: the run was interrupted mid-scenario.
                    runner_event("2026-09-02T10:05:00.000Z", "scenario_begin", "back-and-forth"),
                    # back-and-forth is also interrupted (and is the last scenario in the run),
                    # so its window stays open with no upper bound at all.
                ],
            )
            windows = report.load_scenario_windows(run_root)
            cold_open, back_and_forth = windows
            self.assertEqual(cold_open.end, back_and_forth.begin)
            self.assertIsNone(back_and_forth.end)


class FirstPaintPercentileTests(unittest.TestCase):
    def test_reports_p50_p95_max_split_by_hold_released_by(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:00:00.000Z", "scenario_begin", "cold-open"),
                    runner_event("2026-09-02T10:05:00.000Z", "scenario_end", "cold-open"),
                ],
            )
            # 10 matching_frame samples: 100..1000ms in steps of 100.
            events = []
            base_ns = 1_000_000_000
            for index, value in enumerate([100, 200, 300, 400, 500, 600, 700, 800, 900, 1000]):
                events.append(
                    device_event(
                        "SESSION-1",
                        "ios-viewer",
                        "terminal_first_paint",
                        f"2026-09-02T10:01:{index:02d}.000Z",
                        base_ns + index,
                        elapsed_ms=value,
                        attributes={"hold_released_by": "matching_frame", "frame": "full"},
                    )
                )
            write_jsonl(run_root / "device-perf.jsonl", events)

            markdown = report.build_report(run_root)
            self.assertIn("hold_released_by=matching_frame", markdown)
            # Nearest-rank p50 of 10 sorted values [100..1000] is the 5th value (500);
            # p95 is the 10th value (1000, since ceil(0.95*10) == 10).
            self.assertIn("| cold-open | 10 | 500.0 | 1000.0 | 1000.0 |", markdown)


class TerminalBackDwellScenarioBoundaryTests(unittest.TestCase):
    def test_back_whose_open_predates_the_window_is_excluded_from_dwell(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:00:00.000Z", "scenario_begin", "cold-open"),
                    runner_event("2026-09-02T10:05:00.000Z", "scenario_end", "cold-open"),
                    runner_event("2026-09-02T10:05:00.000Z", "scenario_begin", "back-and-forth"),
                    runner_event("2026-09-02T10:10:00.000Z", "scenario_end", "back-and-forth"),
                ],
            )
            events = [
                # This back lands 10s into back-and-forth, but its 20s elapsedMS means the
                # terminal it closes was opened at 10:04:50, before the window began: that
                # open is the runner's cold-open-or-prompt open from before the scenario, not
                # a real back-and-forth cycle, so this sample must not count.
                device_event(
                    "SESSION-1",
                    "ios-viewer",
                    "terminal_back",
                    "2026-09-02T10:05:10.000Z",
                    10_000_000_000,
                    elapsed_ms=20_000,
                ),
                # This back's open (10:05:25) is squarely inside the window: a real
                # back-and-forth cycle, so it is the only sample that should count.
                device_event(
                    "SESSION-1",
                    "ios-viewer",
                    "terminal_back",
                    "2026-09-02T10:05:30.000Z",
                    30_000_000_000,
                    elapsed_ms=5_000,
                ),
            ]
            write_jsonl(run_root / "device-perf.jsonl", events)

            markdown = report.build_report(run_root)
            self.assertIn("| back-and-forth | 1 | 5000.0 | 5000.0 | 5000.0 |", markdown)


class HandoffCalculationTests(unittest.TestCase):
    def test_pairs_disconnect_with_next_first_frame_for_the_same_session(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:00:00.000Z", "scenario_begin", "wifi-handoff"),
                    runner_event("2026-09-02T10:05:00.000Z", "scenario_end", "wifi-handoff"),
                ],
            )
            base_ns = 5_000_000_000
            events = [
                device_event(
                    "SESSION-1", "ios-viewer", "stream_disconnect", "2026-09-02T10:01:00.000Z", base_ns, attributes={"error": "wifi_lost"}
                ),
                # A disconnect for a different session in between must not be picked up.
                device_event("SESSION-2", "ios-viewer", "stream_first_frame", "2026-09-02T10:01:00.500Z", base_ns + 500_000_000, attributes={"host": "other"}),
                device_event(
                    "SESSION-1",
                    "ios-viewer",
                    "stream_first_frame",
                    "2026-09-02T10:01:02.500Z",
                    base_ns + 2_500_000_000,
                    attributes={"host": "cellular-relay"},
                ),
            ]
            write_jsonl(run_root / "device-perf.jsonl", events)

            markdown = report.build_report(run_root)
            self.assertIn("cellular-relay", markdown)
            self.assertIn("| wifi-handoff | 1 | 2500.0 | 2500.0 | 2500.0 | cellular-relay |", markdown)


class HandoffOutageCollapseTests(unittest.TestCase):
    def test_failed_redial_disconnects_collapse_to_one_sample_from_the_first_disconnect(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:00:00.000Z", "scenario_begin", "wifi-handoff"),
                    runner_event("2026-09-02T10:10:00.000Z", "scenario_end", "wifi-handoff"),
                ],
            )
            base_ns = 5_000_000_000
            events = [
                # First outage: a real disconnect followed by two failed-redial disconnects
                # (same session), all before the eventual recovery frame arrives.
                device_event(
                    "SESSION-1", "ios-viewer", "stream_disconnect", "2026-09-02T10:01:00.000Z", base_ns, attributes={"error": "wifi_lost"}
                ),
                device_event(
                    "SESSION-1", "ios-viewer", "stream_disconnect", "2026-09-02T10:01:00.200Z", base_ns + 200_000_000, attributes={"error": "redial_failed"}
                ),
                device_event(
                    "SESSION-1", "ios-viewer", "stream_disconnect", "2026-09-02T10:01:00.400Z", base_ns + 400_000_000, attributes={"error": "redial_failed"}
                ),
                device_event(
                    "SESSION-1",
                    "ios-viewer",
                    "stream_first_frame",
                    "2026-09-02T10:01:02.000Z",
                    base_ns + 2_000_000_000,
                    attributes={"host": "wifi-relay1"},
                ),
                # Second outage, later in the same scenario and session: its own single sample.
                device_event(
                    "SESSION-1", "ios-viewer", "stream_disconnect", "2026-09-02T10:02:00.000Z", base_ns + 60_000_000_000, attributes={"error": "wifi_lost"}
                ),
                device_event(
                    "SESSION-1",
                    "ios-viewer",
                    "stream_first_frame",
                    "2026-09-02T10:02:01.500Z",
                    base_ns + 61_500_000_000,
                    attributes={"host": "wifi-relay2"},
                ),
            ]
            write_jsonl(run_root / "device-perf.jsonl", events)

            markdown = report.build_report(run_root)
            # n=2 total (one sample per outage, not one per disconnect), the first outage's
            # duration measured from its FIRST disconnect (2000ms, not 1800ms or 1600ms from the
            # failed-redial disconnects), the second outage's own 1500ms.
            self.assertIn("| wifi-handoff | 2 | 1500.0 | 2000.0 | 2000.0 | wifi-relay1, wifi-relay2 |", markdown)


class ForegroundResumeScenarioBoundaryTests(unittest.TestCase):
    def test_resume_target_outside_source_scenario_window_is_dropped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:00:00.000Z", "scenario_begin", "background-foreground-terminal"),
                    runner_event("2026-09-02T10:05:00.000Z", "scenario_end", "background-foreground-terminal"),
                    runner_event("2026-09-02T10:05:00.000Z", "scenario_begin", "background-foreground-list"),
                    runner_event("2026-09-02T10:10:00.000Z", "scenario_end", "background-foreground-list"),
                ],
            )
            events = [
                # Resume in background-foreground-terminal whose stream_first_frame never
                # arrives before the scenario ends.
                device_event(
                    "SESSION-1",
                    "ios-app",
                    "app_scene_phase",
                    "2026-09-02T10:04:58.000Z",
                    0,
                    attributes={"phase": "active", "open_terminal": "1"},
                ),
                # A resume of its own, fully inside background-foreground-list, so the fix's
                # window check does not also eat a legitimate same-scenario pairing.
                device_event(
                    "SESSION-1",
                    "ios-app",
                    "app_scene_phase",
                    "2026-09-02T10:06:00.000Z",
                    60_000_000_000,
                    attributes={"phase": "active", "open_terminal": "1"},
                ),
                device_event(
                    "SESSION-1",
                    "ios-viewer",
                    "stream_first_frame",
                    "2026-09-02T10:06:00.100Z",
                    60_100_000_000,
                    attributes={"host": "wifi"},
                ),
                # The only frame that could pair with the first resume: it lands well inside
                # background-foreground-list, not background-foreground-terminal.
                device_event(
                    "SESSION-1",
                    "ios-viewer",
                    "stream_first_frame",
                    "2026-09-02T10:07:00.000Z",
                    120_000_000_000,
                    attributes={"host": "wifi"},
                ),
            ]
            write_jsonl(run_root / "device-perf.jsonl", events)

            markdown = report.build_report(run_root)
            # The cross-scenario source scenario reports no resume; the frame that landed in
            # the other scenario is not attributed back to it as a huge duration.
            self.assertIn("| background-foreground-terminal | 0 | n/a | n/a | n/a |", markdown)
            # The other scenario's own legitimate, same-scenario pairing is unaffected.
            self.assertIn("| background-foreground-list | 1 | 100.0 | 100.0 | 100.0 |", markdown)


class HeaderAppLaunchSelectionTests(unittest.TestCase):
    def test_prefers_the_launch_inside_the_run_window_over_a_stale_one(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:10:00.000Z", "scenario_begin", "cold-open"),
                    runner_event("2026-09-02T10:15:00.000Z", "scenario_end", "cold-open"),
                ],
            )
            # A stale app_launch from a previous install, persisted in the device log and, like
            # the real rotated file, loaded before this run's own app_launch.
            write_jsonl(
                run_root / "device-perf.jsonl.1",
                [
                    device_event(
                        "app",
                        "ios-app",
                        "app_launch",
                        "2026-09-02T09:00:00.000Z",
                        0,
                        attributes={"device_model": "iPhone 14", "ios_version": "17.0", "build": "100"},
                    ),
                ],
            )
            write_jsonl(
                run_root / "device-perf.jsonl",
                [
                    device_event(
                        "app",
                        "ios-app",
                        "app_launch",
                        "2026-09-02T10:10:30.000Z",
                        1_000_000_000_000,
                        attributes={"device_model": "iPhone 15 Pro", "ios_version": "18.0", "build": "200"},
                    ),
                ],
            )

            markdown = report.build_report(run_root)
            self.assertIn("| Device model | iPhone 15 Pro |", markdown)
            self.assertIn("| Build | 200 |", markdown)
            self.assertNotIn("iPhone 14", markdown)


class BatteryDrainPerHourTests(unittest.TestCase):
    def test_computes_drain_per_hour_from_first_and_last_sample(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:00:00.000Z", "scenario_begin", "battery-30min"),
                    runner_event("2026-09-02T10:30:00.000Z", "scenario_end", "battery-30min"),
                ],
            )
            events = [
                device_event(
                    "app",
                    "ios-app",
                    "battery_sample",
                    "2026-09-02T10:00:00.000Z",
                    0,
                    attributes={"battery_level": "0.80", "battery_state": "unplugged", "thermal_state": "nominal", "low_power": "0"},
                ),
                device_event(
                    "app",
                    "ios-app",
                    "battery_sample",
                    "2026-09-02T10:30:00.000Z",
                    1_800_000_000_000,
                    attributes={"battery_level": "0.75", "battery_state": "unplugged", "thermal_state": "nominal", "low_power": "0"},
                ),
            ]
            write_jsonl(run_root / "device-perf.jsonl", events)

            markdown = report.build_report(run_root)
            # 5 percentage points over 0.5 hours is 10%/hr.
            self.assertIn("10.0%/hr", markdown)

    def test_reports_charging_instead_of_a_drain_rate(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:00:00.000Z", "scenario_begin", "battery-30min"),
                    runner_event("2026-09-02T10:30:00.000Z", "scenario_end", "battery-30min"),
                ],
            )
            events = [
                device_event(
                    "app",
                    "ios-app",
                    "battery_sample",
                    "2026-09-02T10:00:00.000Z",
                    0,
                    attributes={"battery_level": "0.80", "battery_state": "charging", "thermal_state": "nominal", "low_power": "0"},
                ),
                device_event(
                    "app",
                    "ios-app",
                    "battery_sample",
                    "2026-09-02T10:30:00.000Z",
                    1_800_000_000_000,
                    attributes={"battery_level": "0.90", "battery_state": "charging", "thermal_state": "nominal", "low_power": "0"},
                ),
            ]
            write_jsonl(run_root / "device-perf.jsonl", events)

            markdown = report.build_report(run_root)
            self.assertIn("| battery-30min | 0.80 | 0.90 | n/a | charging |", markdown)


class ThermalMaxFoldsInChangeEventsTests(unittest.TestCase):
    def test_excursion_between_two_nominal_samples_is_reflected_in_max_thermal(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:00:00.000Z", "scenario_begin", "thermal-test"),
                    runner_event("2026-09-02T10:30:00.000Z", "scenario_end", "thermal-test"),
                ],
            )
            events = [
                device_event(
                    "app",
                    "ios-app",
                    "battery_sample",
                    "2026-09-02T10:00:00.000Z",
                    0,
                    attributes={"battery_level": "0.80", "battery_state": "unplugged", "thermal_state": "nominal", "low_power": "0"},
                ),
                # The excursion begins and ends between these two 60-second-cadence samples, so neither
                # sample's own `thermal_state` attribute ever observes it: only the `thermal_state_change`
                # event below does.
                device_event(
                    "app",
                    "ios-app",
                    "thermal_state_change",
                    "2026-09-02T10:15:00.000Z",
                    900_000_000_000,
                    attributes={"thermal_state": "serious"},
                ),
                device_event(
                    "app",
                    "ios-app",
                    "battery_sample",
                    "2026-09-02T10:30:00.000Z",
                    1_800_000_000_000,
                    attributes={"battery_level": "0.75", "battery_state": "unplugged", "thermal_state": "nominal", "low_power": "0"},
                ),
            ]
            write_jsonl(run_root / "device-perf.jsonl", events)

            markdown = report.build_report(run_root)
            self.assertIn("| thermal-test | serious | serious |", markdown)


class EmptyScenarioTests(unittest.TestCase):
    def test_scenario_with_no_device_events_reports_n_a_everywhere(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:00:00.000Z", "scenario_begin", "keyboard-toggle"),
                    runner_event("2026-09-02T10:05:00.000Z", "scenario_end", "keyboard-toggle"),
                ],
            )
            # No device-perf.jsonl at all: the phone log never made it back, or the
            # scenario produced nothing (a UI-only step with no matching event name).
            markdown = report.build_report(run_root)
            self.assertIn("| keyboard-toggle | 0 | n/a | n/a | n/a |", markdown)
            self.assertNotIn("Traceback", markdown)


class RotatedLogOrderingTests(unittest.TestCase):
    def test_rotated_file_is_read_before_the_current_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:00:00.000Z", "scenario_begin", "streaming"),
                    runner_event("2026-09-02T10:10:00.000Z", "scenario_end", "streaming"),
                ],
            )
            # The rotated (.1) file holds older render_frame_payload_receive frames; the current file
            # holds newer ones. Loaded in the wrong order, the byte totals would still
            # match (order-independent sum) but a paired-event calculation walking the
            # events in file order would see them out of chronological order.
            write_jsonl(
                run_root / "device-perf.jsonl.1",
                [
                    device_event(
                        "SESSION-1", "ios-viewer", "render_frame_payload_receive", "2026-09-02T10:01:00.000Z", 1_000,
                        count=100, attributes={"render_update": "1"},
                    ),
                ],
            )
            write_jsonl(
                run_root / "device-perf.jsonl",
                [
                    device_event(
                        "SESSION-1", "ios-viewer", "render_frame_payload_receive", "2026-09-02T10:02:00.000Z", 2_000,
                        count=200, attributes={"render_update": "1"},
                    ),
                ],
            )
            events = report.load_device_events(run_root)
            self.assertEqual([event["emittedUptimeNanoseconds"] for event in events], [1_000, 2_000])

            markdown = report.build_report(run_root)
            self.assertIn("| streaming | 2 |", markdown)
            self.assertIn("300", markdown)  # total bytes across both files


class PayloadSectionRenderUpdateFilterTests(unittest.TestCase):
    def test_frameless_state_payload_is_excluded_from_frame_stats(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:00:00.000Z", "scenario_begin", "cold-open"),
                    runner_event("2026-09-02T10:05:00.000Z", "scenario_end", "cold-open"),
                ],
            )
            events = [
                # A state payload with no render update at all: must not count as a frame or
                # contribute its (large) byte count to the payload statistics.
                device_event(
                    "SESSION-1", "ios-viewer", "render_frame_payload_receive", "2026-09-02T10:01:00.000Z", 1_000,
                    count=9_000, attributes={"render_update": "0"},
                ),
                device_event(
                    "SESSION-1", "ios-viewer", "render_frame_payload_receive", "2026-09-02T10:01:01.000Z", 2_000,
                    count=100, attributes={"render_update": "1"},
                ),
                device_event(
                    "SESSION-1", "ios-viewer", "render_frame_payload_receive", "2026-09-02T10:01:02.000Z", 3_000,
                    count=300, attributes={"render_update": "1"},
                ),
            ]
            write_jsonl(run_root / "device-perf.jsonl", events)

            markdown = report.build_report(run_root)
            # n=2 frames, and percentiles (p50/p95/max) computed from the two framed events only.
            self.assertIn("| cold-open | 2 | 100 | 300 | 300 | 400 |", markdown)


class InputSectionSuccessFilterTests(unittest.TestCase):
    def test_failed_send_excluded_from_latency_and_counted_as_failed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            write_jsonl(
                run_root / "runner-events.jsonl",
                [
                    runner_event("2026-09-02T10:00:00.000Z", "scenario_begin", "cold-open"),
                    runner_event("2026-09-02T10:05:00.000Z", "scenario_end", "cold-open"),
                ],
            )
            events = [
                device_event(
                    "SESSION-1", "ios-viewer", "input_command_rpc_end", "2026-09-02T10:01:00.000Z", 1_000,
                    elapsed_ms=50, attributes={"success": "1"},
                ),
                device_event(
                    "SESSION-1", "ios-viewer", "input_command_rpc_end", "2026-09-02T10:01:01.000Z", 2_000,
                    elapsed_ms=150, attributes={"success": "1"},
                ),
                # A failed send: its elapsedMS is the largest of the three, but it must not
                # inflate the latency stats since it never completed successfully.
                device_event(
                    "SESSION-1", "ios-viewer", "input_command_rpc_end", "2026-09-02T10:01:02.000Z", 3_000,
                    elapsed_ms=500, attributes={"success": "0"},
                ),
            ]
            write_jsonl(run_root / "device-perf.jsonl", events)

            markdown = report.build_report(run_root)
            # n=2 successes, max=150.0 (the larger success, not the failure's 500), failed=1.
            self.assertIn("| cold-open | 2 | 50.0 | 150.0 | 150.0 | 1 |", markdown)


if __name__ == "__main__":
    unittest.main()
