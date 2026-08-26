#!/usr/bin/env python3
"""Driver for profile_device_api_control_lanes.sh.

Holds one persistent Device API request connection per streaming producer session, resyncing each with
`.state` in a loop the way a visible pane does, while a separate connection types into an idle session and
a third polls `.overview` the way a reloading sidebar does. The typed round trip is the number the freeze
is about; the lane wait read out of the perf log is what attributes it.

The corroboration `.ping` is deliberately not measured here. Timing it through the CLI would time a fresh
process launch per sample, which swamps the round trip it is meant to report, and answering a ping clear of
the shared queue is already pinned by a unit test that goes red on the unfixed daemon.
"""

import json
import math
import os
import re
import statistics
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid

HOST = "127.0.0.1"
PORT = int(os.environ["DEVICE_API_PORT"])
SPACES_E2E = os.environ["SPACES_E2E"]
PRODUCER_SESSION_IDS = [value for value in os.environ["PRODUCER_SESSION_IDS"].split(",") if value]
TYPING_SESSION_ID = os.environ["TYPING_SESSION_ID"]
PERF_LOG = os.environ["PERF_LOG"]
# The `pgrep -f` pattern that matches this run's producer fixtures and nothing else, seeded per run so a
# concurrent bench in another worktree is never counted.
PRODUCER_FIXTURE_PATTERN = os.environ["PRODUCER_FIXTURE_PATTERN"]
SAMPLES = int(os.environ["SAMPLES"])
SUMMARY_PATH = os.environ["SUMMARY_PATH"]
# Discarded from every distribution: the first round trips pay for connection setup, the first frame
# export, and a producer that has not reached its steady output rate yet.
WARMUP_SAMPLES = 5

window = json.load(open(os.environ["PAIRING_WINDOW_JSON"]))
FINGERPRINT = window["certificateFingerprint"]
PROTOCOL_VERSION = int(urllib.parse.parse_qs(urllib.parse.urlparse(window["pairingLink"]).query)["pv"][0])

CLIENT_APP = {
    "installationID": str(uuid.uuid4()).upper(),
    "bundleID": "dev.usespaces.spacesmobile",
    "platform": "ios",
    "deviceName": "Control Lane Bench",
    "appVersion": "1.0",
}


def one_shot_request(payload: dict) -> tuple[dict, float]:
    """A request on its own fresh pinned-TLS connection. Used for the one-off pairing handshake, never for
    a timed sample: the CLI process launch it pays for dwarfs any round trip it would report."""
    started = time.perf_counter()
    completed = subprocess.run(
        [SPACES_E2E, "mobile-request", "--host", HOST, "--port", str(PORT),
         f"--certificate-fingerprint={FINGERPRINT}", "--request-json", json.dumps(payload)],
        capture_output=True, text=True, check=True)
    return json.loads(completed.stdout), (time.perf_counter() - started) * 1000


