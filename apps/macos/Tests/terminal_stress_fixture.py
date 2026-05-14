#!/usr/bin/env python3
import argparse
import random
import string
import sys
import time


def random_payload(width: int, rng: random.Random) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(rng.choice(alphabet) for _ in range(max(width, 1)))


def sgr(*codes: str) -> str:
    return f"\x1b[{';'.join(codes)}m"


def style_prefix(frame: int, row: int) -> str:
    palette_fg = 30 + (row % 8)
    bright_fg = 90 + (frame % 8)
    palette_bg = 40 + ((frame + row) % 8)
    rgb_fg = (
        48 + ((frame * 17 + row * 11) % 180),
        72 + ((frame * 9 + row * 13) % 150),
        110 + ((frame * 7 + row * 5) % 120),
    )
    rgb_bg = (
        16 + ((frame * 5 + row * 19) % 96),
        24 + ((frame * 11 + row * 7) % 96),
        32 + ((frame * 13 + row * 3) % 96),
    )
    codes = [str(palette_fg), str(bright_fg)]
    if row % 3 == 0:
        codes.append("1")
    if row % 4 == 0:
        codes.append("4")
    if row % 5 == 0:
        codes.append("3")
    if row % 6 == 0:
        codes.extend(["38", "2", str(rgb_fg[0]), str(rgb_fg[1]), str(rgb_fg[2])])
    if row % 7 == 0:
        codes.append(str(palette_bg))
    if row % 8 == 0:
        codes.extend(["48", "2", str(rgb_bg[0]), str(rgb_bg[1]), str(rgb_bg[2])])
    if row % 9 == 0:
        codes.append("7")
    return sgr(*codes)


def styled_line(prefix: str, payload: str, frame: int, row: int) -> str:
    accent = style_prefix(frame, row)
    marker = sgr("38", "5", str((frame + row) % 256), "48", "5", str((frame * 3 + row * 5) % 256))
    return f"{accent}{prefix}{sgr('0')} {marker}{payload}{sgr('0')}"


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


def emit_color_repaint_stream(args: argparse.Namespace, rng: random.Random) -> int:
    line_seq = 0
    for frame in range(1, args.frames + 1):
        sys.stdout.write("\x1b[H\x1b[2J")
        sys.stdout.write(f"{sgr('1','38','5','45')}FRAME {frame:06d}{sgr('0')}\n")
        for row in range(1, args.rows + 1):
            line_seq += 1
            payload = random_payload(args.width, rng)
            prefix = f"SEQ {line_seq:08d} FRAME {frame:06d} ROW {row:03d}"
            sys.stdout.write(styled_line(prefix, payload, frame, row) + "\n")
        sys.stdout.flush()
        if args.sleep_ms:
            time.sleep(args.sleep_ms / 1000.0)
    return line_seq


def emit_color_scrollback_repaint_stream(args: argparse.Namespace, rng: random.Random) -> int:
    line_seq = 0
    for frame in range(1, args.frames + 1):
        sys.stdout.write("\x1b[H")
        sys.stdout.write(f"{sgr('1','38','2','120','210','255')}STATUS frame={frame:06d} total={args.frames:06d} mode=color_scrollback_repaint{sgr('0')}\n")
        for history_row in range(1, args.history_rows + 1):
            line_seq += 1
            payload = random_payload(args.width, rng)
            prefix = f"HISTORY {line_seq:08d} FRAME {frame:06d} ROW {history_row:03d}"
            sys.stdout.write(styled_line(prefix, payload, frame, history_row) + "\n")
        for live_row in range(1, args.rows + 1):
            line_seq += 1
            payload = random_payload(args.width, rng)
            prefix = f"SEQ {line_seq:08d} FRAME {frame:06d} LIVE {live_row:03d}"
            sys.stdout.write(styled_line(prefix, payload, frame, live_row + args.history_rows) + "\n")
        sys.stdout.flush()
        if args.sleep_ms:
            time.sleep(args.sleep_ms / 1000.0)
    return line_seq


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=["lines", "repaint", "mixed", "scrollback_repaint", "color_repaint", "color_scrollback_repaint"],
        required=True,
    )
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
    elif args.mode == "color_repaint":
        emitted = emit_color_repaint_stream(args, rng)
    elif args.mode == "color_scrollback_repaint":
        emitted = emit_color_scrollback_repaint_stream(args, rng)
    else:
        emitted = emit_mixed_stream(args, rng)

    print(f"FIXTURE_DONE mode={args.mode} emitted={emitted}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
