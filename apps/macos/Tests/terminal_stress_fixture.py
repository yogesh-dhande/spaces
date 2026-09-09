#!/usr/bin/env python3
import argparse
import random
import re
import signal
import string
import sys
import textwrap
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
    "apps/macos/Tests/e2e.sh mobile --scenario scrollback",
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


AGENT_NAMES = ("codex", "claude", "spaces-agent")
MODEL_NAMES = ("gpt-5.6-sol", "claude-sonnet-5", "opus-4.6")

FG = {
    "cyan": "\x1b[38;5;51m",
    "magenta": "\x1b[38;5;213m",
    "green": "\x1b[38;5;114m",
    "grey": "\x1b[38;5;244m",
    "blue": "\x1b[38;5;75m",
    "white": "\x1b[38;5;253m",
}
BOLD = "\x1b[1m"
RESET = "\x1b[0m"

CODE_KEYWORDS = (
    "def", "return", "import", "from", "class", "if", "elif", "else", "for", "while",
    "try", "except", "finally", "await", "async", "with", "as", "in", "not", "and",
    "or", "lambda", "yield", "raise", "assert", "pass", "break", "continue", "global",
    "nonlocal", "del", "is", "None", "True", "False", "self",
)
_KEYWORD_RE = re.compile(r"\b(" + "|".join(CODE_KEYWORDS) + r")\b")
_STRING_RE = re.compile(r'"[^"]*"')
_COMMENT_RE = re.compile(r"#.*$")

CODE_FUNCS = (
    "reconcile_scrollback", "apply_patch", "flush_render_dump", "tail_session",
    "resync_owner", "commit_epoch", "drain_queue", "seed_snapshot",
)
CODE_ARG_LISTS = (
    "session_id, cursor",
    "path, *, force=False",
    "frame, owner",
    "event, deadline_ms",
)
CODE_VARS = ("frame", "owner", "cursor", "tail", "epoch", "patch", "snapshot")
CODE_MODULES = ("workspacecore", "spacesd.session", "ghostty_vt", "terminalengine")
CODE_EXCEPTIONS = (
    "OwnerEpochStale", "RenderDumpTimeout", "ScrollbackGuardError", "SessionClosed",
)
CODE_MESSAGES = (
    "owner epoch mismatch",
    "scrollback checkpoint missing",
    "render dump stalled",
    "session already closed",
)
CODE_CLASSES = (
    "OwnerEpochGuard", "ScrollbackSeed", "RenderDumpWriter", "SessionTail",
)
CODE_TEMPLATES = (
    "def {func}({args}):",
    "    return {var}.snapshot()  # {msg}",
    "    self.{var} = {func}({var})",
    "    if not {var}:",
    '        raise {exc}("{msg}")',
    "    for {var} in tail_events:",
    "        {var}.append(frame)",
    '    with open("scrollback.log") as f:',
    "        data = f.read()",
    "    # {msg}",
    "    import {module}",
    "    async def {func}({args}):",
    "    await {func}({var})",
    '    assert {var}, "{msg}"',
    "    try:",
    "    except {exc} as e:",
    '        logger.warning("{msg}")',
    "class {cls}:",
)
PROSE_SENTENCES = (
    "Reviewing the diff before applying it to make sure the scrollback invariant still holds.",
    "The owner epoch has to advance once the standalone takeover finishes or stale frames leak through.",
    "Tail latency on the render dump looks fine, but the snapshot export is still buffering output.",
    "Reconciling the scrollback seed against the last checkpoint before the patch gets written.",
    "Waiting on input_ready before it retries the diff apply against the checked out worktree.",
    "The status line should reflect elapsed time in seconds once the owner epoch is confirmed stable.",
    "Checking render_dump for a matching frame before it commits the patch to the working tree.",
    "The snapshot export finished, so it is scanning metrics before writing the final patch summary.",
)


def random_code_text(rng: random.Random) -> str:
    template = rng.choice(CODE_TEMPLATES)
    return template.format(
        func=rng.choice(CODE_FUNCS),
        args=rng.choice(CODE_ARG_LISTS),
        var=rng.choice(CODE_VARS),
        msg=rng.choice(CODE_MESSAGES),
        exc=rng.choice(CODE_EXCEPTIONS),
        module=rng.choice(CODE_MODULES),
        cls=rng.choice(CODE_CLASSES),
    )


def random_prose_text(rng: random.Random) -> str:
    sentence_count = rng.randint(1, 2)
    return " ".join(rng.choice(PROSE_SENTENCES) for _ in range(sentence_count))


def colorize_code_row(text: str) -> str:
    # Comments are colored first so keyword/string coloring never reaches into
    # the trailing comment text (a "#" inside a string literal is rare in the
    # generated templates and not handled).
    comment_match = _COMMENT_RE.search(text)
    if comment_match:
        code_part = text[: comment_match.start()]
        comment_part = FG["grey"] + text[comment_match.start():] + RESET
    else:
        code_part = text
        comment_part = ""
    code_part = _STRING_RE.sub(lambda m: FG["green"] + m.group(0) + RESET, code_part)
    code_part = _KEYWORD_RE.sub(lambda m: FG["magenta"] + BOLD + m.group(0) + RESET, code_part)
    return code_part + comment_part