class RequestSession:
    """One persistent request connection, the shape a pane's own client holds."""

    def __init__(self) -> None:
        self.process = subprocess.Popen(
            [SPACES_E2E, "mobile-request", "--host", HOST, "--port", str(PORT),
             f"--certificate-fingerprint={FINGERPRINT}", "--request-lines"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

    def send(self, payload: dict) -> tuple[dict, float]:
        started = time.perf_counter()
        self.process.stdin.write(json.dumps(payload) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        elapsed_ms = (time.perf_counter() - started) * 1000
        if not line:
            raise RuntimeError("Device API request connection closed.")
        return json.loads(line), elapsed_ms

    def close(self) -> None:
        try:
            self.process.stdin.close()
            self.process.wait(timeout=5)
        except Exception:
            self.process.kill()


pair_response, _ = one_shot_request({
    "command": {"pair": {"pairingCode": window["pairingCode"], "pairingNonce": window["pairingNonce"],
                         "clientProtocolVersion": PROTOCOL_VERSION}},
    "clientApp": CLIENT_APP,
})
assert pair_response["ok"], pair_response
AUTH_TOKEN = pair_response["result"]["issuedAuthToken"]["authToken"]

TYPING_CLIENT_ID = str(uuid.uuid4()).upper()


def control(action: str, session_id: str, client_id: str = TYPING_CLIENT_ID, **extra) -> dict:
    payload = {"action": action, "sessionID": session_id, "clientID": client_id,
               "appendNewline": False, "asPaste": False}
    payload.update(extra)
    return {"command": {"terminalControl": payload}, "authToken": AUTH_TOKEN, "clientApp": CLIENT_APP}


def owner_attach(session_id: str, client_id: str, columns: int, rows: int) -> dict:
    return control("attach", session_id, client_id,
                   client={"id": client_id, "kind": "localWindow",
                           "identity": {"label": "Control Lane Bench", "hostName": "localhost",
                                        "deviceName": "Mac", "networkAddress": "127.0.0.1"},
                           "connectedAt": "2026-08-24T00:00:00Z", "disconnectedAt": None},
                   attachmentMode="owner", columns=columns, rows=rows)


def state(session_id: str) -> dict:
    return {"command": {"state": {"sessionID": session_id}}, "authToken": AUTH_TOKEN, "clientApp": CLIENT_APP}


# Every session is attached at the size a real pane opens at rather than the 80x24 default: a `.state`
# export is grid-sized, and the grid is most of what a resyncing pane makes the engine do.
PANE_COLUMNS, PANE_ROWS = 200, 60

typing_session = RequestSession()
attach, _ = typing_session.send(owner_attach(TYPING_SESSION_ID, TYPING_CLIENT_ID, PANE_COLUMNS, PANE_ROWS))
assert attach["ok"], attach

stop = threading.Event()
resync_counts = [0] * len(PRODUCER_SESSION_IDS)
resync_rejections = [0] * len(PRODUCER_SESSION_IDS)
resync_errors: list[str] = [""] * len(PRODUCER_SESSION_IDS)
# Each producer's latest screen revision, which advances only while that producer actually writes. It is
# what proves the load was applied: a fixture that died still has a session the daemon answers `.state`
# for, so counting answered resyncs alone cannot tell a streaming producer from a silent one.
resync_revisions = [0] * len(PRODUCER_SESSION_IDS)


def resync_loop(index: int, session_id: str) -> None:
    """One producer's pane resyncing while it streams. A rejected or unreadable `.state` is a failure, not
    a resync: counting it as load is how a run with half its producers dead still looks like a full run."""
    session = RequestSession()
    try:
        attached, _ = session.send(owner_attach(session_id, str(uuid.uuid4()).upper(), PANE_COLUMNS, PANE_ROWS))
        assert attached["ok"], attached
        while not stop.is_set():
            response, _ = session.send(state(session_id))
            revision = ((response.get("result") or {}).get("terminalState") or {}).get("screenStateRevision")
            if response.get("ok") and isinstance(revision, int):
                resync_counts[index] += 1
                resync_revisions[index] = revision
            else:
                resync_rejections[index] += 1
    except Exception as error:
        resync_errors[index] = repr(error)
    finally:
        session.close()


resync_threads = [threading.Thread(target=resync_loop, args=(index, session_id), daemon=True)
                  for index, session_id in enumerate(PRODUCER_SESSION_IDS)]
for thread in resync_threads:
    thread.start()

# The sidebar reloads several times a second while terminals stream, and `.overview` is answered inline on
# the shared request queue (SQLite plus a per-session filesystem walk). It is the dominant inline work a
# request can end up queued behind, so the bench has to generate it or the typed number is measured against
# an idle daemon.
# Each entry is (started_at, elapsed_ms) with `None` for a rejection. The start time is what the window is
# taken on: a poll is charged to the window it was issued in, so one that spans the boundary — and whose
# latency is therefore mostly pre-window work — cannot land in the measured distribution just because it
# happened to complete inside it.
overview_samples: list[tuple[float, float | None]] = []
overview_error = ""


def overview_loop() -> None:
    """The inline shared-queue load. A rejected `.overview` is a failure, not a sample: recording its
    latency would report the cost of the work the daemon skipped as if it had done it."""
    global overview_error
    session = RequestSession()
    try:
        while not stop.is_set():
            started_at = time.perf_counter()
            response, elapsed_ms = session.send({"command": {"overview": {}}, "authToken": AUTH_TOKEN, "clientApp": CLIENT_APP})
            overview_samples.append((started_at, elapsed_ms if response.get("ok") else None))
            time.sleep(0.1)
    except Exception as error:
        overview_error = repr(error)
    finally:
        session.close()


overview_thread = threading.Thread(target=overview_loop, daemon=True)
overview_thread.start()

# Let every producer reach its steady output rate and every resync loop get a connection up before the
# typed samples start; otherwise the first samples measure startup rather than contention.
time.sleep(3)


def live_producer_fixture_count() -> int:
    """How many producer fixtures are still running. A producer that emitted one frame and exited leaves a
    session the daemon keeps answering `.state` for, so an advancing revision alone cannot tell a producer
    that streamed through the window from one that died inside it."""
    completed = subprocess.run(["pgrep", "-f", PRODUCER_FIXTURE_PATTERN], capture_output=True, text=True)
    return len(completed.stdout.split())


def perf_log_offset() -> int:
    """How far the perf log has been written. Lane-wait rows are read from the offset taken when the
    measured window opens, so the distribution covers the same requests the latencies do: appends are
    serialized and only ever extend the file, so everything past that offset belongs to the window."""
    try:
        return os.path.getsize(PERF_LOG)
    except OSError:
        return 0


typed_latencies: list[float] = []
typed_failures = 0


def send_typed_sample(record: bool) -> None:
    global typed_failures
    try:
        response, elapsed_ms = typing_session.send(control("send", TYPING_SESSION_ID, text="x"))
        if response.get("ok"):
            if record:
                typed_latencies.append(elapsed_ms)
        else:
            typed_failures += 1
    except Exception:
        typed_failures += 1
    time.sleep(0.05)


for _ in range(WARMUP_SAMPLES):
    send_typed_sample(record=False)

# The measured window opens here, with the first sample that counts. The warm-up's typed sends, the
# attaches, and the thousands of resyncs issued while the producers were still spinning up are all outside
# it: pooling them into the same percentiles would report a distribution the latency numbers do not
# describe. Every accumulator that reaches the summary or a validity gate is therefore given its window
# treatment at this one boundary — reset if this thread owns it, snapshotted and subtracted at the close if
# a generator thread appends to it, since clearing a list another thread is appending to would race.
typed_failures = 0
window_opened_at = time.perf_counter()
window_start_resyncs = list(resync_counts)
window_start_resync_rejections = list(resync_rejections)
window_start_revisions = list(resync_revisions)
# The perf-log offset is read next to the counter snapshots, and the fixture probe — which shells out to
# `pgrep` and takes tens of milliseconds — is left until after both. Between those two reads the producers
# keep resyncing, so anything slower in between systematically counts requests whose lane-wait rows are
# already on the wrong side of the offset.
perf_log_window_start = perf_log_offset()
window_start_fixtures = live_producer_fixture_count()

for _ in range(SAMPLES):
    send_typed_sample(record=True)

# Closed on the last counted sample, before the fixture probe and before the generators are told to stop:
# teardown emits control requests of its own, and a lane wait recorded while the producers are being shut
# down describes a daemon that is no longer under the load the numbers claim.
perf_log_window_end = perf_log_offset()
window_closed_at = time.perf_counter()
window_end_overview_samples = len(overview_samples)
window_end_resyncs = list(resync_counts)
window_end_resync_rejections = list(resync_rejections)
window_end_revisions = list(resync_revisions)
# The fixture probe is the one thing left until after the freeze: it shells out to `pgrep`, and every
# counter above must be read at the same instant as the perf-log offset for the two to describe one window.
window_end_fixtures = live_producer_fixture_count()

# Windowed by when each poll was issued, not by when it landed. The prefix taken at the close is what makes
# the read stable against the poller thread; a poll issued inside the window that had not returned by then
# is outside this list, which is at most the one request in flight at each edge.
overview_in_window = [
    (started_at, elapsed_ms) for started_at, elapsed_ms in overview_samples[:window_end_overview_samples]
    if window_opened_at <= started_at < window_closed_at
]
overview_latencies_in_window = [elapsed_ms for _, elapsed_ms in overview_in_window if elapsed_ms is not None]
overview_rejections_in_window = sum(1 for _, elapsed_ms in overview_in_window if elapsed_ms is None)
resync_counts_in_window = [end - start for start, end in zip(window_start_resyncs, window_end_resyncs)]
resync_rejections_in_window = [end - start for start, end in zip(window_start_resync_rejections, window_end_resync_rejections)]
revisions_advanced_in_window = [end - start for start, end in zip(window_start_revisions, window_end_revisions)]

stop.set()
overview_thread.join(timeout=15)
for thread in resync_threads:
    thread.join(timeout=15)
typing_session.close()


def percentile(values: list[float], pct: float) -> float:
    ordered = sorted(values)
    return ordered[max(math.ceil(len(ordered) * pct) - 1, 0)]


def summarize(values: list[float]) -> dict:
    if not values:
        return {"count": 0, "p50_ms": None, "p95_ms": None, "max_ms": None}
    return {"count": len(values), "p50_ms": round(statistics.median(values), 3),
            "p95_ms": round(percentile(values, 0.95), 3), "max_ms": round(max(values), 3)}


def summarize_us(values: list[float]) -> dict:
    if not values:
        return {"count": 0, "p50_us": None, "p95_us": None, "max_us": None}
    return {"count": len(values), "p50_us": round(statistics.median(values), 1),
            "p95_us": round(percentile(values, 0.95), 1), "max_us": round(max(values), 1)}


# `device_api_control_lane_wait` is emitted per control request with the enqueue-to-dequeue delta in its
# detail; elapsed_ms rounds a sub-millisecond wait to zero, so the microseconds are what is read.
LANE_WAIT_PATTERN = re.compile(
    r"spaces: perf metric=device_api_control_lane_wait target=(?P<target>\S+) success=[01] elapsed_ms=\d+ "
    r"command=(?P<command>\S+) wait_us=(?P<wait>\d+)")

lane_waits: dict[str, list[float]] = {}
try:
    # Rows carry a wall-clock time but no date, so the window is bounded by byte offset instead: appends
    # are serialized and only ever extend the file, so the bytes between the two offsets are exactly the
    # rows written while the window was open. Read as bytes, because the offsets are byte counts and a
    # text-mode seek/read would be counting characters.
    with open(PERF_LOG, "rb") as handle:
        handle.seek(perf_log_window_start)
        window_rows = handle.read(max(perf_log_window_end - perf_log_window_start, 0))
    for line in window_rows.decode("utf-8", errors="replace").splitlines():
        match = LANE_WAIT_PATTERN.search(line)
        if match:
            lane_waits.setdefault(match.group("target"), []).append(float(match.group("wait")))
except FileNotFoundError:
    pass

typed_waits = lane_waits.get(TYPING_SESSION_ID, [])
producer_waits = [wait for session_id in PRODUCER_SESSION_IDS for wait in lane_waits.get(session_id, [])]


def perf_log_contains(marker: str) -> bool:
    """Whether any row in the whole log carries this marker, window or not."""
    encoded = marker.encode()
    try:
        with open(PERF_LOG, "rb") as handle:
            return any(encoded in line for line in handle)
    except FileNotFoundError:
        return False


# Two different facts, read from the whole log rather than the window, and they must not be conflated.
#
# `perf_log_armed` asks whether the daemon was started under DEBUG at all. An unarmed daemon writes no row
# of any metric, and its latencies are not comparable with a run that paid for the log, so that is always
# an invalid run — it is also the failure mode of the arming flake this bench hits intermittently.
#
# `lane_wait_metric_present` asks whether this daemon knows the metric. A daemon built before the
# per-session lanes emits every other perf row and none of these, which is exactly the baseline half of a
# before/after comparison: refusing it would make the identical-procedure comparison impossible. So a log
# that armed but carries no lane-wait row anywhere publishes the externally measured distributions with the
# lane-wait fields omitted and says so. An armed log that does know the metric is held to the strict rule:
# if the window carries no typed lane wait, something dropped out mid-run and the run is refused.
#
# Accepted: the two armed daemons are not instrumentation-identical. Both pay the pre-existing perf-log
# costs, and the after-side pays one extra serialized append per control dequeue that the baseline has no
# row for. That is left as-is rather than papered over with a parity mode, because the bias runs against
# the change: the extra work is charged to the run being argued for, so it can only understate the
# improvement the comparison reports, never invent one.
perf_log_armed = perf_log_contains("spaces: perf ")
lane_wait_metric_present = perf_log_contains("metric=device_api_control_lane_wait")

# Validity first: nothing is published until the run is known to be comparable. A summary on disk or on
# stdout is taken as a measurement, so a run that carried less load than it claims must produce neither.
#
# What is checked is whether the load was applied, never how fast the daemon answered it. Each generator
# must have survived to the end (its thread exits only when `stop` is set), have been answered rather than
# rejected, and have done some work. There is deliberately no rate floor: slow answers under contention
# are the thing being measured, and a threshold on requests-per-second would fail exactly the saturated
# runs the bench exists to capture. Typed failures are excluded for the same reason — they are the
# measurement, and a baseline that drops them is the finding rather than a bad run.
#
# Counts are read from the measured window; a generator dying or outliving its join is checked over the
# whole run instead, because neither is an accumulator and either one anywhere means the run was not the
# run it claims to be.
problems = []

if not perf_log_armed:
    problems.append(f"The daemon never armed its DEBUG perf log ({PERF_LOG} carries no perf rows); rerun with DEBUG=1.")
elif lane_wait_metric_present and not typed_waits:
    problems.append("The daemon emits device_api_control_lane_wait, but no typed lane wait landed in the measured window.")

for index, session_id in enumerate(PRODUCER_SESSION_IDS):
    if resync_errors[index]:
        problems.append(f"producer {index} ({session_id}) died: {resync_errors[index]}")
    if resync_threads[index].is_alive():
        problems.append(f"producer {index} ({session_id}) did not finish within the join timeout")
    if resync_rejections_in_window[index]:
        problems.append(f"producer {index} ({session_id}) had {resync_rejections_in_window[index]} rejected resyncs")
    if resync_counts_in_window[index] == 0:
        problems.append(f"producer {index} ({session_id}) completed no successful resyncs")
    elif revisions_advanced_in_window[index] <= 0:
        problems.append(
            f"producer {index} ({session_id}) stopped streaming during the measured window "
            f"(screen revision stuck at {window_end_revisions[index]})")

expected_fixtures = len(PRODUCER_SESSION_IDS)
if window_start_fixtures != expected_fixtures:
    problems.append(f"only {window_start_fixtures} of {expected_fixtures} producer fixtures were running when the window opened")
elif window_end_fixtures != expected_fixtures:
    problems.append(f"only {window_end_fixtures} of {expected_fixtures} producer fixtures were still running when the window closed")

if overview_error:
    problems.append(f"the overview poller died: {overview_error}")
if overview_thread.is_alive():
    problems.append("the overview poller did not finish within the join timeout")
if overview_rejections_in_window:
    problems.append(f"the overview poller had {overview_rejections_in_window} rejected requests")
if not overview_latencies_in_window:
    problems.append("the overview poller completed no successful requests")

if problems:
    print("Load was not sustained for the whole run; no summary published.", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    print(f"  resync_requests_per_producer={resync_counts_in_window}", file=sys.stderr)
    print(f"  resync_rejections_per_producer={resync_rejections_in_window}", file=sys.stderr)
    print(f"  screen_revision_window_start={window_start_revisions} end={window_end_revisions}", file=sys.stderr)
    print(f"  producer_fixtures_window_start={window_start_fixtures} end={window_end_fixtures}", file=sys.stderr)
    print(f"  overview_successes={len(overview_latencies_in_window)} overview_rejections={overview_rejections_in_window}", file=sys.stderr)
    print(
        f"  perf_log={PERF_LOG} size={perf_log_offset()} window=[{perf_log_window_start},{perf_log_window_end}) "
        f"armed={perf_log_armed} lane_wait_metric_present={lane_wait_metric_present} lane_wait_targets={len(lane_waits)}",
        file=sys.stderr)
    raise SystemExit(1)

summary = {
    "producers": len(PRODUCER_SESSION_IDS),
    "typed_input_round_trip": summarize(typed_latencies),
    "typed_input_failures": typed_failures,
    "overview_round_trip": summarize(overview_latencies_in_window),
    "lane_wait_metric": "present" if lane_wait_metric_present else "absent",
    "resync_requests": sum(resync_counts_in_window),
    "resync_requests_per_producer": resync_counts_in_window,
    "screen_revisions_advanced_per_producer": revisions_advanced_in_window,
}
# A daemon that does not emit the metric gets no lane-wait fields at all rather than empty ones, so a
# baseline summary cannot be misread as a run whose lanes happened to wait for nothing.
if lane_wait_metric_present:
    summary["typing_session_lane_wait"] = summarize_us(typed_waits)
    summary["producer_session_lane_wait"] = summarize_us(producer_waits)

with open(SUMMARY_PATH, "w") as handle:
    json.dump(summary, handle, indent=2, sort_keys=True)
print(json.dumps(summary, indent=2, sort_keys=True))
