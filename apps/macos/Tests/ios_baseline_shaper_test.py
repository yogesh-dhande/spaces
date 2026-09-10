#!/usr/bin/env python3
"""Unit tests for ios_baseline_shaper.py.

Starts the shaper as a real subprocess against a loopback asyncio echo
server (run in a background thread with its own event loop, since this
test process drives the shaper synchronously with plain blocking sockets).
No network beyond 127.0.0.1 is used. Python 3.9+, stdlib only.
"""

import asyncio
import json
import os
import select
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SHAPER_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ios_baseline_shaper.py")


def free_port():
    # Bind-then-close instead of relying on the OS to hand back a port
    # number via --listen-port 0: we need the port before we spawn the
    # subprocess, since it is a required CLI argument.
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class EchoServer:
    """Loopback asyncio echo server run in a background thread so the main
    test thread can drive the shaper with ordinary blocking sockets.
    """

    def __init__(self):
        self.loop = None
        self.server = None
        self.thread = None
        self.port = None
        self._ready = threading.Event()

    def start(self):
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()
        if not self._ready.wait(timeout=5):
            raise RuntimeError("echo server did not start in time")

    def _run(self):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.loop.run_until_complete(self._start_server())
        self._ready.set()
        self.loop.run_forever()

    async def _start_server(self):
        self.server = await asyncio.start_server(self._handle, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]

    async def _handle(self, reader, writer):
        try:
            while True:
                data = await reader.read(65536)
                if not data:
                    break
                writer.write(data)
                await writer.drain()
        except (ConnectionResetError, OSError):
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    def stop(self):
        if self.loop is not None and self.server is not None:
            fut = asyncio.run_coroutine_threadsafe(self._stop_server(), self.loop)
            try:
                fut.result(timeout=5)
            except Exception:
                pass
        if self.loop is not None:
            self.loop.call_soon_threadsafe(self.loop.stop)
        if self.thread is not None:
            self.thread.join(timeout=5)

    async def _stop_server(self):
        self.server.close()
        await self.server.wait_closed()


