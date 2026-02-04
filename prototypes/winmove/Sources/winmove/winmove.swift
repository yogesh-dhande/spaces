import Foundation
import AppKit
import ApplicationServices

// MARK: - Accessibility trust check (no prompt; avoids Swift 6 concurrency issue)
if !AXIsProcessTrusted() {
    fputs("""
Accessibility permission not granted.

Enable BOTH:
  System Settings → Privacy & Security → Accessibility → Terminal (or your shell)
  System Settings → Privacy & Security → Accessibility → winmove (the built binary)

Then re-run.

""", stderr)
    exit(3)
}

// MARK: - Models

enum Tile: String {
    case leftHalf, rightHalf
    case topLeft, topRight, bottomLeft, bottomRight
}

struct Args {
    var appName: String?
    var bundleId: String?
    var frontmost = false           // choose focused window if possible; else first window
    var match: String?
    var displayIndex: Int?
    var tile: Tile?

    var listOnly = false
    var frontmostApp = false        // ignore appName/bundleId; target current frontmost app

    var retries: Int = 25
    var delayMs: Int = 80

    // NEW: always try to exit fullscreen before moving
    var forceExitFullscreen: Bool = true

    // how long to wait after toggling fullscreen (ms)
    var postFullscreenDelayMs: Int = 250
}

func usage() -> Never {
    fputs("""
Usage:
  winmove [--bundle <id> | --app <name> | --frontmost-app]
          [--frontmost | --match <substring>]
          --display <index> --tile <tile>
          [--retries <n>] [--delay-ms <n>]
          [--no-exit-fullscreen]
          [--post-fullscreen-delay-ms <n>]

  winmove [--bundle <id> | --app <name> | --frontmost-app] --list

Examples:
  winmove --bundle com.exafunction.windsurf --frontmost --display 0 --tile leftHalf
  winmove --bundle com.google.Chrome --frontmost --display 0 --tile rightHalf
  winmove --frontmost-app --display 1 --tile topRight
  winmove --bundle com.exafunction.windsurf --list

Tiles:
  leftHalf, rightHalf, topLeft, topRight, bottomLeft, bottomRight

Notes:
  - Window targeting prefers the app's focused window (best for Electron apps like Windsurf).
  - By default, winmove attempts to exit fullscreen before moving.

""", stderr)
    exit(2)
}

// MARK: - Arg parsing

func parseArgs() -> Args {
    var a = Args()
    var i = 1
    let argv = CommandLine.arguments

    while i < argv.count {
        let k = argv[i]
        switch k {
        case "--app":
            i += 1; if i >= argv.count { usage() }
            a.appName = argv[i]

        case "--bundle":
            i += 1; if i >= argv.count { usage() }
            a.bundleId = argv[i]

        case "--frontmost-app":
            a.frontmostApp = true

        case "--frontmost":
            a.frontmost = true

        case "--match":
            i += 1; if i >= argv.count { usage() }
            a.match = argv[i]

        case "--display":
            i += 1; if i >= argv.count { usage() }
            a.displayIndex = Int(argv[i])

        case "--tile":
            i += 1; if i >= argv.count { usage() }
            a.tile = Tile(rawValue: argv[i])

        case "--list":
            a.listOnly = true

        case "--retries":
            i += 1; if i >= argv.count { usage() }
            a.retries = Int(argv[i]) ?? a.retries

        case "--delay-ms":
            i += 1; if i >= argv.count { usage() }
            a.delayMs = Int(argv[i]) ?? a.delayMs

        case "--no-exit-fullscreen":
            a.forceExitFullscreen = false

        case "--post-fullscreen-delay-ms":
            i += 1; if i >= argv.count { usage() }
            a.postFullscreenDelayMs = Int(argv[i]) ?? a.postFullscreenDelayMs

        default:
            usage()
        }
        i += 1
    }

    if a.listOnly {
        if !(a.frontmostApp || a.bundleId != nil || a.appName != nil) { usage() }
        return a
    }

    guard a.displayIndex != nil, a.tile != nil else { usage() }
    if !(a.frontmostApp || a.bundleId != nil || a.appName != nil) { usage() }
    if !a.frontmost && a.match == nil { usage() }

    return a
}

