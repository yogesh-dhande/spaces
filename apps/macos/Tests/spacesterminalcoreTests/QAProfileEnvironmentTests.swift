#if os(macOS)
    import Foundation
    import Testing

    @testable import spacesterminalcore

    /// The QA lane launches shipped binaries, which inherit the environment they are launched from, so a
    /// binding that would send one of them somewhere other than the QA profile has to be reported rather
    /// than silently dropped.
    @Suite struct QAProfileEnvironmentTests {
        @Test func reportsNothingForACleanEnvironment() {
            #expect(QAProfileEnvironment.redirectingBindings(in: ["PATH": "/usr/bin", "HOME": "/Users/qa"]).isEmpty)
        }

        /// Both halves of the list are live: the daemon-side names that decide which `spacesd` runs and how
        /// it serves, and the rest, which decide where a Mac client keeps its database and device secrets
        /// and which Ghostty resources a terminal renders against.
        @Test func reportsDaemonAndClientRedirection() {
            let environment = [
                "SPACESD_EXECUTABLE": "/tmp/spacesd", SpacesProfile.runtimeDirectoryEnvironmentVariable: "/tmp/runtime",
                "SPACES_DEVICE_API_PORT": "47999", SpacesProfile.databasePathEnvironmentVariable: "/tmp/other/spaces.db",
                "SPACES_CLIENT_DB_PATH": "/tmp/other/spaces-client.db", "SPACES_CLIENT_SECRET_DIR": "/tmp/other/client-secrets",
                "SPACES_GHOSTTY_RESOURCES_DIR": "/tmp/checkout/ghostty", "PATH": "/usr/bin",
            ]

            #expect(
                QAProfileEnvironment.redirectingBindings(in: environment) == [
                    "SPACESD_EXECUTABLE", SpacesProfile.runtimeDirectoryEnvironmentVariable, "SPACES_DEVICE_API_PORT",
                    SpacesProfile.databasePathEnvironmentVariable, "SPACES_CLIENT_DB_PATH", "SPACES_CLIENT_SECRET_DIR",
                    "SPACES_GHOSTTY_RESOURCES_DIR",
                ])
        }

        /// The refusal is a preflight rather than a failure at the point of use, because `deploy-remote`
        /// pairs through the installed CLI only after it has installed a release on the device and started
        /// its daemon. It names every offending variable and the work it is refusing, since the operator
        /// has to know which binding to unset.
        @Test func refusesTheWorkAndNamesEveryBinding() {
            let refusal = QAProfileEnvironment.redirectingRefusal(
                in: ["SPACESD_EXECUTABLE": "/repo/.build/debug/spacesd", "SPACES_CLIENT_DB_PATH": "/tmp/other.db", "PATH": "/usr/bin"],
                action: "deploy the remote QA daemon")

            #expect(refusal?.contains("SPACESD_EXECUTABLE, SPACES_CLIENT_DB_PATH are bindings") == true)
            #expect(refusal?.contains("deploy the remote QA daemon") == true)
            #expect(QAProfileEnvironment.redirectingRefusal(in: ["PATH": "/usr/bin"], action: "deploy the remote QA daemon") == nil)
        }

        /// `TerminalService.resolveExecutableURL` reads `_` before `Bundle.main.executableURL` when it picks
        /// a `spacesd`, and a shell sets `_` to the command it invoked, so an installed binary launched with
        /// the lane's own `_` would resolve a daemon beside the repo-built helper instead of its bundled
        /// one.
        @Test func namesTheLaunchedBinaryInTheInheritedUnderscore() {
            let environment = QAProfileEnvironment.environmentForInstalledProcess(
                executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp", databasePath: "/Users/qa/.spaces-dev/qa/spaces.db",
                base: ["_": "/repo/apps/macos/.build/debug/spacese2e", "PATH": "/usr/bin"])

            #expect(environment["_"] == "/Applications/Spaces.app/Contents/MacOS/SpacesApp")
            #expect(environment[SpacesProfile.databasePathEnvironmentVariable] == "/Users/qa/.spaces-dev/qa/spaces.db")
            #expect(environment["PATH"] == "/usr/bin")
        }

        /// An exported-then-emptied variable is not a redirection, and reading it as one would refuse to run
        /// in a shell that is in fact clean.
        @Test func treatsAnEmptyBindingAsAbsent() {
            #expect(QAProfileEnvironment.redirectingBindings(in: [SpacesProfile.runtimeDirectoryEnvironmentVariable: "  "]).isEmpty)
        }
    }
#endif
