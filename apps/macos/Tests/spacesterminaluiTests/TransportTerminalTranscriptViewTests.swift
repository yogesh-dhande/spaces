import AppKit
import Carbon
import XCTest

@testable import spacesterminalui

@MainActor final class TransportTerminalTranscriptViewTests: XCTestCase {
    func testHandleTerminalEventMapsPrintableText() throws {
        let view = TransportTerminalTranscriptView(frame: .zero)
        var received: TransportTerminalTranscriptInput?
        view.terminalInputHandler = {
            received = $0
            return true
        }

        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: UInt16(kVK_ANSI_A)))

        XCTAssertTrue(view.handleTerminalEvent(event))
        XCTAssertEqual(received, .text("a"))
    }

    func testHandleTerminalEventMapsNamedKeysAndControlChords() throws {
        let view = TransportTerminalTranscriptView(frame: .zero)
        var received: [TransportTerminalTranscriptInput] = []
        view.terminalInputHandler = {
            received.append($0)
            return true
        }

        let enterEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(kVK_Return)))
        let controlCEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{03}",
                charactersIgnoringModifiers: "c", isARepeat: false, keyCode: UInt16(kVK_ANSI_C)))

        XCTAssertTrue(view.handleTerminalEvent(enterEvent))
        XCTAssertTrue(view.handleTerminalEvent(controlCEvent))
        XCTAssertEqual(received, [.key("enter"), .key("ctrl+c")])
    }

    func testHandleTerminalEventLeavesCommandShortcutsToResponderChain() throws {
        let view = TransportTerminalTranscriptView(frame: .zero)
        var received: TransportTerminalTranscriptInput?
        view.terminalInputHandler = {
            received = $0
            return true
        }

        let commandVEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "v",
                charactersIgnoringModifiers: "v", isARepeat: false, keyCode: UInt16(kVK_ANSI_V)))

        XCTAssertFalse(view.handleTerminalEvent(commandVEvent))
        XCTAssertNil(received)
    }

    func testCharacterIndexRespectsLineAndColumn() {
        let view = TransportTerminalTranscriptView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = "alpha\nbeta"
        view.sizeToFit()

        let firstLineIndex = view.characterIndex(at: NSPoint(x: 0, y: 0))
        let secondLineIndex = view.characterIndex(
            at: NSPoint(x: view.horizontalInsets + view.measuredCellWidth * 2, y: view.verticalInsets + view.measuredLineHeight + 1))

        XCTAssertEqual(firstLineIndex, 0)
        XCTAssertEqual(secondLineIndex, "alpha\nbet".utf16.count)
    }
}