// MARK: - AX Helpers

func axValue(_ point: CGPoint) -> AXValue {
    var p = point
    return AXValueCreate(.cgPoint, &p)!
}

func axValue(_ size: CGSize) -> AXValue {
    var s = size
    return AXValueCreate(.cgSize, &s)!
}

func windowTitle(_ win: AXUIElement) -> String {
    var value: AnyObject?
    if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &value) == .success {
        return value as? String ?? ""
    }
    return ""
}

func isFullscreen(_ win: AXUIElement) -> Bool {
    // Some SDKs don't expose kAXFullScreenAttribute symbol; use raw attribute string.
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &value)
    if err == .success, let b = value as? Bool {
        return b
    }
    return false
}

func setFullscreen(_ win: AXUIElement, _ enabled: Bool) -> AXError {
    // Set "AXFullScreen" attribute to true/false.
    let value: CFBoolean = enabled ? kCFBooleanTrue : kCFBooleanFalse
    return AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, value)
}

func getWindows(for app: NSRunningApplication) -> [AXUIElement] {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
    if err != .success { return [] }
    return value as? [AXUIElement] ?? []
}

func focusedWindow(for app: NSRunningApplication) -> AXUIElement? {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value)
    if err == .success, let v = value {
        return (v as! AXUIElement)
    }
    return nil
}

// MARK: - App selection

func findRunningApp(appName: String?, bundleId: String?) -> NSRunningApplication? {
    let apps = NSWorkspace.shared.runningApplications
    if let bid = bundleId {
        return apps.first(where: { $0.bundleIdentifier == bid })
    }
    if let name = appName {
        return apps.first(where: { ($0.localizedName ?? "").localizedCaseInsensitiveContains(name) })
    }
    return nil
}

func currentFrontmostApp() -> NSRunningApplication? {
    return NSWorkspace.shared.frontmostApplication
}

// MARK: - Display + tiling

func displayFrame(index: Int) -> CGRect? {
    let screens = NSScreen.screens
    guard index >= 0 && index < screens.count else { return nil }
    return screens[index].visibleFrame
}

func tileRect(in frame: CGRect, tile: Tile) -> CGRect {
    let x = frame.origin.x
    let y = frame.origin.y
    let w = frame.size.width
    let h = frame.size.height

    switch tile {
    case .leftHalf:
        return CGRect(x: x, y: y, width: w/2, height: h)
    case .rightHalf:
        return CGRect(x: x + w/2, y: y, width: w/2, height: h)
    case .topLeft:
        return CGRect(x: x, y: y + h/2, width: w/2, height: h/2)
    case .topRight:
        return CGRect(x: x + w/2, y: y + h/2, width: w/2, height: h/2)
    case .bottomLeft:
        return CGRect(x: x, y: y, width: w/2, height: h/2)
    case .bottomRight:
        return CGRect(x: x + w/2, y: y, width: w/2, height: h/2)
    }
}

func setWindowFrame(_ win: AXUIElement, rect: CGRect) -> Bool {
    let p = axValue(CGPoint(x: rect.origin.x, y: rect.origin.y))
    let s = axValue(CGSize(width: rect.size.width, height: rect.size.height))

    let e1 = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p)
    let e2 = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s)

    if e1 != .success || e2 != .success {
        fputs("AX set failed: position=\(e1.rawValue) size=\(e2.rawValue)\n", stderr)
        return false
    }
    return true
}

// MARK: - Retry helper

func withRetry<T>(retries: Int, delayMs: Int, _ f: () -> T?) -> T? {
    for _ in 0..<retries {
        if let v = f() { return v }
        usleep(useconds_t(delayMs * 1000))
    }
    return nil
}

// MARK: - Window chooser

