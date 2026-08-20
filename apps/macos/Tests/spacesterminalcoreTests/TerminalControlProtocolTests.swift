import Dispatch
import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalControlProtocolTests: XCTestCase {
    func testRequestAndResponseRoundTripThroughCodec() throws {
        let client = TerminalClient(
            id: "client-1", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"),
            connectedAt: "2026-05-15T00:00:00Z")
        let request = TerminalControlRequest(
            command: "attach", authToken: "SECRET", text: "hello", bytes: Data([0, 10, 255]), clientID: "client-1", client: client,
            attachmentMode: .viewer, lineCount: 20, columns: 80, rows: 24, ownerEpoch: 7, resizeSerial: 3, scrollHorizontal: 1.5,
            scrollVertical: -2.5, scrollMods: 7, scrollPointerX: 0.25, scrollPointerY: 0.75, scrollPointerMods: 9, appendNewline: true, asPaste: true,
            appearance: .light)
        let response = TerminalControlResponse(ok: true, message: "ok")

        let decoded = try TerminalControlCodec.decodeRequest(TerminalControlCodec.encodeRequest(request))
        XCTAssertEqual(decoded, request)
        // The attaching client's appearance must survive the wire so a remote daemon can pick the
        // matching theme variant.
        XCTAssertEqual(decoded.appearance, .light)
        XCTAssertEqual(try TerminalControlCodec.decodeResponse(TerminalControlCodec.encodeResponse(response)), response)
    }

    func testSendPasteIntentRoundTripsThroughTypedWrapper() throws {
        let request = TerminalControlRequest(
            command: .send(
                TerminalControlSendPayload(
                    text: "line one\nline two", bytes: nil, clientID: "client-1", ownerEpoch: 7, appendNewline: false, asPaste: true)))

        let decoded = try TerminalControlCodec.decodeRequest(TerminalControlCodec.encodeRequest(request))

        XCTAssertTrue(decoded.asPaste)
        guard case .send(let payload) = decoded.commandValue else { return XCTFail("Expected send command, got '\(decoded.commandValue.name)'.") }
        XCTAssertTrue(payload.asPaste)
        XCTAssertEqual(payload.text, "line one\nline two")
    }

    func testAttachRequestWithoutAppearanceDecodesToNil() throws {
        let payload = #"{"command":"attach","clientID":"remote-client","asPaste":false}"#.data(using: .utf8)!
        XCTAssertNil(try TerminalControlCodec.decodeRequest(payload).appearance)
    }

    func testRequestDecodeDefaultsMissingOptionalFields() throws {
        let payload = #"{"command":"takeover","clientID":"remote-client"}"#.data(using: .utf8)!

        let request = try TerminalControlCodec.decodeRequest(payload)

        XCTAssertEqual(request, TerminalControlRequest(command: "takeover", clientID: "remote-client", appendNewline: false))
        XCTAssertFalse(request.appendNewline)
        XCTAssertFalse(request.asPaste)
    }

    func testLegacyScrollRequestDecodesWithoutScrollMods() throws {
        let payload = #"{"command":"scroll","clientID":"remote-client","scrollHorizontal":1.5,"scrollVertical":-2.5,"asPaste":false}"#.data(
            using: .utf8)!
        let request = try TerminalControlCodec.decodeRequest(payload)

        XCTAssertEqual(request.scrollHorizontal, 1.5)
        XCTAssertEqual(request.scrollVertical, -2.5)
        XCTAssertNil(request.scrollMods)
        XCTAssertNil(request.scrollPointerX)
        XCTAssertNil(request.scrollPointerY)
        XCTAssertNil(request.scrollPointerMods)
    }

    func testTypedCommandWrapperPreservesWireShape() throws {
        let request = TerminalControlRequest(
            command: .resize(TerminalControlResizePayload(clientID: "client-1", columns: 100, rows: 30, ownerEpoch: 4, resizeSerial: 8)))

        let decoded = try TerminalControlCodec.decodeRequest(TerminalControlCodec.encodeRequest(request))

        XCTAssertEqual(decoded.command, "resize")
        XCTAssertEqual(decoded.commandValue.name, "resize")
        XCTAssertEqual(decoded.commandValue.requiresOwnerClientID, true)
        XCTAssertEqual(decoded.columns, 100)
        XCTAssertEqual(decoded.rows, 30)
        XCTAssertEqual(decoded.ownerEpoch, 4)
        XCTAssertEqual(decoded.resizeSerial, 8)
    }

    func testMouseButtonRequestRoundTripsThroughCodec() throws {
        let request = TerminalControlRequest(
            command: .mouseButton(
                TerminalControlMouseButtonPayload(
                    clientID: "owner-1", ownerEpoch: 11, button: 1, pressed: true, pointerX: 0.25, pointerY: 0.75, pointerMods: 3)))

        let decoded = try TerminalControlCodec.decodeRequest(TerminalControlCodec.encodeRequest(request))

        XCTAssertEqual(decoded.command, "mouseButton")
        XCTAssertEqual(decoded.commandValue.name, "mouseButton")
        // A click mutates the session's terminal, so it is owner-gated exactly like a keystroke.
        XCTAssertTrue(decoded.commandValue.requiresOwnerClientID)
        XCTAssertTrue(TerminalControlCommand.isMobileTerminalControlName("mouseButton"))
        guard case .mouseButton(let payload) = decoded.commandValue else {
            return XCTFail("Expected a mouseButton command, got '\(decoded.commandValue.name)'.")
        }
        XCTAssertEqual(payload.clientID, "owner-1")
        XCTAssertEqual(payload.ownerEpoch, 11)
        XCTAssertEqual(payload.button, 1)
        XCTAssertEqual(payload.pressed, true)
        XCTAssertEqual(payload.pointerX, 0.25)
        XCTAssertEqual(payload.pointerY, 0.75)
        XCTAssertEqual(payload.pointerMods, 3)
    }

    func testMouseButtonWithoutButtonOrPointerReportsMissingPayload() throws {
        let noButton = try TerminalControlCodec.decodeRequest(#"{"command":"mouseButton","clientID":"owner-1","asPaste":false}"#.data(using: .utf8)!)
        XCTAssertEqual(noButton.commandValue.requiredPayloadFailureMessage, "Missing mouse button.")

        let noPointer = try TerminalControlCodec.decodeRequest(
            #"{"command":"mouseButton","clientID":"owner-1","mouseButton":1,"mousePressed":true,"asPaste":false}"#.data(using: .utf8)!)
        XCTAssertEqual(noPointer.commandValue.requiredPayloadFailureMessage, "Missing mouse pointer position.")
    }

    func testSetAppearanceRequestRoundTripsThroughCodec() throws {
        let request = TerminalControlRequest(command: .setAppearance(TerminalControlSetAppearancePayload(clientID: "viewer-1", appearance: .dark)))

        let decoded = try TerminalControlCodec.decodeRequest(TerminalControlCodec.encodeRequest(request))

        XCTAssertEqual(decoded.command, "setAppearance")
        XCTAssertEqual(decoded.commandValue.name, "setAppearance")
        // Appearance is a per-client view preference, so it must not be owner-gated on the wire.
        XCTAssertEqual(decoded.commandValue.requiresOwnerClientID, false)
        XCTAssertEqual(decoded.clientID, "viewer-1")
        XCTAssertEqual(decoded.appearance, .dark)
        guard case .setAppearance(let payload) = decoded.commandValue else {
            return XCTFail("Expected a setAppearance command, got '\(decoded.commandValue.name)'.")
        }
        XCTAssertEqual(payload.clientID, "viewer-1")
        XCTAssertEqual(payload.appearance, .dark)
    }

    func testSetAppearanceWithoutAppearanceReportsMissingPayload() throws {
        let request = try TerminalControlCodec.decodeRequest(
            #"{"command":"setAppearance","clientID":"viewer-1","asPaste":false}"#.data(using: .utf8)!)
        XCTAssertEqual(request.commandValue.requiredPayloadFailureMessage, "Missing appearance.")
    }

    func testSetSelectionRequestRoundTripsThroughCodec() throws {
        let request = TerminalControlRequest(
            command: .setSelection(
                TerminalControlSetSelectionPayload(clientID: "viewer-1", startColumn: 4, startRow: 100, endColumn: 20, endRow: 102, rectangle: true))
        )

        let decoded = try TerminalControlCodec.decodeRequest(TerminalControlCodec.encodeRequest(request))

        XCTAssertEqual(decoded.command, "setSelection")
        XCTAssertEqual(decoded.commandValue.name, "setSelection")
        // Selection is deliberately shared state: any attached viewer may set or clear it, unlike
        // scroll/mouse input which are exclusive to whoever currently owns the session.
        XCTAssertEqual(decoded.commandValue.requiresOwnerClientID, false)
        XCTAssertEqual(decoded.selectionStartColumn, 4)
        XCTAssertEqual(decoded.selectionStartRow, 100)
        XCTAssertEqual(decoded.selectionEndColumn, 20)
        XCTAssertEqual(decoded.selectionEndRow, 102)
        XCTAssertEqual(decoded.selectionRectangle, true)
        guard case .setSelection(let payload) = decoded.commandValue else {
            return XCTFail("Expected a setSelection command, got '\(decoded.commandValue.name)'.")
        }
        XCTAssertEqual(payload.clientID, "viewer-1")
        XCTAssertEqual(payload.startColumn, 4)
        XCTAssertEqual(payload.startRow, 100)
        XCTAssertEqual(payload.endColumn, 20)
        XCTAssertEqual(payload.endRow, 102)
        XCTAssertEqual(payload.rectangle, true)
    }

    func testSetSelectionWithoutEndpointsReportsMissingPayload() throws {
        let request = try TerminalControlCodec.decodeRequest(
            #"{"command":"setSelection","clientID":"viewer-1","asPaste":false}"#.data(using: .utf8)!)
        XCTAssertEqual(request.commandValue.requiredPayloadFailureMessage, "Missing selection endpoints.")
    }

    func testClearSelectionAndReadSelectionTextRoundTripThroughCodec() throws {
        for command: TerminalControlCommand in [.clearSelection(.init(clientID: "viewer-1")), .readSelectionText(.init(clientID: "viewer-1"))] {
            let decoded = try TerminalControlCodec.decodeRequest(TerminalControlCodec.encodeRequest(TerminalControlRequest(command: command)))
            XCTAssertEqual(decoded.command, command.name)
            XCTAssertEqual(decoded.commandValue.requiresOwnerClientID, false)
            XCTAssertNil(decoded.commandValue.requiredPayloadFailureMessage, "\(command.name) carries no required payload of its own")
            XCTAssertEqual(decoded.clientID, "viewer-1")
        }
    }

    /// `selectionText` is the one response field `setSelection`/`readSelectionText` add to the wire; it
    /// must round-trip both present (a non-empty selection) and absent (no selection to report).
    func testSelectionTextResponseFieldRoundTripsThroughCodec() throws {
        let withText = TerminalControlResponse(ok: true, message: "Read terminal selection.", selectionText: "hello world")
        let withoutText = TerminalControlResponse(ok: true, message: "Read terminal selection.")

        XCTAssertEqual(try TerminalControlCodec.decodeResponse(TerminalControlCodec.encodeResponse(withText)), withText)
        XCTAssertEqual(try TerminalControlCodec.decodeResponse(TerminalControlCodec.encodeResponse(withText)).selectionText, "hello world")
        XCTAssertNil(try TerminalControlCodec.decodeResponse(TerminalControlCodec.encodeResponse(withoutText)).selectionText)
    }

    func testTypedCommandWrapperReportsMissingPayloadFields() throws {
        let send = try TerminalControlCodec.decodeRequest(#"{"command":"send","clientID":"client-1","asPaste":false}"#.data(using: .utf8)!)
        let attach = try TerminalControlCodec.decodeRequest(#"{"command":"attach","clientID":"legacy-extra","asPaste":false}"#.data(using: .utf8)!)
        let resize = try TerminalControlCodec.decodeRequest(
            #"{"command":"resize","clientID":"client-1","columns":100,"asPaste":false}"#.data(using: .utf8)!)

        XCTAssertEqual(send.commandValue.requiredPayloadFailureMessage, "Missing input payload.")
        XCTAssertEqual(attach.commandValue.requiredPayloadFailureMessage, "Missing client payload.")
        XCTAssertEqual(resize.commandValue.requiredPayloadFailureMessage, "Missing terminal size.")
        XCTAssertEqual(attach.clientID, "legacy-extra")
    }

    func testClientCanSendRequestToSessionSocket() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = root.appendingPathComponent("control.sock").path
        let queue = DispatchQueue(label: "terminal-control-protocol-test")
        let received = expectation(description: "received request")

        let server = TerminalControlServer(socketPath: socketPath, queue: queue) { request in
            XCTAssertEqual(request, TerminalControlRequest(command: "send", text: "payload", appendNewline: true))
            received.fulfill()
            return TerminalControlResponse(ok: true, message: "ack")
        }
        try server.start()
        defer { server.stop() }

        let response = try TerminalControlClient.send(
            request: TerminalControlRequest(command: "send", text: "payload", appendNewline: true), socketPath: socketPath)

        wait(for: [received], timeout: 2)
        XCTAssertEqual(response, TerminalControlResponse(ok: true, message: "ack"))
    }

    /// Every control that changes who is attached answers with the resulting session state, so a client
    /// never has to follow one with a separate `.state` request to see the new ownership. Both daemons read
    /// this one property to decide what to load, so it is the whole contract.
    func testAttachmentChangingControlsCarrySessionState() {
        for command in [
            TerminalControlCommand.attach(.init(client: nil, attachmentMode: .owner, appearance: nil)), .detach(.init(clientID: "client-1")),
            .takeover(.init(clientID: "client-1")),
        ] { XCTAssertTrue(command.includesSessionStateOnSuccess, "\(command.name) changes attachments and must echo session state") }
        for command in [
            TerminalControlCommand.send(.init(text: "ls", bytes: nil, clientID: "client-1", ownerEpoch: nil, appendNewline: true, asPaste: false)),
            .key(.init(key: "enter", clientID: "client-1", ownerEpoch: nil)),
            .resize(.init(clientID: "client-1", columns: 80, rows: 24, ownerEpoch: nil, resizeSerial: nil)), .heartbeat(.init(clientID: "client-1")),
            .setAppearance(.init(clientID: "client-1", appearance: .dark)),
        ] {
            XCTAssertFalse(
                command.includesSessionStateOnSuccess, "\(command.name) changes no attachment; its effect reaches clients on the next broadcast")
        }
    }
}
