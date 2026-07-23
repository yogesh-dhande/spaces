---
name: profile-cpu
description: Profile the CPU usage of the running Spaces app on this machine by sampling the live process while the user exercises it, then produce ranked findings anchored to this repo's source. Use when asked why Spaces is slow or burning CPU, to sample or profile the running app, or to investigate a performance spike.
---

# Profile live Spaces CPU

Measure the running process first. Never diagnose from source alone — the sample decides where the CPU goes; the code only explains why.

## Locate the process

1. Run `ps aux | grep -i SpacesApp | grep -v grep`. Target the main `/Applications/Spaces.app/Contents/MacOS/SpacesApp` binary, not `spacesd`, `caddy`, or other helpers. Note its accumulated CPU `TIME`.
2. Read the app version from a `sample <pid> 1` header — the installed build may lag `main`.

## Capture spikes

Spikes are intermittent and the app is usually idle, so catch them automatically.

1. Write a watcher that polls `ps -p <pid> -o %cpu=` every 3s and, when it crosses ~25%, runs `sample <pid> 5 -file <scratch>/spike_N.txt`. Run it in the background for several minutes.
2. Take one `sample <pid> 5` baseline immediately.
3. Ask the user to exercise the app — type in a terminal, scroll, switch tabs and workspaces — then ask what they did, so findings map to actions.
4. Stop the watcher once enough spikes are captured.

## Analyze

1. For each sample read the "Sort by top of stack" self-time ranking. Ignore idle-wait leaves — `kevent64`, `__workq_kernreturn`, `mach_msg2_trap`, `__psynch_cvwait`, `__ulock_wait2` are blocked threads, not CPU. The real cost is whatever remains.
2. Heavy Swift-runtime frames (`_swift_getGenericMetadata`, metadata-cache lookups, `swift_retain`/`swift_release`) signal generic code in a hot loop — attribute that cost to the app frame directly above it.
3. Find the busiest non-idle thread, trace its stack top to bottom, and confirm the pattern repeats across several spikes before trusting it.
4. Do not read a full sample transcript into context — grep or awk it, and keep raw files in a scratch dir.

## Anchor and report

1. Grep this repo for the symbol names in the hot stack to pin each finding to file:line.
2. The installed app may predate `main` — verify each finding still exists in current source and state which are already fixed.
3. Report ranked findings. For each: file:line, the evidence (sample counts), why it costs CPU, and a concrete fix direction. Separate the interaction-driven spike from any steady-state background cost.
