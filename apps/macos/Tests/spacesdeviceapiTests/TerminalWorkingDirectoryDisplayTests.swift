import Testing
import spacesdevicecore

/// The abbreviation every client uses for a shell row's working directory.
@Suite struct TerminalWorkingDirectoryDisplayTests {
    private let home = "/Users/ada"

    @Test func homeRelativePathKeepsOnlyTheLastComponentWhole() {
        #expect(TerminalWorkingDirectoryDisplay.abbreviated("/Users/ada/projects/spaces", homeDirectory: home) == "~/p/spaces")
        #expect(TerminalWorkingDirectoryDisplay.abbreviated("/Users/ada/projects/spaces/apps/macos", homeDirectory: home) == "~/p/s/a/macos")
    }

    @Test func homeItselfAndItsImmediateChildrenStayReadable() {
        #expect(TerminalWorkingDirectoryDisplay.abbreviated("/Users/ada", homeDirectory: home) == "~")
        #expect(TerminalWorkingDirectoryDisplay.abbreviated("/Users/ada/Downloads", homeDirectory: home) == "~/Downloads")
    }

    /// A hidden component keeps its dot, so `~/.c/nvim` cannot be mistaken for `~/c/nvim`.
    @Test func hiddenComponentsKeepTheirLeadingDot() {
        #expect(TerminalWorkingDirectoryDisplay.abbreviated("/Users/ada/.config/nvim", homeDirectory: home) == "~/.c/nvim")
    }

    @Test func pathsOutsideHomeAbbreviateFromTheRoot() {
        #expect(TerminalWorkingDirectoryDisplay.abbreviated("/var/log/nginx", homeDirectory: home) == "/v/l/nginx")
        #expect(TerminalWorkingDirectoryDisplay.abbreviated("/tmp", homeDirectory: home) == "/tmp")
        #expect(TerminalWorkingDirectoryDisplay.abbreviated("/", homeDirectory: home) == "/")
    }

    /// A remote device's home differs from this client's, so a path that is not under the local home
    /// simply abbreviates from the root rather than inventing a `~`.
    @Test func unrelatedHomeLeavesThePathRooted() {
        #expect(TerminalWorkingDirectoryDisplay.abbreviated("/home/ada/projects/spaces", homeDirectory: home) == "/h/a/p/spaces")
    }

    /// The home passed here is always the OWNING DEVICE's, reported by its daemon — never the reading
    /// client's. An iPhone rendering a Mac's path, or a Mac rendering a Linux daemon's, collapses `~`
    /// correctly only because it abbreviates against the far side's home.
    @Test func pathsCollapseAgainstTheOwningDevicesHomeNotTheReaders() {
        #expect(TerminalWorkingDirectoryDisplay.abbreviated("/home/ada/projects/spaces", homeDirectory: "/home/ada") == "~/p/spaces")
        #expect(
            TerminalWorkingDirectoryDisplay.rowDetail(
                workingDirectory: "/Users/ada/projects/spaces/apps/web", workspaceDirectory: "/Users/ada/projects/spaces", homeDirectory: "/Users/ada"
            ) == "~/p/s/a/web")
    }

    /// A daemon that reports no home at all (a peer predating the field, or a placeholder status for an
    /// offline device) is represented by an empty home: components still shorten, and nothing collapses
    /// to `~` — far better than collapsing against a home that is not the device's.
    @Test func anAbsentDaemonHomeLeavesThePathRootedButStillShortened() {
        #expect(TerminalWorkingDirectoryDisplay.abbreviated("/Users/ada/projects/spaces", homeDirectory: "") == "/U/a/p/spaces")
        #expect(
            TerminalWorkingDirectoryDisplay.rowDetail(
                workingDirectory: "/Users/ada/projects/spaces/apps/web", workspaceDirectory: "/Users/ada/projects/spaces", homeDirectory: "")
                == "/U/a/p/s/a/web")
    }

    @Test func trailingSlashesDoNotChangeTheAbbreviation() {
        #expect(TerminalWorkingDirectoryDisplay.abbreviated("/Users/ada/projects/spaces/", homeDirectory: home) == "~/p/spaces")
    }

    @Test func rowDetailIsHiddenAtTheWorkspaceRoot() {
        #expect(
            TerminalWorkingDirectoryDisplay.rowDetail(
                workingDirectory: "/Users/ada/projects/spaces", workspaceDirectory: "/Users/ada/projects/spaces", homeDirectory: home) == nil)
        #expect(
            TerminalWorkingDirectoryDisplay.rowDetail(
                workingDirectory: "/Users/ada/projects/spaces/", workspaceDirectory: "/Users/ada/projects/spaces", homeDirectory: home) == nil)
    }

    @Test func rowDetailShowsWhereTheShellWanderedTo() {
        #expect(
            TerminalWorkingDirectoryDisplay.rowDetail(
                workingDirectory: "/Users/ada/projects/spaces/apps/web", workspaceDirectory: "/Users/ada/projects/spaces", homeDirectory: home)
                == "~/p/s/a/web")
    }

    /// A session that has never reported a directory has nothing to say about where it is.
    @Test func rowDetailIsHiddenWithoutAWorkingDirectory() {
        #expect(
            TerminalWorkingDirectoryDisplay.rowDetail(workingDirectory: "", workspaceDirectory: "/Users/ada/projects/spaces", homeDirectory: home)
                == nil)
    }

    /// The filesystem root is a present directory, not a missing one — a shell that wandered to `/`
    /// shows it.
    @Test func rowDetailShowsTheFilesystemRoot() {
        #expect(
            TerminalWorkingDirectoryDisplay.rowDetail(workingDirectory: "/", workspaceDirectory: "/Users/ada/projects/spaces", homeDirectory: home)
                == "/")
    }
}
