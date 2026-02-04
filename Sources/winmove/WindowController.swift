import AppKit
import ApplicationServices
import Foundation

public final class WindowController {
    public init() {}

    public func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    public func ensureAccessibilityPermission() throws {
        guard hasAccessibilityPermission() else {
            throw WinmoveError.accessibilityPermissionMissing
        }
    }

    public func listWindows(bundleID: String) throws -> WindowList {
        try ensureAccessibilityPermission()
        guard let app = runningApp(bundleID: bundleID) else {
            throw WinmoveError.appNotRunning(bundleID: bundleID)
        }

        let focused = focusedWindow(for: app).map(windowInfo)
        let windows = getWindows(for: app).map(windowInfo)

        return WindowList(
            bundleID: bundleID,
            appName: app.localizedName ?? "<unknown>",
            windows: windows,
            focusedWindow: focused
        )
    }

    @discardableResult
    public func moveWindow(
        target: WindowTarget,
        layout: WindowLayout,
        options: MoveOptions = .init()
    ) throws -> WindowInfo {
        try ensureAccessibilityPermission()

        guard let app = withRetry(retries: options.retries, delayMs: options.delayMs, {
            self.runningApp(bundleID: target.bundleID)
        }) else {
            throw WinmoveError.appNotRunning(bundleID: target.bundleID)
        }

        let frame = try displayFrame(index: layout.displayIndex)
        let rect = tileRect(in: frame, tile: layout.tile)

        guard let foundWindow = withRetry(retries: options.retries, delayMs: options.delayMs, {
            self.chooseWindow(app: app, target: target)
        }) else {
            throw WinmoveError.windowNotFound(bundleID: target.bundleID)
        }

        let normalizedWindow = normalizeWindow(
            app: app,
            window: foundWindow,
            options: options
        )

        let moved = withRetry(retries: options.retries, delayMs: options.delayMs, {
            self.setWindowFrame(normalizedWindow, rect: rect) ? true : nil
        }) ?? false

        guard moved else {
            throw WinmoveError.moveFailed(bundleID: target.bundleID)
        }

        return windowInfo(normalizedWindow)
    }

    @discardableResult
    public func setMinimized(
        target: WindowTarget,
        minimized: Bool,
        options: MoveOptions = .init()
    ) throws -> WindowInfo {
        try ensureAccessibilityPermission()

        guard let app = withRetry(retries: options.retries, delayMs: options.delayMs, {
            self.runningApp(bundleID: target.bundleID)
        }) else {
            throw WinmoveError.appNotRunning(bundleID: target.bundleID)
        }

        guard let foundWindow = withRetry(retries: options.retries, delayMs: options.delayMs, {
            self.chooseWindow(app: app, target: target)
        }) else {
            throw WinmoveError.windowNotFound(bundleID: target.bundleID)
        }

        let ok = setMinimized(foundWindow, minimized) == .success
        guard ok else {
            throw WinmoveError.moveFailed(bundleID: target.bundleID)
        }
        return windowInfo(foundWindow)
    }

    private func runningApp(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }

    private func chooseWindow(app: NSRunningApplication, target: WindowTarget) -> AXUIElement? {
        if target.preferFocusedWindow, let focused = focusedWindow(for: app) {
            if let match = target.matchTitle?.lowercased(), !windowTitle(focused).lowercased().contains(match) {
                // Continue to fallback window list.
            } else {
                return focused
            }
        }

        let windows = getWindows(for: app)
        if windows.isEmpty {
            return nil
        }

        if let match = target.matchTitle?.lowercased() {
            return windows.first { windowTitle($0).lowercased().contains(match) } ?? windows.first
        }

        return windows.first
    }

    private func displayFrame(index: Int) throws -> CGRect {
        let screens = NSScreen.screens
        guard index >= 0, index < screens.count else {
            throw WinmoveError.invalidDisplayIndex(index: index, screenCount: screens.count)
        }
        return screens[index].visibleFrame
    }

    private func tileRect(in frame: CGRect, tile: Tile) -> CGRect {
        let x = frame.origin.x
        let y = frame.origin.y
        let w = frame.size.width
        let h = frame.size.height

        switch tile {
        case .leftHalf:
            return CGRect(x: x, y: y, width: w / 2, height: h)
        case .rightHalf:
            return CGRect(x: x + w / 2, y: y, width: w / 2, height: h)
        case .topLeft:
            return CGRect(x: x, y: y + h / 2, width: w / 2, height: h / 2)
        case .topRight:
            return CGRect(x: x + w / 2, y: y + h / 2, width: w / 2, height: h / 2)
        case .bottomLeft:
            return CGRect(x: x, y: y, width: w / 2, height: h / 2)
        case .bottomRight:
            return CGRect(x: x + w / 2, y: y, width: w / 2, height: h / 2)
        }
    }

    private func windowInfo(_ window: AXUIElement) -> WindowInfo {
        WindowInfo(title: windowTitle(window), isFullscreen: isFullscreen(window))
    }

    private func normalizeWindow(app: NSRunningApplication, window: AXUIElement, options: MoveOptions) -> AXUIElement {
        var current = window

        if options.exitFullscreen, isFullscreen(current) {
            _ = setFullscreen(current, false)
            usleep(useconds_t(options.postFullscreenDelayMs * 1000))
            if let focused = focusedWindow(for: app) {
                current = focused
            }
        }

        if options.unminimize {
            _ = setMinimized(current, false)
        }

        return current
    }

    private func withRetry<T>(retries: Int, delayMs: Int, _ f: () -> T?) -> T? {
        for _ in 0..<retries {
            if let value = f() {
                return value
            }
            usleep(useconds_t(delayMs * 1000))
        }
        return nil
    }

    private func getWindows(for app: NSRunningApplication) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard error == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private func focusedWindow(for app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value)
        guard error == .success, let raw = value else {
            return nil
        }
        return (raw as! AXUIElement)
    }

    private func windowTitle(_ window: AXUIElement) -> String {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
        guard error == .success else {
            return ""
        }
        return value as? String ?? ""
    }

    private func isFullscreen(_ window: AXUIElement) -> Bool {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value)
        guard error == .success else {
            return false
        }
        return value as? Bool ?? false
    }

    private func setFullscreen(_ window: AXUIElement, _ enabled: Bool) -> AXError {
        let value: CFBoolean = enabled ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, value)
    }

    private func setMinimized(_ window: AXUIElement, _ minimized: Bool) -> AXError {
        let value: CFBoolean = minimized ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, value)
    }

    private func setWindowFrame(_ window: AXUIElement, rect: CGRect) -> Bool {
        var point = CGPoint(x: rect.origin.x, y: rect.origin.y)
        var size = CGSize(width: rect.size.width, height: rect.size.height)

        guard let positionValue = AXValueCreate(.cgPoint, &point),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return false
        }

        let e1 = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let e2 = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

        return e1 == .success && e2 == .success
    }
}
