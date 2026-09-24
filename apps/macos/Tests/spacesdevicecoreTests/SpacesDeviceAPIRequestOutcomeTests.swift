import Foundation
import Testing
import spacesterminalcore

@testable import spacesdevicecore

/// Pins the boundary a mutation's caller reads before it reports a failure: which failures leave it
/// unknown whether the daemon carried the request out, and which prove it never did. The Editor's entry
/// move reconciles the first group against the file listing and reports the second as a plain refusal,
/// so getting a post-send failure onto the definite side is what leaves a pane editing a path the daemon
/// has emptied.
@Suite struct SpacesDeviceAPIRequestOutcomeTests {
    @Test func failuresThatCanLandAfterTheDaemonHoldsTheRequestAreUnknown() {
        // The reply was lost with the connection that carried it: the daemon may have finished the work.
        #expect(SpacesDeviceAPIRequestOutcome.mayHaveBeenPerformed(SpacesDeviceAPIRequestClientError.emptyResponse))
        #expect(SpacesDeviceAPIRequestOutcome.mayHaveBeenPerformed(SpacesDeviceAPIRequestClientError.timeout("Timed out.")))
        // The shape a deadline actually takes on the production request path.
        #expect(SpacesDeviceAPIRequestOutcome.mayHaveBeenPerformed(SpacesPinnedTLSConnectionError.timeout))
        #expect(SpacesDeviceAPIRequestOutcome.mayHaveBeenPerformed(SpacesPinnedTLSConnectionError.connectionClosed))
        // What `NWConnection` reports for a send or receive that failed on an established connection.
        #expect(SpacesDeviceAPIRequestOutcome.mayHaveBeenPerformed(SpacesPinnedTLSConnectionError.connectionFailed("connection reset")))
        // The raw drop shapes the transport surfaces without wrapping.
        #expect(SpacesDeviceAPIRequestOutcome.mayHaveBeenPerformed(POSIXError(.ECONNRESET)))
    }

    @Test func failuresBeforeARequestCanGoOutAreDefinite() {
        // The non-replayable mutation path dials its own connection, and the resolver reports every dial
        // failure as its own error, so none of these ever carried a request.
        #expect(!SpacesDeviceAPIRequestOutcome.mayHaveBeenPerformed(SpacesDeviceEndpointResolverError.allCandidatesUnreachable(hosts: ["1.2.3.4"])))
        #expect(!SpacesDeviceAPIRequestOutcome.mayHaveBeenPerformed(SpacesDeviceEndpointResolverError.noCandidateHosts))
        #expect(!SpacesDeviceAPIRequestOutcome.mayHaveBeenPerformed(SpacesDeviceEndpointResolverError.transportAuthenticationFailed(host: "1.2.3.4")))
        #expect(!SpacesDeviceAPIRequestOutcome.mayHaveBeenPerformed(SpacesDeviceAPIRequestClientError.invalidPort))
        #expect(!SpacesDeviceAPIRequestOutcome.mayHaveBeenPerformed(SpacesPinnedTLSConnectionError.invalidPort(0)))
    }

    @Test func theDaemonsOwnRejectionIsAnOutcomeRatherThanAnUnknown() {
        #expect(
            !SpacesDeviceAPIRequestOutcome.mayHaveBeenPerformed(
                SpacesDeviceAPIRequestClientError.requestRejected(message: "Destination already exists.", code: .conflict)))
    }
}
