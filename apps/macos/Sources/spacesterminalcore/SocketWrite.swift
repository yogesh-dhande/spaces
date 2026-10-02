#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Writes to a stream socket without ever raising SIGPIPE: Darwin relies on `SO_NOSIGPIPE` set on the
/// socket, Linux has no such option and passes `MSG_NOSIGNAL` per call. A closed peer surfaces as `EPIPE`
/// instead of a signal that kills a host process which has not ignored SIGPIPE (a test runner; `spacesd`
/// ignores it process-wide, which also covers OpenSSL's `SSL_write`, the one writer that cannot take
/// the flag). Only for sockets: `send` fails with `ENOTSOCK` on any other descriptor.
public func spacesWriteToSocket(_ fileDescriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Glibc)
        send(fileDescriptor, bytes, count, Int32(MSG_NOSIGNAL))
    #else
        write(fileDescriptor, bytes, count)
    #endif
}
