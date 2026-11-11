import Foundation

/// The self-update status every `TerminalServiceDaemonStatus` this process builds carries.
///
/// The daemon's update service writes it whenever its view changes; every status this process builds
/// only reads it, so building a status never touches the network or the disk. It stays nil in any process whose daemon cannot update itself.
///
/// A stored status that differs from the held one raises `onChange`. The shared cache raises
/// `TerminalOverviewSignal`, so connected clients hear about a newly found release or advancing
/// progress on an otherwise idle device instead of waiting for an unrelated overview change.
public final class DaemonSelfUpdateStatusCache: @unchecked Sendable {
    public static let shared = DaemonSelfUpdateStatusCache(onChange: { TerminalOverviewSignal.post() })

    private let lock = NSLock()
    private var status: DaemonSelfUpdateStatus?
    private let onChange: (@Sendable () -> Void)?

    public init(onChange: (@Sendable () -> Void)? = nil) {
        self.onChange = onChange
    }

    public var current: DaemonSelfUpdateStatus? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    public func store(_ newValue: DaemonSelfUpdateStatus?) {
        lock.lock()
        let changed = status != newValue
        status = newValue
        lock.unlock()
        if changed { onChange?() }
    }
}
