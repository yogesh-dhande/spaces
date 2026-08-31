#!/bin/sh

kill_silence_watchdog_process_tree() {
    watchdog_pid="$1"
    for watchdog_child in $(pgrep -P "$watchdog_pid" 2>/dev/null); do
        kill_silence_watchdog_process_tree "$watchdog_child"
    done
    kill -KILL "$watchdog_pid" 2>/dev/null || true
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
                # Record the timeout before killing so a fast-exiting parent cannot hide it.
                : >"$watchdog_timeout_path"
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
