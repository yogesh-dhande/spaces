#!/usr/bin/env python3
"""TCP shaping proxy used by the iOS performance baseline lane.

Sits between the iOS simulator and a live Spaces daemon on loopback and
reproduces a network profile (one-way delay plus a bandwidth cap, both
directions) on top of an otherwise transparent relay. TLS between the
mobile client and the daemon passes through untouched: the client pins the
daemon's certificate by fingerprint, so the proxy does not terminate or
inspect anything, it just paces bytes.

Also exposes a line-based control port so a driving test can flip the link
down and back up to exercise reconnect behavior deterministically. Three
verbs, each answered with "ok <link state>":

  link down      Blackhole: sockets stay open, nothing is forwarded, and a
                 connection accepted during the outage is never dialed
                 upstream. Every connection alive at this moment, and every
                 one accepted while down, is tainted.
  link up        Recovery that closes every tainted connection, so a client
                 holding a stale socket learns immediately and redials.
  link up dead   Recovery for new connections only: every tainted
                 connection is left black-holed for the rest of the run,
                 never dialed upstream and never closed by the proxy, so a
                 client waiting on one sits out its own timeout before it
                 redials. This is the path change (NAT rebinding, VPN or
                 mesh route change) a client cannot detect from its socket.

Python 3.9+, stdlib only.
"""

import argparse
import asyncio
import json
import signal
import sys
import time
from datetime import datetime, timezone

PROFILES = {
    "good": {"delay_ms": 10, "bandwidth_mbit": 50},
    "constrained": {"delay_ms": 40, "bandwidth_mbit": 8},
    "poor": {"delay_ms": 200, "bandwidth_mbit": 1},
}

CHUNK_SIZE = 64 * 1024
BUCKET_DEPTH = 64 * 1024


