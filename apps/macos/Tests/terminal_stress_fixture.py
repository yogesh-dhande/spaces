#!/usr/bin/env python3
import argparse
import random
import string
import sys
import time

SPINNER_STATES = "|/-\\"
STATUS_PHASES = (
    "reading_repo",
    "scanning_metrics",
    "buffering_output",
    "reconciling_scrollback",
    "checking_render_dump",
    "writing_patch",
)
HISTORY_TOPICS = (
    "owner_epoch",
    "snapshot_export",
    "scrollback_seed",
    "tail_latency",
    "render_dump",
    "diff_apply",
    "input_ready",
)
PROMPT_COMMANDS = (
    "codex resume 019e380a-9def-7852-9834-74c67b2da894",
    "rg -n owner_first_input_ready apps/macos/Tests",
    "spaces terminal tail --lines 120 $SESSION_ID",
    "swift test --filter GhosttyEmbeddedSessionHostTests",
    "apps/macos/Tests/e2e_mobile.sh --scenario scrollback",
)
TRANSCRIPT_ROLES = ("assistant", "tool", "stdout", "diff", "plan", "status")


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


def emit_codex_churn_stream(args: argparse.Namespace, rng: random.Random) -> int:
    line_seq = 0
    history_prompt_interval = max(args.rows * 18, 120)
    sys.stdout.write("\x1b[?25l")
    for history_index in range(1, args.lines + 1):
        if history_index == 1 or history_index % history_prompt_interval == 0:
            prompt_index = 0 if history_index == 1 else (history_index // history_prompt_interval) % len(PROMPT_COMMANDS)
            command = PROMPT_COMMANDS[prompt_index]
            sys.stdout.write(f"workspace@spaces pty % {command}\n")
            sys.stdout.write(
                f"> scrollback checkpoint={history_index:05d} owner=mac detail={STATUS_PHASES[(history_index // history_prompt_interval) % len(STATUS_PHASES)]}\n"
            )
        line_seq += 1
        topic = HISTORY_TOPICS[(history_index - 1) % len(HISTORY_TOPICS)]
        payload = random_payload(max(args.width - 28, 8), rng)
        sys.stdout.write(f"SEQ {line_seq:08d} HISTORY {history_index:05d} TOPIC {topic} {payload}\n")
        if args.flush_every and history_index % args.flush_every == 0:
            sys.stdout.flush()

    sys.stdout.write("workspace@spaces pty % codex resume 019e380a-9def-7852-9834-74c67b2da894\n")
    sys.stdout.write("> rebuilding owner epoch from standalone takeover artifacts\n")

    for frame in range(1, args.frames + 1):
        spinner = SPINNER_STATES[(frame - 1) % len(SPINNER_STATES)]
        phase = STATUS_PHASES[(frame - 1) % len(STATUS_PHASES)]
        pending_frames = args.frames - frame
        base_status = f"[{spinner}] CODEX_STATUS FRAME {frame:06d}/{args.frames:06d} phase={phase} pending={pending_frames:04d} seq={line_seq:08d}"
        for repaint in range(3):
            sys.stdout.write(f"\r\x1b[2K{base_status} repaint={repaint}")
            sys.stdout.flush()
        sys.stdout.write(f"\r\x1b[2K{base_status} committed\n")

        if frame % 7 == 1:
            command = PROMPT_COMMANDS[(frame // 7) % len(PROMPT_COMMANDS)]
            sys.stdout.write(f"workspace@spaces pty % {command}\n")
            sys.stdout.write(f"> owner=ipad bootstrap=stable frame={frame:06d} source=live_snapshot\n")

        for row in range(1, args.rows + 1):
            line_seq += 1
            role = TRANSCRIPT_ROLES[(line_seq + frame + row) % len(TRANSCRIPT_ROLES)]
            payload = random_payload(max(args.width - 32, 8), rng)
            template_index = (frame + row + line_seq) % 6
            if template_index == 0:
                detail = f"checkpoint=scrollback_guard invariant=single_epoch payload={payload}"
            elif template_index == 1:
                detail = (
                    f"command=rg pattern=owner_first_input_ready hits={(frame + row) % 5 + 1} "
                    f"window={max(frame - 2, 1):06d}-{frame:06d} payload={payload}"
                )
            elif template_index == 2:
                detail = (
                    f"metric=terminal_tail_read p95_ms={18 + (frame % 11)} "
                    f"tail_bytes={1400 + frame * row} payload={payload}"
                )
            elif template_index == 3:
                detail = (
                    f"file=GhosttyRemoteTerminalView.swift hunk=owner_epoch trim={frame % 2} "
                    f"rows={row:03d} payload={payload}"
                )
            elif template_index == 4:
                detail = (
                    f"step=owner_ready_assert frame={frame:06d} row={row:03d} "
                    f"recovery=explicit_resync payload={payload}"
                )
            else:
                detail = (
                    f"channel=stdout token_batch={(frame * row) % 17 + 1} "
                    f"cursor=redraw payload={payload}"
                )
            sys.stdout.write(f"SEQ {line_seq:08d} FRAME {frame:06d} ROW {row:03d} ROLE {role} {detail}\n")

        footer_tail_ms = 11 + (frame % 9)
        footer_backlog = max((args.frames - frame) * args.rows, 0)
        sys.stdout.write(
            f"TAIL frame={frame:06d} state=pending tail_ms={footer_tail_ms:03d} backlog={footer_backlog:05d}\n"
        )
        sys.stdout.write("\x1b[1A\r\x1b[2K")
        sys.stdout.write(
            f"TAIL frame={frame:06d} state=updated tail_ms={footer_tail_ms + 2:03d} backlog={max(footer_backlog - args.rows, 0):05d}\n"
        )
        if frame % 5 == 0:
            sys.stdout.write("\x1b[1A\r\x1b[2K")
            sys.stdout.write(f"TAIL frame={frame:06d} state=settled tail_ms={footer_tail_ms + 1:03d} backlog=00000\n")

        sys.stdout.flush()
        if args.sleep_ms:
            time.sleep(args.sleep_ms / 1000.0)

    sys.stdout.write(f"\r\x1b[2K[ok] CODEX_STATUS FRAME {args.frames:06d}/{args.frames:06d} phase=settled pending=0000 seq={line_seq:08d}\n")
    sys.stdout.write("workspace@spaces pty % codex status --complete\n")
    sys.stdout.write("\x1b[?25h\n")
    sys.stdout.flush()
    return line_seq


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["lines", "repaint", "mixed", "codex_churn"], required=True)
    parser.add_argument("--lines", type=int, default=20000)
    parser.add_argument("--frames", type=int, default=300)
    parser.add_argument("--rows", type=int, default=24)
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
    elif args.mode == "mixed":
        emitted = emit_mixed_stream(args, rng)
    else:
        emitted = emit_codex_churn_stream(args, rng)

    print(f"FIXTURE_DONE mode={args.mode} emitted={emitted}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
