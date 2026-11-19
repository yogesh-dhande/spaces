import Foundation

/// Runs `body` and releases the Foundation objects it autoreleased before returning.
///
/// The index build runs on a plain thread that never returns to a run loop, so autoreleased objects (every
/// `JSONSerialization` result, every `FileManager` attributes dictionary) would otherwise pile up until
/// the thread exits and hold hundreds of megabytes on a large store. Linux has no autorelease pools.
func withAutoreleasePool<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
        return try autoreleasepool(invoking: body)
    #else
        return try body()
    #endif
}
