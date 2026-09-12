import Foundation

#if os(macOS)
    /// The environment bindings that would point a shipped Spaces binary away from the profile it is
    /// started for, and which the QA lane therefore refuses to start anything under.
    ///
    /// The lane runs the INSTALLED app and the INSTALLED `spaces` CLI, and a launched process inherits the
    /// environment of the shell that ran the lane. Every name here redirects part of that shipped build:
    /// which `spacesd` runs, where its runtime directory, client database, and device secrets live, and
    /// which host and port its Device API serves. A sweep that inherited one would be reporting on a
    /// mixture of the QA profile and wherever the binding points, which is the one thing the lane exists to
    /// rule out.
    ///
    /// They are refused rather than cleared. A shell carrying these is a shell someone pointed somewhere on
    /// purpose, so dropping the binding silently would hide that rather than fix it, and the operator would
    /// be left wondering why their override did nothing.
    public enum QAProfileEnvironment {
        /// What a Mac CLIENT reads to place its own state, plus the Ghostty resource override, none of which
        /// the daemon-side list covers. These are `SpacesClientDatabase.databasePathEnvironmentVariable`,
        /// `SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable`, and
        /// `GhosttyEmbeddedPaths.resourcesEnvironmentVariable`, which `GhosttyEmbeddedLocator` prefers over
        /// the resources bundled beside the binary: bound, the shipped daemon renders terminals against a
        /// checkout's Ghostty resources instead of the ones the release shipped with, which is the opposite
        /// of what a QA sweep is reading. They are mirrored as literals because both owning modules depend
        /// on this one rather than the other way around. Renaming one there means renaming it here.
        static let clientRedirectingVariables = ["SPACES_CLIENT_DB_PATH", "SPACES_CLIENT_SECRET_DIR", "SPACES_GHOSTTY_RESOURCES_DIR"]

        /// Every name the lane refuses. The daemon-side half is `TerminalService`'s own list, which exists
        /// for a neighbouring reason: a binding that changes which daemon runs, or how it serves, cannot
        /// survive a launchd kickstart. The same bindings are what would redirect a daemon the lane starts
        /// directly, so the two lists are one list rather than a copy.
        public static let redirectingVariables =
            TerminalService.kickstartForbiddingEnvironmentVariables + [SpacesProfile.databasePathEnvironmentVariable] + clientRedirectingVariables

        /// Why the lane refuses to do `action` from `environment`, or `nil` when nothing in it redirects.
        ///
        /// Separated from the commands so a caller can run it as a preflight: `deploy-remote` finishes by
        /// pairing through the installed CLI, and that refusal is worth nothing at the end of a command
        /// that has already installed a release on the device and started its daemon.
        public static func redirectingRefusal(in environment: [String: String], action: String) -> String? {
            let bound = redirectingBindings(in: environment)
            guard !bound.isEmpty else { return nil }
            let subject = bound.count == 1 ? "is a binding" : "are bindings"
            return "\(bound.joined(separator: ", ")) \(subject) in this environment that would point the installed build away from the QA profile. "
                + "Unset \(bound.count == 1 ? "it" : "them") before asking the lane to \(action)."
        }

        /// The environment an installed binary is launched with by the QA lane: the caller's own, plus the
        /// QA profile's database path, plus `_` naming the binary being launched.
        ///
        /// `_` matters because `TerminalService.resolveExecutableURL` reads it before
        /// `Bundle.main.executableURL` when it decides which `spacesd` to start, and a shell sets it to the
        /// command it invoked. Inherited unchanged, it names the repo-built helper that ran the lane, so the
        /// installed app would look for a `spacesd` sibling of THAT and find the checkout's own. Setting it
        /// to the executable being launched is what the shell would have set had the binary been run
        /// directly, which is the whole intent: the installed build, resolving its own bundled daemon.
        public static func environmentForInstalledProcess(executablePath: String, databasePath: String, base: [String: String]) -> [String: String] {
            var environment = base
            environment[SpacesProfile.databasePathEnvironmentVariable] = databasePath
            environment["_"] = executablePath
            return environment
        }

        /// The redirecting names bound in `environment`, in list order. An empty or whitespace binding
        /// counts as absent, matching how `TerminalService.resolveStartPlan` reads the same names.
        public static func redirectingBindings(in environment: [String: String]) -> [String] {
            redirectingVariables.filter { !(environment[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }
#endif
