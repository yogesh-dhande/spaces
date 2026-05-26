#!/usr/bin/env python3
import argparse
import csv
import html
from collections import defaultdict
from pathlib import Path


FIELDNAMES = [
    "run_id",
    "timestamp",
    "machine_name",
    "machine_model",
    "git_branch",
    "git_sha",
    "git_state",
    "worktree_fingerprint",
    "metric",
    "terminal_host",
    "workspace_scope",
    "sample_count",
    "avg_ms",
    "min_ms",
    "max_ms",
    "samples_ms",
]

ABSOLUTE_HEAT_MIN_MS = 0.0
ABSOLUTE_HEAT_MAX_MS = 2000.0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Append real-system profile metrics and render a static HTML report.")
    parser.add_argument("--metrics-log", required=True)
    parser.add_argument("--csv", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--timestamp", required=True)
    parser.add_argument("--machine-name", required=True)
    parser.add_argument("--machine-model", required=True)
    parser.add_argument("--git-branch", required=True)
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--git-state", required=True, choices=["clean", "dirty"])
    parser.add_argument("--worktree-fingerprint", required=True)
    return parser.parse_args()


def load_metric_samples(path: Path) -> dict[tuple[str, str, str], list[int]]:
    grouped: dict[tuple[str, str, str], list[int]] = defaultdict(list)
    for raw_line in path.read_text().splitlines():
        if not raw_line.strip():
            continue
        parts = raw_line.split("\t")
        if len(parts) < 2:
            raise ValueError(f"Malformed metrics log line: {raw_line}")
        metric = parts[0]
        value = int(parts[1])
        metadata: dict[str, str] = {}
        for part in parts[2:]:
            key, _, raw_value = part.partition("=")
            if key:
                metadata[key] = raw_value
        terminal_host = metadata.get("terminal_host", "unknown")
        workspace_scope = metadata.get("workspace_scope", "single")
        grouped[(metric, terminal_host, workspace_scope)].append(value)
    return grouped


def build_rows(args: argparse.Namespace, grouped: dict[tuple[str, str, str], list[int]]) -> list[dict[str, str]]:
    machine_slug = args.machine_name.lower().replace(" ", "-")
    run_id = f"{args.timestamp}-{args.git_sha[:12]}-{args.git_state}-{args.worktree_fingerprint[:12]}-{machine_slug}"
    rows: list[dict[str, str]] = []
    for (metric, terminal_host, workspace_scope) in sorted(grouped):
        samples = grouped[(metric, terminal_host, workspace_scope)]
        avg_ms = sum(samples) / len(samples)
        rows.append(
            {
                "run_id": run_id,
                "timestamp": args.timestamp,
                "machine_name": args.machine_name,
                "machine_model": args.machine_model,
                "git_branch": args.git_branch,
                "git_sha": args.git_sha,
                "git_state": args.git_state,
                "worktree_fingerprint": args.worktree_fingerprint,
                "metric": metric,
                "terminal_host": terminal_host,
                "workspace_scope": workspace_scope,
                "sample_count": str(len(samples)),
                "avg_ms": f"{avg_ms:.1f}",
                "min_ms": str(min(samples)),
                "max_ms": str(max(samples)),
                "samples_ms": ",".join(str(sample) for sample in samples),
            }
        )
    return rows


def load_history(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def write_history(path: Path, existing_rows: list[dict[str, str]], new_rows: list[dict[str, str]]) -> list[dict[str, str]]:
    replacement_keys = {
        (row["run_id"], row["metric"], row["terminal_host"], row["workspace_scope"])
        for row in new_rows
    }
    all_rows = [
        row for row in existing_rows
        if (row["run_id"], row["metric"], row.get("terminal_host", ""), row.get("workspace_scope", ""))
        not in replacement_keys
    ] + new_rows
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(all_rows)
    return all_rows


def revision_label(row: dict[str, str]) -> str:
    fingerprint = row["worktree_fingerprint"][:12]
    if row["git_state"] == "clean":
        return row["git_sha"][:12]
    return f'{row["git_sha"][:12]}+{fingerprint}'


def timing_heat_style(value: float) -> str:
    clamped = min(max(value, ABSOLUTE_HEAT_MIN_MS), ABSOLUTE_HEAT_MAX_MS)
    ratio = (clamped - ABSOLUTE_HEAT_MIN_MS) / (ABSOLUTE_HEAT_MAX_MS - ABSOLUTE_HEAT_MIN_MS)
    red = int(255 - (ratio * 20))
    green = int(241 - (ratio * 110))
    blue = int(214 - (ratio * 120))
    alpha = 0.18 + (ratio * 0.42)
    return f"background-color: rgba({red}, {green}, {blue}, {alpha:.2f});"


def render_snapshot_row(label: str, row: dict[str, str] | None) -> str:
    if row is None:
        return "<tr><th>{}</th><td colspan=\"10\">No run yet</td></tr>".format(html.escape(label))
    row_style = timing_heat_style(float(row["avg_ms"]))
    return (
        f"<tr style=\"{row_style}\">"
        f"<th>{html.escape(label)}</th>"
        f"<td>{html.escape(row['timestamp'])}</td>"
        f"<td>{html.escape(row['git_branch'])}</td>"
        f"<td><code>{html.escape(revision_label(row))}</code></td>"
        f"<td>{html.escape(row['git_state'])}</td>"
        f"<td>{html.escape(row['machine_name'])}</td>"
        f"<td>{html.escape(row['machine_model'])}</td>"
        f"<td>{html.escape(row['avg_ms'])}</td>"
        f"<td>{html.escape(row['min_ms'])}</td>"
        f"<td>{html.escape(row['max_ms'])}</td>"
        f"<td>{html.escape(row['sample_count'])}</td>"
        "</tr>"
    )


def host_label(terminal_host: str) -> str:
    return "iTerm2" if terminal_host == "iterm2" else "Ghostty" if terminal_host == "ghostty" else terminal_host


def scope_label(workspace_scope: str) -> str:
    labels = {
        "single": "single-workspace",
        "primary": "primary-workspace",
        "secondary": "secondary-workspace",
    }
    return labels.get(workspace_scope, workspace_scope)


def metric_description(metric: str, terminal_host: str, workspace_scope: str) -> str:
    prefix = f"Recorded during the {host_label(terminal_host)} {scope_label(workspace_scope)} real-system scenario, this metric"

    descriptions = {
        "browser_untracked_tab.cli_window_focus.browser_tracked_tab":
            "measures how long Spaces takes to use CLI window focus to move from an untracked browser tab back to the tracked browser tab.",
        "terminal_untracked_tab.cli_window_focus.process_tracked_tab":
            "measures how long Spaces takes to use CLI window focus to move from an untracked terminal tab back to the tracked process tab.",
        "spaces_detail_ui.keyboard_window_shortcut.browser_tracked_tab":
            "measures how long Spaces takes to complete a numbered window shortcut from the Spaces detail UI and focus the tracked browser tab.",
        "spaces_detail_ui.keyboard_window_shortcut.process_tracked_tab":
            "measures how long Spaces takes to complete a numbered window shortcut from the Spaces detail UI and focus the tracked process tab.",
        "terminal_tracked_tab.keyboard_cycle_next.browser_tracked_tab":
            "measures how long Spaces takes to cycle forward from the tracked terminal tab to the tracked browser tab.",
        "browser_tracked_tab.keyboard_cycle_previous.terminal_tracked_tab":
            "measures how long Spaces takes to cycle backward from the tracked browser tab to the tracked terminal tab.",
        "external_app.keyboard_toggle_main_window.main_window":
            "measures how long Spaces takes to show the main app window when another app is frontmost.",
        "main_window.keyboard_toggle_main_window.external_app":
            "measures how long Spaces takes to hide the main app window and return focus away from Spaces.",
        "external_app.keyboard_toggle_palette.palette":
            "measures how long Spaces takes to show the command palette when another app is frontmost.",
        "palette.keyboard_toggle_palette.external_app":
            "measures how long Spaces takes to hide the command palette and return focus away from Spaces.",
        "main_window.keyboard_toggle_palette.palette":
            "measures how long Spaces takes to show the command palette when the main app window is frontmost.",
        "palette.keyboard_toggle_palette.main_window":
            "measures how long Spaces takes to hide the command palette and return to the main app window.",
        "spaces_terminal.keyboard_toggle_palette.palette":
            "measures how long Spaces takes to show the command palette when a built-in Spaces terminal is frontmost.",
        "palette.cli_window_focus.process_tracked_tab":
            "measures how long Spaces takes to refocus the tracked built-in process terminal after dismissing the command palette.",
    }

    suffix = descriptions.get(metric, f"captures the real-system timing for `{metric}`.")
    return f"{prefix} {suffix}"


def render_report(rows: list[dict[str, str]], report_path: Path) -> None:
    grouped: dict[tuple[str, str, str], list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        grouped[(row["metric"], row["terminal_host"], row["workspace_scope"])].append(row)

    sections: list[str] = []
    for key in sorted(grouped):
        metric, terminal_host, workspace_scope = key
        metric_rows = grouped[key]
        latest = metric_rows[-1]
        previous = metric_rows[-2] if len(metric_rows) > 1 else None
        best = min(metric_rows, key=lambda row: (float(row["avg_ms"]), int(row["min_ms"]), row["timestamp"], row["run_id"]))
        sections.append(
            f"""
<section class="metric">
  <h2>{html.escape(metric)}</h2>
  <p class="meta">Host: <code>{html.escape(host_label(terminal_host))}</code> · Workspace scope: <code>{html.escape(workspace_scope)}</code></p>
  <p>{html.escape(metric_description(metric, terminal_host, workspace_scope))}</p>
  <p class="samples">Latest samples: <code>{html.escape(latest["samples_ms"])}</code></p>
  <table>
    <thead>
      <tr>
        <th>Snapshot</th>
        <th>Timestamp</th>
        <th>Branch</th>
        <th>Revision</th>
        <th>State</th>
        <th>Machine</th>
        <th>Model</th>
        <th>Avg ms</th>
        <th>Min ms</th>
        <th>Max ms</th>
        <th>Count</th>
      </tr>
    </thead>
    <tbody>
      {render_snapshot_row("Best", best)}
      {render_snapshot_row("Previous", previous)}
      {render_snapshot_row("Latest", latest)}
    </tbody>
  </table>
</section>
""".strip()
        )

    report_path.write_text(
        f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Spaces Real-System Profiling</title>
  <style>
    :root {{
      color-scheme: light dark;
      --bg: #f4efe8;
      --panel: #fffdf9;
      --text: #1f2328;
      --muted: #5f6b76;
      --border: #d9cfc1;
      --accent: #8f3b2e;
    }}
    @media (prefers-color-scheme: dark) {{
      :root {{
        --bg: #181512;
        --panel: #221d18;
        --text: #f6efe5;
        --muted: #c3b3a1;
        --border: #4b4035;
        --accent: #f3a36b;
      }}
    }}
    body {{
      margin: 0;
      font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: linear-gradient(180deg, var(--bg), color-mix(in srgb, var(--bg) 82%, var(--accent)));
      color: var(--text);
    }}
    main {{
      max-width: 1200px;
      margin: 0 auto;
      padding: 32px 20px 56px;
    }}
    h1 {{
      margin: 0 0 8px;
      font-size: 2rem;
    }}
    p {{
      color: var(--muted);
    }}
    .metric {{
      margin-top: 24px;
      padding: 20px;
      border: 1px solid var(--border);
      border-radius: 18px;
      background: var(--panel);
      box-shadow: 0 16px 40px rgba(0, 0, 0, 0.08);
    }}
    .meta {{
      margin-bottom: 4px;
    }}
    .samples {{
      margin-top: 0;
      overflow-wrap: anywhere;
    }}
    table {{
      width: 100%;
      border-collapse: collapse;
      margin-top: 12px;
      font-size: 0.95rem;
    }}
    th, td {{
      text-align: left;
      padding: 10px 8px;
      border-top: 1px solid var(--border);
      vertical-align: top;
    }}
    thead th {{
      color: var(--muted);
      font-weight: 600;
    }}
    tbody tr {{
      transition: background-color 120ms ease;
    }}
    code {{
      font-family: ui-monospace, "SFMono-Regular", Menlo, monospace;
    }}
  </style>
</head>
<body>
  <main>
    <h1>Spaces Real-System Profiling</h1>
    <p>Aggregated from clean and dirty worktree runs of <code>apps/macos/Tests/e2e_macos_app.sh</code>. Dirty revisions are labeled as <code>HEAD+fingerprint</code>.</p>
    {''.join(sections) if sections else '<p>No profiling history recorded yet.</p>'}
  </main>
</body>
</html>
""",
        encoding="utf-8",
    )


def main() -> None:
    args = parse_args()
    metrics_log = Path(args.metrics_log)
    csv_path = Path(args.csv)
    report_path = Path(args.report)
    grouped = load_metric_samples(metrics_log)
    new_rows = build_rows(args, grouped)
    history = load_history(csv_path)
    all_rows = write_history(csv_path, history, new_rows)
    render_report(all_rows, report_path)


if __name__ == "__main__":
    main()