def emit_history_lines(args: argparse.Namespace, rng: random.Random) -> None:
    for index in range(1, args.history_lines + 1):
        prefix = f"HIST {index} "
        is_code = index % 2 == 0
        content = random_code_text(rng) if is_code else random_prose_text(rng)
        available = max(args.width - len(prefix), 8)
        wrapped_rows = textwrap.wrap(content, available) or [""]
        for row_index, row in enumerate(wrapped_rows):
            colored = colorize_code_row(row) if is_code else FG["white"] + row + RESET
            lead = prefix if row_index == 0 else " " * len(prefix)
            sys.stdout.write(lead + colored + RESET + "\n")
        if args.flush_every and index % args.flush_every == 0:
            sys.stdout.flush()
    sys.stdout.flush()


def emit_prompt_box(args: argparse.Namespace) -> None:
    width = max(args.width, 8)
    inner = width - 2
    prompt_text = "> agent idle, awaiting input"[:inner].ljust(inner)
    sys.stdout.write(FG["blue"] + "┌" + ("─" * inner) + "┐" + RESET + "\n")
    sys.stdout.write(FG["blue"] + "│" + RESET + prompt_text + FG["blue"] + "│" + RESET + "\n")
    sys.stdout.write(FG["blue"] + "└" + ("─" * inner) + "┘" + RESET + "\n")
    sys.stdout.flush()


def emit_agent_screen_paint(args: argparse.Namespace, rng: random.Random) -> None:
    sys.stdout.write("\x1b[2J\x1b[H")

    agent_name = rng.choice(AGENT_NAMES)
    model_name = rng.choice(MODEL_NAMES)
    tokens_in = rng.randint(1200, 48000)
    tokens_out = rng.randint(400, 12000)
    elapsed_s = rng.randint(30, 900)
    status = (
        f"agent={agent_name} model={model_name} tokens_in={tokens_in} "
        f"tokens_out={tokens_out} elapsed={elapsed_s}s"
    )
    sys.stdout.write(BOLD + FG["cyan"] + status + RESET + "\n")

    paragraph = random_prose_text(rng) + " " + random_prose_text(rng)
    for row in textwrap.wrap(paragraph, max(args.width, 8)):
        sys.stdout.write(FG["white"] + row + RESET + "\n")
    sys.stdout.write("\n")

    code_line_count = rng.randint(12, 18)
    for _ in range(code_line_count):
        sys.stdout.write(colorize_code_row(random_code_text(rng)) + RESET + "\n")
    sys.stdout.write("\n")

    emit_prompt_box(args)

    sys.stdout.write("AGENT_SCREEN_READY\n")
    sys.stdout.flush()


def emit_burst(args: argparse.Namespace, rng: random.Random, burst_index: int) -> None:
    # Rows are built before the paced loop so the per-line cost is the sleep, not the colorizer.
    rows = [
        (colorize_code_row(random_code_text(rng)) + RESET) if line_index % 3 == 0 else (FG["white"] + random_prose_text(rng) + RESET)
        for line_index in range(1, args.burst_lines + 1)
    ]
    # A paced burst (the lane passes --sleep-ms) streams like an agent printing output over a few
    # seconds; an unpaced one lands in one write and shows up as a single frame. Pacing is by absolute
    # deadline rather than one sleep per line: a host whose timer overshoots (macOS coalesces a 10 ms
    # sleep to 30 ms or more) then writes a few lines back to back and keeps the average rate.
    started = time.monotonic()
    for line_index, row in enumerate(rows, start=1):
        sys.stdout.write(row + "\n")
        if args.flush_every and line_index % args.flush_every == 0:
            sys.stdout.flush()
        if args.sleep_ms > 0:
            sys.stdout.flush()
            deadline = started + line_index * args.sleep_ms / 1000.0
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(remaining)
    sys.stdout.flush()
    emit_prompt_box(args)
    sys.stdout.write(f"BURST_DONE {burst_index}\n")
    sys.stdout.flush()


def _exit_zero(signum, frame) -> None:
    sys.exit(0)


def emit_agent_screen(args: argparse.Namespace, rng: random.Random) -> int:
    if args.history_lines > 0:
        emit_history_lines(args, rng)

    emit_agent_screen_paint(args, rng)

    if not args.burst_on_stdin:
        # The fixture only ever writes to its own stdout (no files/sockets to
        # release), so exiting straight from the signal handler is safe.
        signal.signal(signal.SIGTERM, _exit_zero)
        signal.signal(signal.SIGHUP, _exit_zero)
        while True:
            time.sleep(1)

    burst_index = 0
    while True:
        line = sys.stdin.readline()
        if line == "":
            return burst_index
        burst_index += 1
        emit_burst(args, rng, burst_index)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["lines", "repaint", "mixed", "codex_churn", "agent_screen"], required=True)
    parser.add_argument("--lines", type=int, default=20000)
    parser.add_argument("--frames", type=int, default=300)
    parser.add_argument("--rows", type=int, default=24)
    parser.add_argument("--width", type=int, default=72)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--sleep-ms", type=int, default=0)
    parser.add_argument("--flush-every", type=int, default=100)
    parser.add_argument("--history-lines", type=int, default=0)
    parser.add_argument("--burst-on-stdin", action="store_true")
    parser.add_argument("--burst-lines", type=int, default=400)
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
    elif args.mode == "codex_churn":
        emitted = emit_codex_churn_stream(args, rng)
    else:
        emitted = emit_agent_screen(args, rng)

    print(f"FIXTURE_DONE mode={args.mode} emitted={emitted}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
