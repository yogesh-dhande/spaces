#!/usr/bin/env python3
import argparse
import random
import string
import sys
import time


def random_payload(width: int, rng: random.Random) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(rng.choice(alphabet) for _ in range(max(width, 1)))


def emit_line_stream(args: argparse.Namespace, rng: random.Random) -> int:
    for seq in range(1, args.lines + 1):
        payload = random_payload(args.width, rng)
        print(f"SEQ {seq:08d} {payload}")
        if args.flush_every and seq % args.flush_every == 0:
            sys.stdout.flush()
        if args.sleep_ms:
            time.sleep(args.sleep_ms / 1000.0)
    sys.stdout.flush()
    return args.lines


def emit_repaint_stream(args: argparse.Namespace, rng: random.Random) -> int:
    line_seq = 0
    for frame in range(1, args.frames + 1):
        sys.stdout.write("\x1b[H\x1b[2J")
        sys.stdout.write(f"FRAME {frame:06d}\n")
        for row in range(1, args.rows + 1):
            line_seq += 1
            payload = random_payload(args.width, rng)
            sys.stdout.write(f"SEQ {line_seq:08d} FRAME {frame:06d} ROW {row:03d} {payload}\n")
        sys.stdout.flush()
        if args.sleep_ms:
            time.sleep(args.sleep_ms / 1000.0)
    return line_seq


def emit_mixed_stream(args: argparse.Namespace, rng: random.Random) -> int:
    line_seq = 0
    for frame in range(1, args.frames + 1):
        sys.stdout.write("\x1b[H")
        sys.stdout.write(f"STATUS frame={frame:06d} total={args.frames:06d}\n")
        for row in range(1, args.rows + 1):
            line_seq += 1
            payload = random_payload(args.width, rng)
            sys.stdout.write(f"SEQ {line_seq:08d} FRAME {frame:06d} ROW {row:03d} {payload}\n")
        sys.stdout.flush()
        if args.sleep_ms:
            time.sleep(args.sleep_ms / 1000.0)
    return line_seq


def emit_scrollback_repaint_stream(args: argparse.Namespace, rng: random.Random) -> int:
    line_seq = 0
    for frame in range(1, args.frames + 1):
        sys.stdout.write("\x1b[H")
        sys.stdout.write(f"STATUS frame={frame:06d} total={args.frames:06d} mode=scrollback_repaint\n")
        for history_row in range(1, args.history_rows + 1):
            line_seq += 1
            payload = random_payload(args.width, rng)
            sys.stdout.write(f"HISTORY {line_seq:08d} FRAME {frame:06d} ROW {history_row:03d} {payload}\n")
        for live_row in range(1, args.rows + 1):
            line_seq += 1
            payload = random_payload(args.width, rng)
            sys.stdout.write(f"SEQ {line_seq:08d} FRAME {frame:06d} LIVE {live_row:03d} {payload}\n")
        sys.stdout.flush()
        if args.sleep_ms:
            time.sleep(args.sleep_ms / 1000.0)
    return line_seq


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["lines", "repaint", "mixed", "scrollback_repaint"], required=True)
    parser.add_argument("--lines", type=int, default=20000)
    parser.add_argument("--frames", type=int, default=300)
    parser.add_argument("--rows", type=int, default=24)
    parser.add_argument("--history-rows", type=int, default=24)
    parser.add_argument("--width", type=int, default=72)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--sleep-ms", type=int, default=0)
    parser.add_argument("--flush-every", type=int, default=100)
    args = parser.parse_args()

    rng = random.Random(args.seed)
    print(
        f"FIXTURE_START mode={args.mode} lines={args.lines} frames={args.frames} rows={args.rows} width={args.width} seed={args.seed}",
        flush=True,
    )

    if args.mode == "lines":
        emitted = emit_line_stream(args, rng)
    elif args.mode == "repaint":
        emitted = emit_repaint_stream(args, rng)
    elif args.mode == "scrollback_repaint":
        emitted = emit_scrollback_repaint_stream(args, rng)
    else:
        emitted = emit_mixed_stream(args, rng)

    print(f"FIXTURE_DONE mode={args.mode} emitted={emitted}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