def read_ready_line(proc, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.stdout in select.select([proc.stdout], [], [], 0.5)[0]:
            line = proc.stdout.readline()
            if line:
                return line.strip()
        if proc.poll() is not None:
            raise RuntimeError("shaper exited early: %s" % proc.stderr.read())
    raise TimeoutError("shaper did not report a listening line in time")


class ShaperTestCase(unittest.TestCase):
    echo = None

    @classmethod
    def setUpClass(cls):
        cls.echo = EchoServer()
        cls.echo.start()

    @classmethod
    def tearDownClass(cls):
        cls.echo.stop()

    def setUp(self):
        self.proc = None
        self.log_dir = tempfile.mkdtemp(prefix="ios_baseline_shaper_test_")

    def tearDown(self):
        if self.proc is not None:
            if self.proc.poll() is None:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=5)
            if self.proc.stdout is not None:
                self.proc.stdout.close()
            if self.proc.stderr is not None:
                self.proc.stderr.close()

    def start_shaper(self, profile):
        listen_port = free_port()
        control_port = free_port()
        log_path = os.path.join(self.log_dir, "shaper-%s.jsonl" % profile)
        cmd = [
            sys.executable,
            SHAPER_PATH,
            "--listen-port", str(listen_port),
            "--upstream-host", "127.0.0.1",
            "--upstream-port", str(self.echo.port),
            "--profile", profile,
            "--control-port", str(control_port),
            "--log", log_path,
        ]
        self.proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1
        )
        line = read_ready_line(self.proc)
        self.assertTrue(line.startswith("listening port="), line)
        return listen_port, control_port, log_path

    def send_control(self, control_port, command):
        with socket.create_connection(("127.0.0.1", control_port), timeout=5) as s:
            s.sendall((command + "\n").encode())
            f = s.makefile("r")
            return f.readline().strip()

    def read_log(self, log_path):
        events = []
        with open(log_path) as f:
            for line in f:
                line = line.strip()
                if line:
                    events.append(json.loads(line))
        return events

    # --- tests -----------------------------------------------------------

    def test_relays_bytes_both_ways(self):
        listen_port, _control_port, _log_path = self.start_shaper("good")
        with socket.create_connection(("127.0.0.1", listen_port), timeout=5) as s:
            s.sendall(b"hello shaper")
            reply = s.recv(1024)
        self.assertEqual(reply, b"hello shaper")

    def test_round_trip_delay_good_and_constrained(self):
        # good: 10 ms one-way => >= 20 ms RTT. constrained: 40 ms one-way
        # => >= 80 ms RTT. A generous 5 ms tolerance absorbs scheduling
        # jitter without weakening the check: an unshaped loopback RTT is
        # under 1 ms, so even with the tolerance the assertion clearly
        # distinguishes shaped from unshaped.
        for profile, expected_rtt in (("good", 0.020), ("constrained", 0.080)):
            with self.subTest(profile=profile):
                listen_port, _control_port, _log_path = self.start_shaper(profile)
                with socket.create_connection(("127.0.0.1", listen_port), timeout=5) as s:
                    start = time.monotonic()
                    s.sendall(b"ping")
                    reply = s.recv(1024)
                    elapsed = time.monotonic() - start
                self.assertEqual(reply, b"ping")
                self.assertGreaterEqual(elapsed, expected_rtt - 0.005)
                self.tearDown()
                self.setUp()

    def test_poor_bandwidth_1mb_transfer(self):
        listen_port, _control_port, _log_path = self.start_shaper("poor")
        total = 1024 * 1024
        payload = os.urandom(total)
        received = bytearray()
        with socket.create_connection(("127.0.0.1", listen_port), timeout=20) as s:
            def sender():
                s.sendall(payload)

            sender_thread = threading.Thread(target=sender)
            start = time.monotonic()
            sender_thread.start()
            while len(received) < total:
                chunk = s.recv(65536)
                if not chunk:
                    break
                received.extend(chunk)
            elapsed = time.monotonic() - start
            sender_thread.join(timeout=5)
        self.assertEqual(bytes(received), payload)
        # 1 Mbit/s => ~1 MB in ~8 s; bound loosely on both sides so the
        # test stays reliable without being slow (contract: keep under
        # 15 s).
        self.assertGreaterEqual(elapsed, 7.0)
        self.assertLess(elapsed, 15.0)

    def test_link_down_stalls_established_and_blocks_new_connections(self):
        listen_port, control_port, _log_path = self.start_shaper("good")
        s = socket.create_connection(("127.0.0.1", listen_port), timeout=5)
        try:
            s.sendall(b"before")
            self.assertEqual(s.recv(1024), b"before")

            resp = self.send_control(control_port, "link down")
            self.assertEqual(resp, "ok down")

            s.sendall(b"during")
            s.settimeout(2.0)
            with self.assertRaises(socket.timeout):
                s.recv(1024)

            s2 = socket.create_connection(("127.0.0.1", listen_port), timeout=5)
            try:
                s2.sendall(b"new-during-outage")
                s2.settimeout(2.0)
                with self.assertRaises(socket.timeout):
                    s2.recv(1024)
            finally:
                s2.close()
        finally:
            s.close()

    def test_link_up_closes_survivors_and_allows_new_connections(self):
        listen_port, control_port, _log_path = self.start_shaper("good")
        s = socket.create_connection(("127.0.0.1", listen_port), timeout=5)
        s.sendall(b"before-outage")
        self.assertEqual(s.recv(1024), b"before-outage")

        self.assertEqual(self.send_control(control_port, "link down"), "ok down")

        # Accepted while down: never connected upstream, never answered.
        s2 = socket.create_connection(("127.0.0.1", listen_port), timeout=5)

        self.assertEqual(self.send_control(control_port, "link up"), "ok up")

        s.settimeout(5.0)
        self.assertEqual(s.recv(1024), b"")  # closed, both halves
        s2.settimeout(5.0)
        self.assertEqual(s2.recv(1024), b"")  # closed, never having connected
        s.close()
        s2.close()

        with socket.create_connection(("127.0.0.1", listen_port), timeout=5) as s3:
            s3.sendall(b"after-recovery")
            self.assertEqual(s3.recv(1024), b"after-recovery")

    def test_link_up_dead_black_holes_survivors_and_allows_new_connections(self):
        listen_port, control_port, _log_path = self.start_shaper("good")
        s = socket.create_connection(("127.0.0.1", listen_port), timeout=5)
        s.sendall(b"before-outage")
        self.assertEqual(s.recv(1024), b"before-outage")

        self.assertEqual(self.send_control(control_port, "link down"), "ok down")

        # Accepted while down: never connected upstream, never answered.
        s2 = socket.create_connection(("127.0.0.1", listen_port), timeout=5)

        self.assertEqual(self.send_control(control_port, "link up dead"), "ok up-dead")

        # Both tainted connections stay open and silent: the client learns
        # nothing from its socket and only recovers by dialing anew.
        s.settimeout(2.0)
        s.sendall(b"after-dead-recovery")
        with self.assertRaises(socket.timeout):
            s.recv(1024)
        s2.settimeout(2.0)
        s2.sendall(b"after-dead-recovery")
        with self.assertRaises(socket.timeout):
            s2.recv(1024)
        s.close()
        s2.close()

        with socket.create_connection(("127.0.0.1", listen_port), timeout=5) as s3:
            s3.sendall(b"new-connection")
            self.assertEqual(s3.recv(1024), b"new-connection")

    def test_byte_log_sums_match_bytes_transferred(self):
        listen_port, _control_port, log_path = self.start_shaper("good")
        payload = os.urandom(50000)
        with socket.create_connection(("127.0.0.1", listen_port), timeout=5) as s:
            s.sendall(payload)
            received = bytearray()
            while len(received) < len(payload):
                chunk = s.recv(65536)
                if not chunk:
                    break
                received.extend(chunk)
        self.assertEqual(bytes(received), payload)
        # Let the natural EOF-driven connection close finish logging
        # conn_close before the SIGTERM shutdown flush runs.
        time.sleep(0.3)

        self.proc.send_signal(signal.SIGTERM)
        self.proc.wait(timeout=5)

        events = self.read_log(log_path)
        bytes_events = [e for e in events if e["event"] == "bytes"]
        total_up = sum(e["up"] for e in bytes_events)
        total_down = sum(e["down"] for e in bytes_events)

        conn_close_events = [e for e in events if e["event"] == "conn_close"]
        self.assertEqual(len(conn_close_events), 1)
        self.assertEqual(conn_close_events[0]["bytes_up"], len(payload))
        self.assertEqual(conn_close_events[0]["bytes_down"], len(payload))
        self.assertEqual(total_up, len(payload))
        self.assertEqual(total_down, len(payload))


if __name__ == "__main__":
    unittest.main(verbosity=2)
