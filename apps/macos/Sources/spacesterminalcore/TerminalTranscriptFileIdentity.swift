import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The identity of the `output.log` file a handle refers to, as its inode number.
///
/// The transcript endpoint reports it as `SpacesDeviceTerminalTranscriptResult.fileIdentity`, and every
/// render frame a host exports carries it as `GhosttyRenderFrame.transcriptFileIdentity`, so a client
/// can tell whether a frame's `transcriptByteOffset` is measured in the file it fetched. Both sites call
/// this one function so the two can never disagree. A rename of another file over `output.log` (which is
/// how a head-trim commits) leaves an open handle on the file it opened and gives the path a different
/// one, so the number is what distinguishes the two. Inode 0 never names a file, which is why a frame
/// with no transcript carries 0.
///
/// Accepted risk: an inode number can in principle be reused once the trimmed file is unlinked, which
/// would let a stale continuation pass an identity check against a same-numbered but unrelated file. APFS
/// allocates inode numbers monotonically and does not reuse them, and on ext4 a false match needs two
/// trims (each moving tens of megabytes of transcript) landing between two gestures of the same
/// undiscarded replay, plus the allocator happening to hand the freed number back in that window; the
/// existing offset and gap guards in the transcript continuation still bound what such a continuation
/// could return even then. A durable generation token would have to be persisted through the same
/// write-behind runtime state whose lag the run-identity check already tolerates, so the inode is kept
/// rather than adding that persistence for a risk this narrow.
public enum TerminalTranscriptFileIdentity {
    public static func of(_ handle: FileHandle) throws -> UInt64 {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return UInt64(info.st_ino)
    }
}