def iso_now():
    dt = datetime.now(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + ("%03dZ" % (dt.microsecond // 1000))


def log_event(log_file, event, **fields):
    record = {"event": event, "at": iso_now(), "uptime_ns": time.monotonic_ns()}
    record.update(fields)
    # A single synchronous write() call from a single-threaded event loop is
    # never interleaved with another coroutine's write, so no lock is needed.
    log_file.write(json.dumps(record) + "\n")
    log_file.flush()


class TokenBucket:
    """Bytes-as-tokens bucket, refilled continuously at a byte rate, capped
    at BUCKET_DEPTH. Starts full so a link that has been idle can release an
    initial burst up to the cap before bandwidth pacing kicks in, matching
    how the delay-only tests expect small messages to be gated by delay
    alone rather than by bandwidth.
    """

    def __init__(self, rate_bytes_per_sec, capacity):
        self.rate = rate_bytes_per_sec
        self.capacity = capacity
        self.tokens = float(capacity)
        self.last = time.monotonic()

    def _refill(self):
        now = time.monotonic()
        elapsed = now - self.last
        self.last = now
        if elapsed > 0:
            self.tokens = min(self.capacity, self.tokens + elapsed * self.rate)

    async def take(self, n):
        while True:
            self._refill()
            if self.tokens >= n:
                self.tokens -= n
                return
            deficit = n - self.tokens
            await asyncio.sleep(deficit / self.rate)


class Connection:
    def __init__(self, conn_id, client_writer):
        self.id = conn_id
        self.client_writer = client_writer
        self.upstream_writer = None
        # Set on every connection alive at the moment of `link down`, and on
        # every connection accepted while the link is down. `link up` closes
        # every tainted connection (both halves) rather than letting it
        # resume, so the client's stale socket fails fast the way a real
        # link recovery does instead of silently replaying stale traffic.
        # `link up dead` leaves them open and forwarding nothing instead.
        self.tainted = False
        # Cleared for this connection by `link down`, and never set again:
        # a tainted connection either gets closed by `link up` or stays
        # black-holed through `link up dead`. Pacers wait on it before every
        # write, so forwarding stops without touching sockets, and a
        # recovered link only carries connections opened after it.
        self.flow_event = asyncio.Event()
        self.flow_event.set()
        self.closed = False
        self.closed_event = asyncio.Event()
        self.bytes_up = 0
        self.bytes_down = 0
        self.start = time.monotonic()
        self.tasks = []


class ShaperState:
    def __init__(self, args, log_file):
        self.args = args
        self.log_file = log_file
        profile = PROFILES[args.profile]
        self.delay_seconds = profile["delay_ms"] / 1000.0
        self.rate_bytes_per_sec = profile["bandwidth_mbit"] * 1_000_000 / 8.0
        self.connections = {}
        self._next_id = 0
        # "up", "down", or "up-dead". Only "down" stops a new connection
        # from being dialed upstream; the two recovery states differ solely
        # in what happens to the connections the outage tainted.
        self.link_state = "up"
        self.pending_up = 0
        self.pending_down = 0

    def next_id(self):
        self._next_id += 1
        return self._next_id


async def reader_loop(reader, queue):
    """Reads chunks and stamps each with its arrival time. A None sentinel
    marks EOF so the paired pacer can finish draining and half-close.
    """
    try:
        while True:
            data = await reader.read(CHUNK_SIZE)
            if not data:
                break
            queue.put_nowait((data, time.monotonic()))
    except (asyncio.CancelledError, ConnectionResetError, OSError):
        pass
    finally:
        queue.put_nowait(None)


async def pacer_loop(state, queue, writer, conn, direction):
    while True:
        item = await queue.get()
        if item is None:
            break
        data, arrival = item
        release_time = arrival + state.delay_seconds
        now = time.monotonic()
        if release_time > now:
            await asyncio.sleep(release_time - now)
        bucket = conn.up_bucket if direction == "up" else conn.down_bucket
        await bucket.take(len(data))
        await conn.flow_event.wait()
        try:
            writer.write(data)
            await writer.drain()
        except (ConnectionResetError, OSError, asyncio.CancelledError):
            break
        n = len(data)
        if direction == "up":
            conn.bytes_up += n
            state.pending_up += n
        else:
            conn.bytes_down += n
            state.pending_down += n
    try:
        if writer.can_write_eof():
            writer.write_eof()
    except Exception:
        pass


async def close_connection(state, conn):
    if conn.closed:
        return
    conn.closed = True
    for t in conn.tasks:
        t.cancel()
    for t in conn.tasks:
        try:
            await t
        except asyncio.CancelledError:
            pass
        except Exception:
            pass
    for w in (conn.client_writer, conn.upstream_writer):
        if w is not None:
            try:
                w.close()
            except Exception:
                pass
    for w in (conn.client_writer, conn.upstream_writer):
        if w is not None:
            try:
                await w.wait_closed()
            except Exception:
                pass
    state.connections.pop(conn.id, None)
    duration_ms = (time.monotonic() - conn.start) * 1000.0
    log_event(
        state.log_file,
        "conn_close",
        conn=conn.id,
        bytes_up=conn.bytes_up,
        bytes_down=conn.bytes_down,
        duration_ms=round(duration_ms, 1),
    )
    conn.closed_event.set()


async def handle_connection(state, client_reader, client_writer):
    conn = Connection(state.next_id(), client_writer)
    state.connections[conn.id] = conn
    log_event(state.log_file, "conn_open", conn=conn.id)

    if state.link_state == "down":
        # Accepted but deliberately never connected upstream and never
        # answered: the client's TCP handshake succeeds but nothing more
        # happens until `link up` closes it, same as an established
        # connection caught by the outage.
        conn.tainted = True
        await conn.closed_event.wait()
        return

    try:
        upstream_reader, upstream_writer = await asyncio.open_connection(
            state.args.upstream_host, state.args.upstream_port
        )
    except OSError:
        await close_connection(state, conn)
        return
    conn.upstream_writer = upstream_writer

    up_queue = asyncio.Queue()
    down_queue = asyncio.Queue()
    conn.up_bucket = TokenBucket(state.rate_bytes_per_sec, BUCKET_DEPTH)
    conn.down_bucket = TokenBucket(state.rate_bytes_per_sec, BUCKET_DEPTH)

    conn.tasks = [
        asyncio.create_task(reader_loop(client_reader, up_queue)),
        asyncio.create_task(pacer_loop(state, up_queue, upstream_writer, conn, "up")),
        asyncio.create_task(reader_loop(upstream_reader, down_queue)),
        asyncio.create_task(pacer_loop(state, down_queue, client_writer, conn, "down")),
    ]
    await asyncio.wait(conn.tasks, return_when=asyncio.ALL_COMPLETED)
    await close_connection(state, conn)


async def do_link_down(state):
    for conn in state.connections.values():
        conn.tainted = True
        conn.flow_event.clear()
    state.link_state = "down"
    log_event(state.log_file, "link", state="down")


async def do_link_up(state):
    tainted = [c for c in state.connections.values() if c.tainted]
    for conn in tainted:
        await close_connection(state, conn)
    state.link_state = "up"
    log_event(state.log_file, "link", state="up")


async def do_link_up_dead(state):
    """Recovery that leaves the outage's connections dead rather than closed.

    The tainted connections keep their sockets and forward nothing for the
    rest of the run: their pacers stay parked on a flow event that is never
    set again, and one accepted during the outage is still waiting to be
    dialed upstream. The proxy closes them only at shutdown. A client
    parked on one of them recovers by dialing anew, on its own timeout.
    """
    state.link_state = "up-dead"
    log_event(state.log_file, "link", state="up-dead")


async def handle_control(state, reader, writer):
    try:
        while True:
            line = await reader.readline()
            if not line:
                break
            command = line.decode("utf-8", "replace").strip()
            if command == "link down":
                await do_link_down(state)
            elif command == "link up":
                await do_link_up(state)
            elif command == "link up dead":
                await do_link_up_dead(state)
            elif command == "status":
                pass
            else:
                # Unrecognized command: report current state rather than
                # tearing down the control connection.
                pass
            writer.write(("ok %s\n" % state.link_state).encode())
            await writer.drain()
    except (ConnectionResetError, OSError, asyncio.CancelledError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


def flush_pending_bytes(state):
    if state.pending_up or state.pending_down:
        log_event(state.log_file, "bytes", up=state.pending_up, down=state.pending_down)
        state.pending_up = 0
        state.pending_down = 0


async def bytes_ticker(state):
    try:
        while True:
            await asyncio.sleep(1.0)
            flush_pending_bytes(state)
    except asyncio.CancelledError:
        pass


async def run(args):
    log_file = open(args.log, "a")
    state = ShaperState(args, log_file)

    async def connection_handler(reader, writer):
        await handle_connection(state, reader, writer)

    async def control_handler(reader, writer):
        await handle_control(state, reader, writer)

    listen_server = await asyncio.start_server(connection_handler, "127.0.0.1", args.listen_port)
    control_server = await asyncio.start_server(control_handler, "127.0.0.1", args.control_port)

    listen_port = listen_server.sockets[0].getsockname()[1]
    control_port = control_server.sockets[0].getsockname()[1]

    log_event(log_file, "listen", port=listen_port, control_port=control_port)
    profile = PROFILES[args.profile]
    log_event(
        log_file,
        "profile",
        name=args.profile,
        delay_ms=profile["delay_ms"],
        bandwidth_mbit=profile["bandwidth_mbit"],
    )
    print("listening port=%d control=%d" % (listen_port, control_port), flush=True)

    ticker_task = asyncio.create_task(bytes_ticker(state))

    stop_event = asyncio.Event()
    loop = asyncio.get_event_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop_event.set)

    await stop_event.wait()

    listen_server.close()
    control_server.close()
    await listen_server.wait_closed()
    await control_server.wait_closed()

    for conn in list(state.connections.values()):
        await close_connection(state, conn)

    ticker_task.cancel()
    try:
        await ticker_task
    except asyncio.CancelledError:
        pass
    flush_pending_bytes(state)
    log_file.close()


def parse_args(argv):
    parser = argparse.ArgumentParser(description="iOS baseline lane network shaping proxy")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--upstream-host", type=str, required=True)
    parser.add_argument("--upstream-port", type=int, required=True)
    parser.add_argument("--profile", type=str, required=True, choices=sorted(PROFILES.keys()))
    parser.add_argument("--control-port", type=int, required=True)
    parser.add_argument("--log", type=str, required=True)
    return parser.parse_args(argv)


def main():
    args = parse_args(sys.argv[1:])
    asyncio.run(run(args))
    sys.exit(0)


if __name__ == "__main__":
    main()