func chooseWindow(args: Args) -> (NSRunningApplication, AXUIElement)? {
    let app: NSRunningApplication?

    if args.frontmostApp {
        app = currentFrontmostApp()
    } else {
        app = findRunningApp(appName: args.appName, bundleId: args.bundleId)
    }

    guard let targetApp = app else {
        fputs("Error: target app not running / not frontmost.\n", stderr)
        return nil
    }

    // 1) Prefer focused window (best for Electron apps like Windsurf)
    if let fw = focusedWindow(for: targetApp) {
        if args.frontmost { return (targetApp, fw) }
        if let m = args.match?.lowercased(), windowTitle(fw).lowercased().contains(m) {
            return (targetApp, fw)
        }
    }

    // 2) Fallback to list of windows
    let wins = getWindows(for: targetApp)
    if wins.isEmpty { return nil }

    if args.frontmost { return (targetApp, wins[0]) }

    if let m = args.match?.lowercased() {
        if let w = wins.first(where: { windowTitle($0).lowercased().contains(m) }) {
            return (targetApp, w)
        }
    }

    return (targetApp, wins[0])
}

// MARK: - List mode

func listWindows(args: Args) -> Int {
    let targetApp: NSRunningApplication?

    if args.frontmostApp {
        targetApp = currentFrontmostApp()
    } else {
        targetApp = findRunningApp(appName: args.appName, bundleId: args.bundleId)
    }

    guard let app = targetApp else {
        fputs("Error: app not running / not frontmost.\n", stderr)
        return 1
    }

    print("App:")
    print("  name: \(app.localizedName ?? "<unknown>")")
    print("  pid: \(app.processIdentifier)")
    print("  bundleId: \(app.bundleIdentifier ?? "<none>")")

    if let fw = focusedWindow(for: app) {
        print("Focused window:")
        print("  title: \(windowTitle(fw))")
        print("  fullscreen: \(isFullscreen(fw))")
    } else {
        print("Focused window: <none>")
    }

    let wins = getWindows(for: app)
    print("Windows: \(wins.count)")
    for (i, w) in wins.enumerated() {
        print("  [\(i)] title=\(windowTitle(w)) fullscreen=\(isFullscreen(w))")
    }

    return 0
}

// MARK: - Fullscreen handling (best-effort)

func ensureNotFullscreen(app: NSRunningApplication,
                        args: Args,
                        initialWin: AXUIElement) -> AXUIElement {
    if !args.forceExitFullscreen {
        return initialWin
    }

    if !isFullscreen(initialWin) {
        return initialWin
    }

    // Attempt to exit fullscreen
    let err = setFullscreen(initialWin, false)
    if err != .success {
        fputs("Warning: failed to exit fullscreen (AX error \(err.rawValue)). Will continue and attempt move anyway.\n", stderr)
        return initialWin
    }

    // Give macOS time to animate out of fullscreen.
    usleep(useconds_t(args.postFullscreenDelayMs * 1000))

    // After exiting fullscreen, the focused window object can change. Re-fetch.
    if let fw = focusedWindow(for: app) {
        return fw
    }

    // Fallback: return the original element.
    return initialWin
}

// MARK: - Main (top-level)

let args = parseArgs()

if args.listOnly {
    exit(Int32(listWindows(args: args)))
}

guard let frame = displayFrame(index: args.displayIndex!) else {
    fputs("Error: invalid display index. screens=\(NSScreen.screens.count)\n", stderr)
    exit(1)
}

let rect = tileRect(in: frame, tile: args.tile!)

guard let (app, foundWin) = withRetry(retries: args.retries, delayMs: args.delayMs, {
    chooseWindow(args: args)
}) else {
    fputs("Error: failed to find window after retries. Try --list.\n", stderr)
    exit(1)
}

// Always attempt to exit fullscreen (best-effort) before moving
let win = ensureNotFullscreen(app: app, args: args, initialWin: foundWin)

// Move/resize (with retries)
let ok = withRetry(retries: args.retries, delayMs: args.delayMs, {
    setWindowFrame(win, rect: rect) ? true : nil
}) ?? false

if !ok {
    fputs("Error: failed to set window frame after retries.\n", stderr)
    exit(1)
}

let appLabel = app.bundleIdentifier ?? (app.localizedName ?? "<app>")
print("OK moved \(appLabel) to \(args.tile!.rawValue) on display \(args.displayIndex!)")
