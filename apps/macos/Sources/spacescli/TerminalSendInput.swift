import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

/// The one send path behind `spaces terminal send` and `spaces_terminal_send`: sends to this machine's
/// daemon, or to `device` when one is named.
func sendTerminalInput(_ input: TerminalProfileInput, sessionID: String, appendNewline: Bool, device: SpacesPairedDeviceRecord?) throws
    -> TerminalServiceProfileCommandResponse
{
    guard let device else {
        return try TerminalService.sendProfileCommand(
            .terminalSend(.init(sessionID: sessionID, input: input, appendNewline: appendNewline)), timeout: 5)
    }
    let text: String?
    let bytes: Data?
    switch input {
    case .text(let value): (text, bytes) = (value, nil)
    case .bytes(let value): (text, bytes) = (nil, value)
    }
    let response = try SpacesDeviceClient.sendTerminalInput(
        sessionID: sessionID, text: text, bytes: bytes, appendNewline: appendNewline,
        context: DeviceRequestContext(device: device, clientApp: cliDeviceClientApp()))
    return TerminalServiceProfileCommandResponse(message: response.message)
}
