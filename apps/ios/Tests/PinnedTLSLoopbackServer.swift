#if canImport(UIKit)
    import Foundation
    import Network
    import Security
    import spacesterminalcore

    // Shared test-only infrastructure: a loopback pinned-TLS server used by multiple test files. The
    // embedded certificate/private key below is a throwaway, publicly-known self-signed fixture generated
    // solely for this test harness — it has no production role, is not used to protect any real system,
    // and grants access to nothing.

    /// A minimal pinned-TLS test server: an `NWListener` presenting a fixed, pre-generated self-signed
    /// identity and accepting connections without speaking any application-level protocol.
    /// `SpacesDeviceEndpointResolver.connect` only waits for the TLS handshake to reach `.ready`, so this
    /// is enough to drive a genuine (not simulated) resolver success — unlike `LoopbackConnectionSink`,
    /// which only ever proves the pin-mismatch path.
    final class PinnedTLSLoopbackServer: @unchecked Sendable {
        let certificateFingerprint: String
        private let listener: NWListener
        private let queue = DispatchQueue(label: "spaces.device.api.resolver-test.tls-server")
        private let lock = NSLock()
        private var acceptedConnections: [NWConnection] = []
        /// Delays starting each accepted connection by this long before the server begins its side of
        /// the TLS handshake. `NWListener` hands a connection to `newConnectionHandler` as soon as the
        /// kernel accepts the underlying TCP socket, but nothing about the TLS handshake itself proceeds
        /// until `connection.start(queue:)` runs on the server side too: the client's own `NWConnection`
        /// sits in `.preparing` waiting on a `ServerHello` that will not arrive until then. That is the
        /// only lever this in-process test double has to make a *connect* stage consume a controlled,
        /// substantial share of a caller's timeout while still eventually succeeding, which is what
        /// `SpacesDeviceEndpointResolverTests` needs to prove `sendPinnedPing` spends one end-to-end
        /// deadline across connect, send, and read rather than a fresh budget at each stage.
        private let acceptDelay: Duration

        init(acceptDelay: Duration = .zero) throws {
            self.acceptDelay = acceptDelay
            let identity = try PinnedTLSTestFixture.loadIdentity()
            certificateFingerprint = identity.certificateFingerprint
            let tlsOptions = NWProtocolTLS.Options()
            let securityOptions = tlsOptions.securityProtocolOptions
            sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
            // No mutual TLS: only the server presents an identity, matching the real daemon's
            // `TerminalServiceTLSServer` and the client's pin-only (not chain) verification.
            sec_protocol_options_set_peer_authentication_required(securityOptions, false)
            guard let secIdentity = sec_identity_create(identity.identity) else {
                throw NSError(domain: "PinnedTLSLoopbackServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "sec_identity_create failed"])
            }
            sec_protocol_options_set_local_identity(securityOptions, secIdentity)
            let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
            listener = try NWListener(using: parameters)
        }

        func start() async throws -> UInt16 {
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                let beginHandshake: () -> Void = {
                    connection.start(queue: self.queue)
                    self.lock.lock()
                    self.acceptedConnections.append(connection)
                    self.lock.unlock()
                }
                guard self.acceptDelay > .zero else {
                    beginHandshake()
                    return
                }
                Task {
                    try? await Task.sleep(for: self.acceptDelay)
                    self.queue.async(execute: beginHandshake)
                }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume = LoopbackConnectionSinkOneShot(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: resume.resume(returning: ())
                    case .failed(let error): resume.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
            guard let port = listener.port?.rawValue else { throw NSError(domain: "PinnedTLSLoopbackServer", code: 2) }
            return port
        }

        /// Number of connections accepted so far, so a test can wait until its stream has actually arrived
        /// before writing to it.
        func acceptedConnectionCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return acceptedConnections.count
        }

        /// Writes raw bytes to every accepted connection. The server speaks no application protocol, so a
        /// test composes the wire bytes itself: a newline-framed payload line, or the daemon's empty-line
        /// keepalive frame.
        func broadcast(_ data: Data) {
            lock.lock()
            let connections = acceptedConnections
            lock.unlock()
            for connection in connections {
                connection.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { _ in })
            }
        }

        func stop() {
            listener.cancel()
            lock.lock()
            let connections = acceptedConnections
            acceptedConnections.removeAll()
            lock.unlock()
            for connection in connections { connection.cancel() }
        }
    }

    /// Loads the fixed self-signed identity `PinnedTLSLoopbackServer` presents, from DER bytes generated
    /// once (`openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -subj "/CN=spaces-test"`) and
    /// embedded here rather than generated at test run time, since generating one the way the production
    /// `TerminalServiceTLSIdentityStore` does would shell out to `openssl` via `Process`, which iOS does
    /// not have.
    private enum PinnedTLSTestFixture {
        struct Identity {
            let identity: SecIdentity
            let certificateFingerprint: String
        }

        private static let certificateDERBase64 = """
            MIICqDCCAZACCQDuV9iZvn7ZLjANBgkqhkiG9w0BAQsFADAWMRQwEgYDVQQDDAtz\
            cGFjZXMtdGVzdDAeFw0yNjA3MjQxNzQ1NTlaFw0zNjA3MjExNzQ1NTlaMBYxFDAS\
            BgNVBAMMC3NwYWNlcy10ZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC\
            AQEApG2mTFThKLqUXkzKw/HiAush6CKbi3m9EoKXkR3ohRxq4c2cyrGsbg8GYBfV\
            Bga5gqwJ5f5oTs+tmXi5OT0+YitOPEGTxoW1Xrgg/ivjQBIb75J4cdV4v17wpJP9\
            op0g+ew2ihxTLRQKc3sG25L9hXLZuQWu2s0DzEs5M/qKpT41TLJF0BNJkkCV0X1M\
            I/kKmBzHM0TP1OUkU6wXJyDAx2lNwzto3X3SsBEX52kthefDzU7Ew8CPW7JhfTGX\
            i3b9c5nBzWqA9wsmYMAtZiinUZfB3I0qIsO+OrPpU0zSh2uQcLwijYPHs7Gd5BeG\
            o97tGopM/WCv8keCL0zGFgTelQIDAQABMA0GCSqGSIb3DQEBCwUAA4IBAQA/beIg\
            SBA2qt0Djw87O4qrk3weZgYoASGG9+7O4Rf5Cd5oOeT19GGHkdvP4eKTZMdug9wr\
            aMAT+Or0yPG8b4E3PHEWpauBZHKA1yezDzJDbIBtsjaUFx4S+kbGEVBLXhWA2s2P\
            A6vLIEL/EYcqRzNqc3pSH/i5OuTA3cIK0gDhDYMG0ippC4fRQY3lux7go2sgvy7Q\
            mBjnaoRJZpyJojRikSGGsFmnPawebIvSThO2K2IPJ0Hs6txURDMo8rHmxy+BN5eg\
            NzOuqgTSBe0TZdr+M6XJt/MloCIm81WMeHvbJlIE6k7tEc3ydX/erNJba7L3HdqE\
            dF+BShTh8AJ4KWTh
            """
        private static let privateKeyDERBase64 = """
            MIIEpgIBAAKCAQEApG2mTFThKLqUXkzKw/HiAush6CKbi3m9EoKXkR3ohRxq4c2c\
            yrGsbg8GYBfVBga5gqwJ5f5oTs+tmXi5OT0+YitOPEGTxoW1Xrgg/ivjQBIb75J4\
            cdV4v17wpJP9op0g+ew2ihxTLRQKc3sG25L9hXLZuQWu2s0DzEs5M/qKpT41TLJF\
            0BNJkkCV0X1MI/kKmBzHM0TP1OUkU6wXJyDAx2lNwzto3X3SsBEX52kthefDzU7E\
            w8CPW7JhfTGXi3b9c5nBzWqA9wsmYMAtZiinUZfB3I0qIsO+OrPpU0zSh2uQcLwi\
            jYPHs7Gd5BeGo97tGopM/WCv8keCL0zGFgTelQIDAQABAoIBAQCeym2A5a+Tn6vM\
            7agbVqqHWv+hqFpCdcyL5aXttM5qTilB60jxzmfQ2Z20iw9kBHZ+pRniDLA6/ACQ\
            Z6+ogWaPc3bYZhQJ8fJXiMYD7+pEY7iqwe6jMB6t4UfQCEM3GTtRYDbDZdtFe0ck\
            grj6r5c5mtJ8Ber4zmhOkI6rjdb6/+1nJWfLz1951VYo7bbLA6Xexin2K0u6nxwJ\
            Xhoyp3TPTDBUrGNbAYE/G2uMkFmqXw3efs3oUhVYcV0VoKvwfR4/FhRifgz0r5bz\
            phmbg/KUQCmvEHWx5yq/4851K4vai2YuP1emohkuBZIx0SRIwI6ASiSHG2k0wme+\
            7dA1H6E5AoGBANsC+eS8ya+e0tykn9Z+gyCOaDRy5KTyOyFjGFFDi9aiRsqPLstu\
            ooDDaozBzTLii8qA/suLrwzvl/QAe6QnLTNA6HUUH/GknSXo5vrDPelHyjzQrts5\
            7YfTiqGG8UrsStB/zIUpb2UjA4pyGrJAMh0/OXwxVb00RFF6CMOIfiyzAoGBAMAy\
            wAtiQ1GK9E/9xnIC1rh6ee1+J++lACw2MnBeheDCBfceJ9AFSkcnjJ8QXbQJNt+O\
            79ND9doa2uSKOLs4TuAUd8zIOzMcsgWZopIc9e4ZQmJq00M+HYmDQ0V7DCg2GR5C\
            zE2w3ERn9hT39u6LPyZ+lJBdgTX/69M1oJ/3p/uXAoGBAJnBmyLlD0tGW48f3D9A\
            Dlr631mDF9ZdYPntkhLrMu96eeyXXSjhASEZEGLFZIRG3BFNQpQv+rNAOhPJiwQR\
            pQAIn6oieNKy2MjWm+KM05hFGExdzYSHRKVI9Fi2XgxVm6iJMFKEZnpAfKnjta5S\
            t1wlGPyBvknYueXhoOl1l+9VAoGBAJ+RwwXwiCmMLzi2XmrL1o+FB/PYeLmrCRCr\
            0oaew5IOJDu96pn3umqG+GYbhWBzAf7rwktpshVplHCIHX+6ySmbdLctSpEt8tNZ\
            cbLTno8Wo5noTQwX5xgDRffKqBY+i+4m0U5zVvzoP1O7Z2U3cK+6CggtyZgWqSlK\
            7dfCGtJzAoGBAKFrjfyKt/kWXSXtROlGoNQAU3sbcXVeXdxfzPNVyXvBVeRt4AuO\
            CObLPa+NBJM7/FfxgecaWptQwlzqfoRMWkUxAbDG+kdZNbRSxEoUCc57TUBxJ9rZ\
            2m60yZYij5ivd98lB7fIcLF9rxYG8kR3NOpnG+fZrZr94tpZyuDPv9qm
            """

        static func loadIdentity() throws -> Identity {
            guard let certificateData = Data(base64Encoded: certificateDERBase64.filter { !$0.isWhitespace }),
                let keyData = Data(base64Encoded: privateKeyDERBase64.filter { !$0.isWhitespace })
            else { throw NSError(domain: "PinnedTLSTestFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid fixture base64"]) }
            guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
                throw NSError(domain: "PinnedTLSTestFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid fixture certificate"])
            }
            // PKCS#1 RSA private-key DER, matching the format `openssl pkcs8 -nocrypt ... -outform der`
            // emits from an unencrypted key — the same format the production identity store loads.
            let keyAttributes =
                [
                    kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                    kSecAttrIsPermanent as String: false,
                ] as CFDictionary
            var keyError: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateWithData(keyData as CFData, keyAttributes, &keyError) else {
                throw keyError?.takeRetainedValue() ?? NSError(domain: "PinnedTLSTestFixture", code: 3)
            }
            guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
                throw NSError(domain: "PinnedTLSTestFixture", code: 4, userInfo: [NSLocalizedDescriptionKey: "SecIdentityCreate failed"])
            }
            return Identity(identity: identity, certificateFingerprint: TerminalServiceTLSFingerprint.fingerprint(certificate: certificate))
        }
    }

    final class LoopbackConnectionSinkOneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, any Error>?

        init(_ continuation: CheckedContinuation<Void, any Error>) { self.continuation = continuation }

        func resume(returning value: Void) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }

        func resume(throwing error: any Error) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(throwing: error)
        }
    }
#endif
