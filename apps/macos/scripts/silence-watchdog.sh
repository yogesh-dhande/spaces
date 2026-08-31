#!/bin/sh

# Both tree walkers read "$1" directly instead of naming a variable: POSIX sh
# variables are global, so a recursive call would overwrite the parent level's
# copy and the post-recursion signal would hit the last descendant again
# instead of the parent. Positional parameters are the one per-call scope.
kill_silence_watchdog_process_tree() {
    for watchdog_child in $(pgrep -P "$1" 2>/dev/null); do
        kill_silence_watchdog_process_tree "$watchdog_child"
    done
    kill -KILL "$1" 2>/dev/null || true
}

# Freezes a tree with SIGSTOP, parent before children, so a frozen parent
# cannot spawn replacements while its descendants are still being walked.
# A stopped process still accepts task inspection (`sample`) and SIGKILL.
stop_silence_watchdog_process_tree() {
    kill -STOP "$1" 2>/dev/null || true
    for watchdog_child in $(pgrep -P "$1" 2>/dev/null); do
        stop_silence_watchdog_process_tree "$watchdog_child"
    done
}

# The SIGKILL that follows a silence timeout destroys the only evidence of
# where the run wedged, and CI hangs of this shape (#583) have never reproduced
# locally — so before killing, capture a process listing and per-process thread
# stacks (`sample`) of the hung tree into the caller's log. Everything here is
# best-effort: a process that exits mid-capture or refuses task inspection
# leaves a note instead of a report and never blocks the kill.
capture_silence_watchdog_hang_evidence() {
    watchdog_hang_root="$1"
    watchdog_hang_dir="$2"

    watchdog_hang_pids=""
    watchdog_hang_queue="$watchdog_hang_root"
    while [ -n "$watchdog_hang_queue" ]; do
        watchdog_hang_next=""
        for watchdog_hang_pid in $watchdog_hang_queue; do
            watchdog_hang_pids="$watchdog_hang_pids $watchdog_hang_pid"
            watchdog_hang_next="$watchdog_hang_next $(pgrep -P "$watchdog_hang_pid" 2>/dev/null || true)"
        done
        # Unquoted expansion through echo collapses the accumulated whitespace;
        # an all-space string becomes empty and ends the walk.
        # shellcheck disable=SC2086,SC2116
        watchdog_hang_queue="$(echo $watchdog_hang_next)"
    done

    echo "=== silence-watchdog: process tree at kill time ==="
    # Darwin ps takes a single comma-separated pid list after -p.
    # shellcheck disable=SC2086
    ps -o pid,ppid,state,%cpu,etime,command -p "$(echo $watchdog_hang_pids | tr ' ' ',')" 2>/dev/null || true

    # `sample` runs 2 seconds per process; the cap bounds the pre-kill delay and
    # the log volume if a runaway tree ever forks wide.
    watchdog_hang_sampled=0
    for watchdog_hang_pid in $watchdog_hang_pids; do
        if [ "$watchdog_hang_sampled" -ge 12 ]; then
            echo "=== silence-watchdog: sampling stopped after $watchdog_hang_sampled processes ==="
            break
        fi
        watchdog_hang_sampled=$((watchdog_hang_sampled + 1))
        echo "=== silence-watchdog: thread stacks for pid $watchdog_hang_pid ==="
        watchdog_hang_sample_file="$watchdog_hang_dir/sample-$watchdog_hang_pid.txt"
        sample "$watchdog_hang_pid" 2 -file "$watchdog_hang_sample_file" \
            >/dev/null 2>"$watchdog_hang_sample_file.err" || true
        if [ -s "$watchdog_hang_sample_file" ]; then
            cat "$watchdog_hang_sample_file"
        else
            echo "(sample produced no report for pid $watchdog_hang_pid)"
            cat "$watchdog_hang_sample_file.err" 2>/dev/null || true
        fi
    done
}

