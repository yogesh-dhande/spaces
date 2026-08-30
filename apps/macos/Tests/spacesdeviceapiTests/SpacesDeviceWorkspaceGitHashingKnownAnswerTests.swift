import Foundation
import Testing

@testable import spacesdeviceapi

/// Round-20: `sha256Hex`'s `#elseif canImport(OpenSSL)` branch (Linux) only compiles there, so this suite
/// only actually exercises that branch when it runs on the Linux lane (see `run_linux_tests.sh`); on macOS
/// it exercises the `CryptoKit` branch instead, which is harmless (the assertions are branch-agnostic
/// known-answer values) but does not by itself prove the Linux branch is correct. Both known-answer values
/// are the standard SHA-256 test vectors for their inputs.
@Suite struct SpacesDeviceWorkspaceGitHashingKnownAnswerTests {
    @Test func emptyInputHashesToTheStandardSHA256EmptyDigest() {
        #expect(
            SpacesDeviceWorkspaceGitHashing.sha256Hex(Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    @Test func abcHashesToItsKnownSHA256Digest() {
        #expect(
            SpacesDeviceWorkspaceGitHashing.sha256Hex(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
