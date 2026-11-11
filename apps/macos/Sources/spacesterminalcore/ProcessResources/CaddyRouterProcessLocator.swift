import Foundation

#if os(macOS)
    import Darwin

    /// Finds the pid of this profile's Caddy router for resource sampling.
    ///
    /// `CaddyService` launches Caddy with `--pidfile`, so the router's pid is one small file read per
    /// sample. The file outlives a router that was killed, and the system can hand that pid to another
    /// program, so a pid counts only while its executable is the bundled Caddy. A router adopted from a
    /// build that launched it without a pid file is not counted until it next restarts.
    public struct CaddyRouterProcessLocator {
        private let executablePath: String?

        public init() { executablePath = (try? CaddyService.resolveExecutableURL())?.resolvingSymlinksInPath().path }

        /// The router's pid, or nil when this profile has no running router.
        public func currentProcessID() -> pid_t? {
            guard let executablePath, let pidFilePath = try? CaddyService.pidFilePath(),
                let contents = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
                let processID = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)), processID > 0
            else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
            return path == executablePath ? processID : nil
        }
    }
#endif