run_with_silence_watchdog() (
    watchdog_seconds="$1"
    shift

    case "$watchdog_seconds" in
        ''|*[!0-9]*)
            echo "Silence watchdog duration must be a non-negative integer: $watchdog_seconds" >&2
            exit 2
            ;;
    esac
    if [ "$watchdog_seconds" -eq 0 ]; then
        "$@"
        exit $?
    fi

    watchdog_poll_seconds=5
    if [ "$watchdog_seconds" -lt "$watchdog_poll_seconds" ]; then
        watchdog_poll_seconds=1
    fi

    watchdog_output_dir="$(mktemp -d -t spaces-silence-watchdog)"
    watchdog_log="$watchdog_output_dir/output.log"
    watchdog_timeout_path="$watchdog_output_dir/timed-out"
    watchdog_done_path="$watchdog_output_dir/done"
    : >"$watchdog_log"
    trap 'rm -rf "$watchdog_output_dir"' EXIT

    # The work process writes directly to a file, never a pipe: a plain file write
    # cannot block on a stalled downstream reader, so the log's mtime is a true
    # liveness signal. Piping through `tee` (the prior implementation) let a CI
    # runner that stalls draining the step's stdout backpressure `tee` itself,
    # freezing the mtime and causing the watchdog to kill a healthy process
    # (#583). The forwarder below re-streams this file to stdout on its own
    # schedule, so a stalled consumer can only stall the forwarder, never the
    # liveness signal.
    "$@" >>"$watchdog_log" 2>&1 &
    watchdog_work_pid=$!

    (
        watchdog_forward_offset=0
        watchdog_forward_quiet=0
        while :; do
            [ -f "$watchdog_log" ] || exit 0
            # Read the done flag before the size so the final tail after the work
            # process exits and the flag is set is never missed.
            watchdog_forward_done=0
            [ -f "$watchdog_done_path" ] && watchdog_forward_done=1
            watchdog_forward_size="$(stat -f %z "$watchdog_log" 2>/dev/null || true)"
            case "$watchdog_forward_size" in
                ''|*[!0-9]*) watchdog_forward_size="$watchdog_forward_offset" ;;
            esac
            if [ "$watchdog_forward_size" -gt "$watchdog_forward_offset" ]; then
                # `head` bounds the copy to exactly the snapshot range, so a
                # concurrent append cannot leak past it -- but it can SIGPIPE
                # `tail` mid-copy, and this subshell inherits the caller's shell
                # options (errexit/pipefail under bash callers), so the pipeline
                # status must be ignored or the forwarder dies and drops the rest
                # of the output.
                tail -c "+$((watchdog_forward_offset + 1))" "$watchdog_log" | head -c "$((watchdog_forward_size - watchdog_forward_offset))" || true
                watchdog_forward_offset="$watchdog_forward_size"
                watchdog_forward_quiet=0
                continue
            elif [ "$watchdog_forward_done" -eq 1 ]; then
                # A background child of the work process that inherited stdout may
                # still write to the log after the work process itself exits, so
                # keep draining until the log has been quiet for two consecutive
                # checks. The bound is deliberate: the prior fifo implementation
                # forwarded until every inherited writer closed, which meant a
                # leaked silent child could block the caller forever; a straggler
                # that stays quiet past the grace loses its later output instead.
                watchdog_forward_quiet=$((watchdog_forward_quiet + 1))
                if [ "$watchdog_forward_quiet" -ge 2 ]; then
                    exit 0
                fi
            fi
            sleep 1
        done
    ) &
    watchdog_forwarder_pid=$!

    (
        while :; do
            sleep "$watchdog_poll_seconds"
            kill -0 "$watchdog_work_pid" 2>/dev/null || exit 0
            watchdog_last_output_epoch="$(stat -f %m "$watchdog_log" 2>/dev/null || true)"
            case "$watchdog_last_output_epoch" in
                ''|*[!0-9]*) continue ;;
            esac
            if [ "$(($(date +%s) - watchdog_last_output_epoch))" -ge "$watchdog_seconds" ]; then
                echo "Test process produced no output for ${watchdog_seconds}s; killing it as hung." >&3
                # Record the timeout before the multi-second evidence capture and
                # the kill: a process that exits mid-capture (or a fast-exiting
                # parent) has still exceeded the silence deadline and must not
                # turn the diagnosed timeout into its own exit status.
                : >"$watchdog_timeout_path"
                # Freeze the tree before the multi-second capture: a root that
                # exited mid-capture would reparent surviving children out of
                # the later tree walk's reach and leak them past the kill.
                stop_silence_watchdog_process_tree "$watchdog_work_pid"
                # Evidence goes through the log file, not fd 3: the log is the
                # backpressure-isolated channel (the forwarder drains it on its
                # own schedule), while a stalled fd-3 consumer could block the
                # monitor here before it ever kills the hung tree.
                capture_silence_watchdog_hang_evidence "$watchdog_work_pid" "$watchdog_output_dir" >>"$watchdog_log" 2>&1 || true
                kill_silence_watchdog_process_tree "$watchdog_work_pid"
                exit 0
            fi
        done
    ) 3>&2 2>/dev/null &
    watchdog_monitor_pid=$!

    trap 'kill_silence_watchdog_process_tree "$watchdog_work_pid" 2>/dev/null; kill_silence_watchdog_process_tree "$watchdog_monitor_pid" 2>/dev/null' INT TERM

    watchdog_status=0
    wait "$watchdog_work_pid" || watchdog_status=$?
    if [ -f "$watchdog_timeout_path" ]; then
        watchdog_status=124
    fi
    # Only mark done once the work process has exited, so the log is final by
    # the time the forwarder observes the flag and stops after its last tail.
    : >"$watchdog_done_path"
    kill_silence_watchdog_process_tree "$watchdog_monitor_pid" 2>/dev/null
    wait "$watchdog_monitor_pid" 2>/dev/null || true
    wait "$watchdog_forwarder_pid" 2>/dev/null || true
    exit "$watchdog_status"
)
