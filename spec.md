# Agentmux - Work stream orchestrator for vibecoding

## 0. Summary

Build a macOS-native app that lets users define **Projects** and launch multiple **Streams** per project.
Each stream reliably launches, attaches to, and tiles a fixed set of windows:

* **Editor**: one per stream (Windsurf, VS Code, Cursor)
* **Terminal**: N windows per stream (Terminal.app first)
* **Browser**: one Chrome window per stream with predefined tabs

The app must:

* launch apps if needed, attach to existing windows if possible
* **exit fullscreen before moving windows** (hard requirement)
* unminimize windows if needed
* tile windows on specific displays (half / quarter layouts)
* open and close streams deterministically

**MVP UI**: minimal GUI + hotkeys

GUI must allow:

* create/delete projects
* configure editor / terminal / browser windows and layouts
* create/delete streams (each stream = git worktree)
* list active streams
* switch streams via hotkeys or click

---

## 1. User & Workflow

### Target user

Agent power users running multiple AI coding agents across repos.

### Workflow

User defines configuration (YAML + local DB):

* **Project**

  * repo root
  * default editor / terminal / browser
  * window layout (display + tile per window)
* **Streams**

  * belong to a project
  * each stream has its own git worktree
  * opening a stream:

    * checks out worktree
    * opens editor, terminals, browser
    * applies layout

---

## 2. Scope

### MUST (MVP)

1. Project + Stream model
2. Launch / attach / reposition windows
3. Multi-monitor support with half/quarter tiling
4. One Chrome window per stream with configured tabs
5. Editor opens repo root + recent files
6. Terminal windows per stream (N)

   * track coding-agent activity per terminal
   * surface status in GUI
   * see `prototypes/agentwrap.sh` for reference
7. Robustness:

   * retries + backoff for app/window discovery
   * **exit fullscreen before moving**
   * clear errors for missing permissions

### SHOULD (if easy)

* Unminimize windows before positioning
* Deterministic “bring to front” ordering after launch

### NOT IN MVP

* Spaces management
* Exact session restore

---

## 3. Core Concepts

### Project

* `id`, `name`
* `repo_root` (absolute path)
* `default_editor`: windsurf | vscode | cursor
* `default_browser`: chrome
* `default_terminal`: Terminal
* `windows`:

  * editor (1)
  * terminal[] (N)
  * browser (1)
* `layout` per window:

  * `display_index` (0..N-1)
  * `tile`: leftHalf | rightHalf | topLeft | topRight | bottomLeft | bottomRight

### Stream

* belongs to a project
* `name` (unique within project, git worktree name)
* `worktree_path` (absolute)

### Window Targeting (critical)

All window targeting **must use bundle identifiers**, not names.

Examples:

* Windsurf: `com.exafunction.windsurf`
* Chrome: `com.google.Chrome`
* Terminal: `com.apple.Terminal`
* iTerm2: `com.googlecode.iterm2`
* VS Code: `com.microsoft.VSCode`
* Cursor: `com.todesktop.230313mzl4w4u92`

---

## 4. Technical Approach

### 4.1 Window Control (AX API)

Implement a low-level module that:

* finds apps by bundle id
* selects focused window first, fallback to window list
* supports:

  * `AXFullScreen = false`
  * `AXMinimized = false` (if supported)
  * `AXPosition`, `AXSize`

**Hard rule**
Always:

1. exit fullscreen
2. wait briefly
3. re-fetch focused window
   (fullscreen transitions often change the window reference)

---

### 4.2 Display Geometry

* Use `NSScreen.screens[index].visibleFrame`
* Compute tile rects from visibleFrame

---

### 4.3 Stream Orchestration

When launching a stream:

1. Load project + stream config
2. Ensure apps are running (launch if needed)
3. Ensure required windows exist
4. Normalize windows:

   * exit fullscreen
   * unminimize (best effort)
5. Apply layout
6. Chrome: ensure tabs exist
7. Editor: open repo + dynamic files
8. Terminals: open windows, run optional commands

Retries required for:

* app launch
* window discovery
* fullscreen transitions

---

## 5. Repo Structure

Swift Package with modules:

* **winmove**

  * window discovery + positioning (AX)
* **appctl**

  * app-specific logic (editor, chrome, terminal)
* **streamctl**

  * orchestration layer
* **gui**

  * stream/project UI

---

## 6. Storage

* Local SQLite (state)

---

## 7. Editor Behavior (Dynamic Files)

### Requirements

* Open repo root
* Optionally open up to **3 relevant files**

### Exact MVP heuristic

On stream launch:

1. Git root = `project.repo_root`
2. Collect candidates:

   * `git diff --name-only`
   * `git diff --name-only --cached`
3. If non-empty:

   * open up to 3 existing files
4. Else:

   * `git ls-files`
   * stat mtime
   * open 3 most recently modified tracked files
   * exclude binary/large extensions (`.png`, `.jpg`, `.zip`, etc.)

### Editor commands

* Windsurf: `surf .`
* VS Code: `code -r .`
* Cursor: `cursor -r .`

Open files:

* Windsurf: `surf <file>` (best effort)
* VS Code / Cursor: `<editor> -r <file>` or `--goto`

---

## 8. Chrome Behavior

### Requirements

* Exactly **one Chrome window per stream**
* Ensure configured URLs exist as tabs

### Stream identification (MVP)

* First URL = **anchor URL**
* A Chrome window belongs to the stream if any tab matches anchor URL

Algorithm:

1. Enumerate Chrome windows/tabs via AppleScript
2. If window with anchor exists:

   * reuse it
   * add missing tabs
3. Else:

   * create new window with all URLs

---

## 9. Terminal Behavior

### Requirements

For each terminal config entry:

* open a new Terminal window
* `cd` to worktree
* run optional command

### MVP Implementation

* Use AppleScript
* After opening:

  * bring Terminal frontmost
  * immediately move focused window via `winmove`
* Accept some brittleness; use retries + sleeps

---

## 10. Window Positioning Rules (Hard)

For **every** window before setting frame:

1. `AXFullScreen = false`
2. wait `postFullscreenDelayMs` (250–600ms)
3. re-fetch focused window
4. `AXMinimized = false` (if supported)
5. set `AXPosition`
6. set `AXSize`

Failure handling:

* log warning
* continue other windows
* abort only if editor window cannot be created

---

## 11. Errors & Diagnostics

### User-facing errors (required)

* Missing Accessibility permission

  * exact steps + binaries listed
* Invalid display index

  * show detected screen count
* App launch failure

  * bundle id + launch command
* Window not found after retries

  * suggest `winmove --list --bundle <id>`

### Logging

* Console logs only
* Prefix with stream name

---

## 12. Test Plan

### Window Control

* Move Windsurf window (normal + fullscreen)
* Move Chrome window
* Move Terminal window
* Multi-monitor placement via display index

### Integration

Create streams `a`, `b`, `c` with localhost tabs.

`streamctl up project:a` must:

* tile editor, chrome, terminal correctly
* not duplicate Chrome windows on re-run
* allow independent recall per stream

---

## 13. Constraints

* Local-only
* No cloud services

