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

    func testInsertTextCommitsComposedInputAndClearsMarkedText() {
        let view = TransportTerminalTranscriptView(frame: .zero)
        var received: [TransportTerminalTranscriptInput] = []
        view.terminalInputHandler = {
            received.append($0)
            return true
        }

        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.insertText("日", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(received, [.text("日")])
        XCTAssertFalse(view.hasMarkedText())
    }

    func testMarkedTextIsExposedForInputMethodQueries() {
        let view = TransportTerminalTranscriptView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        view.string = "prompt> "
        view.setMarkedText(
            NSAttributedString(string: "かな", attributes: [.foregroundColor: NSColor.systemBlue]), selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: "prompt> ".utf16.count, length: 2))
        XCTAssertEqual(view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 7), actualRange: nil)?.string, "prompt>")
        XCTAssertGreaterThan(view.markedTextScreenRect().width, 0)
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

    func testHandleTerminalEventMapsModifiedNavigationAndKeypadKeys() throws {
        let view = TransportTerminalTranscriptView(frame: .zero)
        var received: [TransportTerminalTranscriptInput] = []
        view.terminalInputHandler = {
            received.append($0)
            return true
        }

        let shiftUpEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_UpArrow)))
        let altF5Event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_F5)))
        let keypadClearEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_ANSI_KeypadClear)))
        let f13Event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_F13)))

        XCTAssertTrue(view.handleTerminalEvent(shiftUpEvent))
        XCTAssertTrue(view.handleTerminalEvent(altF5Event))
        XCTAssertTrue(view.handleTerminalEvent(keypadClearEvent))
        XCTAssertTrue(view.handleTerminalEvent(f13Event))
        XCTAssertEqual(received, [.key("shift+up"), .key("alt+f5"), .key("kpclear"), .key("f13")])
    }

    func testMouseHandlersMapRightMiddleAndMoveEvents() throws {
        let view = TransportTerminalTranscriptView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        view.string = "alpha\nbeta"
        view.sizeToFit()
        var received: [TransportTerminalTranscriptMouseInput] = []
        view.terminalMouseHandler = {
            received.append($0)
            return true
        }

        let rightDown = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: 40, y: 20), modifierFlags: [.shift], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        let otherDragged = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .otherMouseDragged, location: NSPoint(x: 60, y: 30), modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        let moved = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: NSPoint(x: 80, y: 40), modifierFlags: [.control], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0))

        view.rightMouseDown(with: rightDown)
        view.otherMouseDragged(with: otherDragged)
        view.mouseMoved(with: moved)

        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(received[0].action, .press)
        XCTAssertEqual(received[0].button, .right)
        XCTAssertTrue(received[0].shift)
        XCTAssertEqual(received[1].action, .move)
        XCTAssertEqual(received[1].button, .middle)
        XCTAssertTrue(received[1].option)
        XCTAssertEqual(received[2].action, .move)
        XCTAssertEqual(received[2].button, .none)
        XCTAssertTrue(received[2].control)
    }

    func testDoubleClickSelectsWordRange() throws {
        let view = TransportTerminalTranscriptView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        view.string = "alpha-beta gamma"
        view.sizeToFit()

        let doubleClick = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: view.horizontalInsets + view.measuredCellWidth * 7, y: view.verticalInsets + 2),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))

        view.mouseDown(with: doubleClick)

        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: "alpha-beta".utf16.count))
    }

    func testTripleClickSelectsRenderedLineWithoutTrailingNewline() throws {
        let view = TransportTerminalTranscriptView(frame: NSRect(x: 0, y: 0, width: 300, height: 140))
        view.string = "alpha beta\ngamma delta\n"
        view.sizeToFit()

        let tripleClick = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: view.horizontalInsets + view.measuredCellWidth * 2, y: view.verticalInsets + view.measuredLineHeight + 2),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 3, pressure: 1))

        view.mouseDown(with: tripleClick)

        let lineStart = "alpha beta\n".utf16.count
        XCTAssertEqual(view.selectedRange(), NSRange(location: lineStart, length: "gamma delta".utf16.count))
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
