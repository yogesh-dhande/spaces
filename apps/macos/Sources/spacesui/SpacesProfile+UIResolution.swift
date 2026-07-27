import Foundation
import spacesterminalcore

extension SpacesProfile {
    /// UI-layer counterpart of `currentOrNilIfUnresolved()` for call sites that predate the test-host
    /// refusal, read a missing profile as a normal render-anyway outcome, and are not themselves
    /// `throws` — `@objc` actions, `begin()`-style setup steps, and similar entry points that must return
    /// a value rather than propagate an error.
    ///
    /// It keeps the same "no profile" degrade for a genuine resolution failure, but a refusal is not
    /// that: it means the process resolving it is a test host that reached a live user profile, and
    /// letting it fall into a `nil` UI branch here would run the rest of the test unisolated against
    /// whatever that branch does. These call sites have no `throws` to propagate the refusal through, so
    /// instead of rendering around it, this traps — exactly as loud as a call site that could rethrow it,
    /// and loud is the entire point of the guard (see `SpacesProfileResolutionError` in
    /// `spacesterminalcore`).
    static func currentOrNilOnFailureFatalOnRefusal(file: StaticString = #fileID, line: UInt = #line) -> SpacesProfile? {
        do {
            return try currentOrNilIfUnresolved()
        } catch {
            fatalError("\(error)", file: file, line: line)
        }
    }
}
