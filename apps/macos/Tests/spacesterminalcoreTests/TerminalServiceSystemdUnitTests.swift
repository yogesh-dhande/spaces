import Foundation
import Testing

@testable import spacesterminalcore

#if os(Linux)
    /// A Linux daemon is owned by user systemd rather than spawned by the client, so "start this profile's
    /// daemon" means "start this profile's unit". This suite pins that mapping, which is what decides
    /// whether one device can serve an installed daemon and several deployed development daemons at once.
    ///
    /// Deliberately a Swift Testing suite, and Linux-only: `systemdUnitName` exists only in the Linux half
    /// of `TerminalService`, so no other lane can cover it, and an XCTest suite deadlocks the Linux runner
    /// (see `apps/macos/scripts/run_linux_tests.sh`). It touches no environment and no filesystem — the
    /// mapping is a pure function of a profile value — so it needs no profile isolation of its own.
    @Suite struct TerminalServiceSystemdUnitTests {
        /// The device's one installed profile is served by the one non-templated unit, so a client that
        /// reaches an installed profile always starts the same daemon.
        @Test func installedProfileIsOwnedByTheSingleInstalledUnit() {
            let profile = makeProfile(source: .installedFallback, rootDirectory: "/home/dev/.spaces")

            #expect(TerminalService.systemdUnitName(for: profile) == "spacesd.service")
        }

        /// A deployed development profile is served by its own instance of the shared `spacesd@.service`
        /// template, keyed by the profile's directory name. Two profiles therefore never resolve to one
        /// unit, which is the whole reason starting one profile's daemon cannot disturb another's.
        @Test func deployedDevelopmentProfileIsOwnedByItsOwnTemplateInstance() {
            let first = makeProfile(
                source: .deployedDevelopmentProfile, rootDirectory: "/home/dev/.spaces-dev/profiles/spaces/feature-x-0123456789ab")
            let second = makeProfile(source: .deployedDevelopmentProfile, rootDirectory: "/home/dev/.spaces-dev/profiles/spaces/main-abcdef012345")

            #expect(TerminalService.systemdUnitName(for: first) == "spacesd@feature-x-0123456789ab.service")
            #expect(TerminalService.systemdUnitName(for: second) == "spacesd@main-abcdef012345.service")
            #expect(TerminalService.systemdUnitName(for: first) != TerminalService.systemdUnitName(for: second))
        }

        /// The unit follows what the profile IS, not the branch that resolved it. A daemon that reached the
        /// installed root through an explicit database path is still the installed profile's daemon, so it
        /// starts the installed unit rather than being treated as a development profile with no unit at all.
        @Test func profileAtTheInstalledRootIsInstalledWhateverRouteResolvedIt() {
            let viaExplicitPath = makeProfile(source: .explicitDatabasePath, rootDirectory: "/home/dev/.spaces")

            #expect(TerminalService.systemdUnitName(for: viaExplicitPath) == "spacesd.service")
        }

        /// A repo-built worktree profile and an explicit database path have no unit on the device, so there
        /// is nothing to ask systemd to start and a missing daemon stays the caller's own error. Naming a
        /// unit for either would only ask systemd for something no install ever wrote.
        @Test func profilesWithoutAnInstalledUnitResolveToNoUnit() {
            let worktree = makeProfile(source: .developmentWorktree, rootDirectory: "/home/dev/.spaces-dev/profiles/spaces/feature-x-0123456789ab")
            let explicitDatabase = makeProfile(source: .explicitDatabasePath, rootDirectory: "/tmp/scratch-profile")

            #expect(TerminalService.systemdUnitName(for: worktree) == nil)
            #expect(TerminalService.systemdUnitName(for: explicitDatabase) == nil)
        }

        /// Mirrors production: installed-ness is derived from the resolved ROOT against the device's home,
        /// not from the source, so a profile that reached `~/.spaces` by an unusual route is still the
        /// installed profile here.
        private func makeProfile(source: SpacesProfileSource, rootDirectory: String, homeDirectory: String = "/home/dev") -> SpacesProfile {
            SpacesProfile(
                source: source, databasePath: "\(rootDirectory)/spaces.db", rootDirectory: rootDirectory,
                isInstalledProfile: rootDirectory == "\(homeDirectory)/.spaces", runtimeDirectory: "\(rootDirectory)/runtime",
                ipcNotificationObject: "spaces.profile.systemd-unit-tests", developmentContext: nil, branchSlug: nil, worktreeHash: nil)
        }
    }
#endif
