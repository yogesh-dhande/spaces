# Recording A Shortcut-Driven Spaces Demo

This document captures the exact workflow that worked for driving Spaces with keyboard shortcuts and recording the result from the shell.

## What This Demonstrates

- Foreground Spaces with the global shortcut `cmd+alt+=`
- Wait for Spaces to actually become frontmost
- Wait `2` seconds for the app to settle
- Open Settings with the app shortcut `cmd+,`
- Record the screen with `ffmpeg`

## Preconditions

- Spaces is already running
- Accessibility permissions are enabled for the terminal/tooling that sends keystrokes
- Screen Recording permissions are enabled for `ffmpeg` or the terminal that launches it
- The desired Spaces starting state is already visible
- If you want Settings hidden at the start, hide it manually first
- Google Chrome is open and can be used as the non-Spaces foreground app

## Important Findings

- `ffmpeg` screen capture on this machine takes a few seconds before frames actually start landing in the output file
- Because of that warm-up delay, start recording first and wait before sending any shortcuts
- After Spaces becomes frontmost, add an explicit `2` second delay before sending `cmd+,`
- `cmd+,` behaves like a toggle for the Settings view in this build
- `cmd+w` is not a safe way to reset state for this workflow because it may close the Spaces window instead of only dismissing Settings
- On this machine, `Capture screen 2` was the display that showed Spaces

## Confirm The Capture Device

List available AVFoundation devices:

```bash
ffmpeg -f avfoundation -list_devices true -i ''
```

Take one still frame from a candidate display:

```bash
ffmpeg -y -f avfoundation -pixel_format uyvy422 -i '2:none' -frames:v 1 -update 1 /tmp/muxy-check.jpg
```

If needed, repeat with another screen index such as `3:none`.

## Live Automation Sequence

This is the working visible automation sequence without recording:

```applescript
delay 1
tell application "Google Chrome" to activate

delay 2
tell application "System Events"
  key code 24 using {command down, option down}
end tell

set frontApp to ""
repeat 40 times
  delay 0.25
  tell application "System Events"
    set frontApp to name of first application process whose frontmost is true
  end tell
  if frontApp is "Spaces" then exit repeat
end repeat

delay 2
tell application "System Events"
  keystroke "," using {command down}
end tell
```

Run it from the repo root with:

```bash
osascript <<'APPLESCRIPT'
delay 1
tell application "Google Chrome" to activate

delay 2
tell application "System Events"
  key code 24 using {command down, option down}
end tell

set frontApp to ""
repeat 40 times
  delay 0.25
  tell application "System Events"
    set frontApp to name of first application process whose frontmost is true
  end tell
  if frontApp is "Spaces" then exit repeat
end repeat

delay 2
tell application "System Events"
  keystroke "," using {command down}
end tell
APPLESCRIPT
```

## Record The Demo

1. Put Spaces in the desired starting state.
2. Make sure Google Chrome is visible first.
3. Start `ffmpeg`.
4. Run the AppleScript sequence while `ffmpeg` is recording.
5. Let the recording continue a few more seconds after Settings opens.

### Start Recording

```bash
ffmpeg -y -f avfoundation -framerate 15 -pixel_format uyvy422 -i '2:none' -t 20 /tmp/muxy-shortcuts-demo.mp4
```

### Drive Spaces While Recording

```bash
osascript <<'APPLESCRIPT'
delay 1
tell application "Google Chrome" to activate

delay 2
tell application "System Events"
  key code 24 using {command down, option down}
end tell

set frontApp to ""
repeat 40 times
  delay 0.25
  tell application "System Events"
    set frontApp to name of first application process whose frontmost is true
  end tell
  if frontApp is "Spaces" then exit repeat
end repeat

delay 2
tell application "System Events"
  keystroke "," using {command down}
end tell
APPLESCRIPT
```

## Verify The Recording

Check the file exists and inspect duration:

```bash
ls -lh /tmp/muxy-shortcuts-demo.mp4
ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 /tmp/muxy-shortcuts-demo.mp4
```

Grab spot-check frames:

```bash
ffmpeg -y -ss 1 -i /tmp/muxy-shortcuts-demo.mp4 -frames:v 1 -update 1 /tmp/muxy-frame-a.jpg
ffmpeg -y -ss 10 -i /tmp/muxy-shortcuts-demo.mp4 -frames:v 1 -update 1 /tmp/muxy-frame-b.jpg
ffmpeg -y -ss 16 -i /tmp/muxy-shortcuts-demo.mp4 -frames:v 1 -update 1 /tmp/muxy-frame-c.jpg
```

Expected sequence:

- early frame: non-Spaces app visible
- middle frame: Spaces frontmost before Settings opens, or during the transition
- later frame: Spaces Settings visible

## Troubleshooting

If the video starts too late:

- increase recording length
- start recording earlier
- keep the `6` second or similar warm-up window before sending shortcuts

If Settings is already open when Spaces appears:

- confirm the app is really in the desired starting state before recording
- remember `cmd+,` toggles Settings in this build
- avoid using `cmd+w` as a reset step

If Spaces does not come forward:

- confirm the global shortcut is still `cmd+alt+=`
- confirm Accessibility permission for the process sending keystrokes
- confirm no other tool is intercepting the shortcut

If the wrong screen is recorded:

- repeat the single-frame capture test with another AVFoundation screen index

If `tell application "Spaces"` fails:

- use `System Events` keystroke automation instead of AppleScript app targeting

## Working Values Used In This Session

- Global shortcut: `cmd+alt+=`
- App shortcut: `cmd+,`
- Post-focus settle delay: `2` seconds
- Recorder warm-up buffer: about `6` seconds before sending shortcuts
- Working capture source: `2:none`
- Output path used for final successful run: `/tmp/muxy-shortcuts-demo-live.mp4`
