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
    watchdog_fifo="$watchdog_output_dir/output"
    watchdog_log="$watchdog_output_dir/output.log"
    watchdog_timeout_path="$watchdog_output_dir/timed-out"
    mkfifo "$watchdog_fifo"
    : >"$watchdog_log"
    trap 'rm -rf "$watchdog_output_dir"' EXIT

    tee "$watchdog_log" <"$watchdog_fifo" &
    watchdog_tee_pid=$!

    "$@" >"$watchdog_fifo" 2>&1 &
    watchdog_work_pid=$!

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
    kill_silence_watchdog_process_tree "$watchdog_monitor_pid" 2>/dev/null
    wait "$watchdog_monitor_pid" 2>/dev/null || true
    wait "$watchdog_tee_pid" 2>/dev/null || true
    exit "$watchdog_status"
)
