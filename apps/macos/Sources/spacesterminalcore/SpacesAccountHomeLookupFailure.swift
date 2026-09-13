import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Why `SpacesProfile.accountHomeDirectory()` could not read this account's home from the password database.
///
/// The reason travels with the failure because the lookup's callers are the places a user meets it: a lease
/// directory that cannot be located, a daemon-start decision that cannot establish account identity. Reporting
/// only that the lookup did not work leaves every cause, a directory service that errored, an account with no
/// entry, an entry with no home, indistinguishable in a bug report, so a failure nobody can reproduce locally
/// carries nothing to act on.
public enum SpacesAccountHomeLookupFailure: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// `getpwuid_r` answered with a non-zero status. `bufferSize` is the record buffer in force at the time,
    /// which is what separates a record too large for the growth cap from every other error it can report.
    case lookupFailed(uid: uid_t, status: Int32, bufferSize: Int)
    /// `getpwuid_r` succeeded and reported that the password database holds no entry for this uid.
    case noEntryForAccount(uid: uid_t)
    /// The password database entry exists but names no home directory.
    case emptyHomeDirectory(uid: uid_t)

    public var description: String {
        switch self {
        case .lookupFailed(let uid, let status, let bufferSize):
            return "getpwuid_r for uid \(uid) failed: \(Self.statusName(status)), with a \(bufferSize)-byte record buffer"
        case .noEntryForAccount(let uid): return "the password database holds no entry for uid \(uid)"
        case .emptyHomeDirectory(let uid): return "the password database entry for uid \(uid) names no home directory"
        }
    }

    public var errorDescription: String? { description }

    /// The account the lookup asked about, so a caller reporting this failure can point the user at a command
    /// that queries the same uid rather than at whatever name their environment happens to carry.
    public var uid: uid_t {
        switch self {
        case .lookupFailed(let uid, _, _): uid
        case .noEntryForAccount(let uid): uid
        case .emptyHomeDirectory(let uid): uid
        }
    }

    /// Symbolic name for a `getpwuid_r` status, so a user's report carries the condition rather than a bare
    /// number. The named codes are the ones this lookup can meet: the buffer-size contract, plus the file,
    /// socket, and connection failures `getpwuid_r` inherits from talking to the password database's directory
    /// service. Anything else reports its number alongside the system's own description of it.
    private static func statusName(_ status: Int32) -> String {
        switch status {
        case ERANGE: "ERANGE"
        case EIO: "EIO"
        case EINTR: "EINTR"
        case EMFILE: "EMFILE"
        case ENFILE: "ENFILE"
        case ENOMEM: "ENOMEM"
        case EACCES: "EACCES"
        case EPERM: "EPERM"
        case ECONNREFUSED: "ECONNREFUSED"
        case ENOENT: "ENOENT"
        default: "errno \(status) (\(String(cString: strerror(status))))"
        }
    }
}
