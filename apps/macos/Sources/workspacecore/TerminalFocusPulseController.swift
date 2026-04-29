import AppKit
import Foundation
import systembridge

public protocol TerminalFocusPulseControlling: Sendable { func pulse(windowID: Int, color: (r: Int, g: Int, b: Int), yabai: YabaiAdapter) }

public final class TerminalFocusPulseController: @unchecked Sendable, TerminalFocusPulseControlling {
    private final class OverlayStore { var overlaysByWindowID: [Int: NSWindow] = [:] }

    private let lock = NSLock()
    private var tokenByWindowID: [Int: UUID] = [:]
    private let pulseDuration: Duration
    private let overlayStore = OverlayStore()

    public init(pulseDuration: Duration = .milliseconds(300)) { self.pulseDuration = pulseDuration }

    public func pulse(windowID: Int, color: (r: Int, g: Int, b: Int), yabai: YabaiAdapter) {
        let token = UUID()
        setToken(token, for: windowID)
        let resolvedWindow = try? yabai.window(id: windowID)
        guard let window = resolvedWindow ?? nil, let frame = window.frame else {
            clearToken(windowID: windowID, token: token)
            return
        }
        let displays = try? yabai.listDisplays()
        guard let display = displays?.first(where: { $0.index == window.display }), let displayFrame = display.frame else {
            clearToken(windowID: windowID, token: token)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let overlayFrame = await MainActor.run { self.overlayFrame(windowFrame: frame, displayFrame: displayFrame, displayID: display.id) }
            guard let overlayFrame else {
                self.clearToken(windowID: windowID, token: token)
                return
            }

            await MainActor.run { self.presentOverlay(windowID: windowID, frame: overlayFrame, color: color) }

            try? await Task.sleep(for: self.pulseDuration)
            await MainActor.run { self.finishPulse(windowID: windowID, token: token) }
        }
    }

    private func setToken(_ token: UUID, for windowID: Int) {
        lock.lock()
        tokenByWindowID[windowID] = token
        lock.unlock()
    }

    private func clearToken(windowID: Int, token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard tokenByWindowID[windowID] == token else { return }
        tokenByWindowID.removeValue(forKey: windowID)
    }

    private func currentToken(windowID: Int) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return tokenByWindowID[windowID]
    }

    @MainActor private func overlayFrame(windowFrame: YabaiFrame, displayFrame: YabaiFrame, displayID: Int?) -> NSRect? {
        guard let screen = screen(for: displayID) else { return nil }
        let xOffset = CGFloat(windowFrame.x - displayFrame.x)
        let yOffsetFromTop = CGFloat(windowFrame.y - displayFrame.y)
        let width = CGFloat(windowFrame.w)
        let height = CGFloat(windowFrame.h)
        let x = screen.frame.minX + xOffset
        let y = screen.frame.minY + screen.frame.height - yOffsetFromTop - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    @MainActor private func screen(for displayID: Int?) -> NSScreen? {
        if let displayID {
            let matched = NSScreen.screens.first {
                (($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue) == displayID
            }
            if let matched { return matched }
        }
        return NSScreen.screens.first
    }

    @MainActor private func presentOverlay(windowID: Int, frame: NSRect, color: (r: Int, g: Int, b: Int)) {
        let overlay: NSWindow
        if let existing = overlayStore.overlaysByWindowID[windowID] {
            overlay = existing
            overlay.setFrame(frame, display: true)
        } else {
            overlay = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.hasShadow = false
            overlay.ignoresMouseEvents = true
            overlay.level = .statusBar
            overlay.collectionBehavior = [.transient, .ignoresCycle]
            overlay.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
            overlay.contentView?.wantsLayer = true
            overlay.contentView?.layer?.cornerRadius = UIRadius.regular
            overlayStore.overlaysByWindowID[windowID] = overlay
        }

        overlay.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        overlay.contentView?.layer?.backgroundColor =
            NSColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 0.35).cgColor
        overlay.orderFrontRegardless()
    }

    @MainActor private func finishPulse(windowID: Int, token: UUID) {
        guard currentToken(windowID: windowID) == token else { return }
        clearToken(windowID: windowID, token: token)
        guard let overlay = overlayStore.overlaysByWindowID.removeValue(forKey: windowID) else { return }
        overlay.orderOut(nil)
    }
}
