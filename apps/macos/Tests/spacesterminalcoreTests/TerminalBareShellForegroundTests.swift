import Testing

@testable import spacesterminalcore

/// The shared "is this terminal sitting at a bare prompt" rule, which decides both whether a closed ad
/// hoc terminal stops and whether a detected coding-agent row demotes. The cases below are the ones the
/// two decisions turn on: an idle shell, a shell that IS the user's program, and a shell that is not the
/// session's own.
@Suite struct TerminalBareShellForegroundTests {
    @Test func idleLaunchShellIsBare() {
        #expect(TerminalBareShellForeground.isBareShell(executableName: "zsh", argv: ["/bin/zsh"], launchShell: "/bin/zsh"))
    }

    @Test func loginShellDashFormIsBare() {
        #expect(TerminalBareShellForeground.isBareShell(executableName: "-zsh", argv: ["-zsh"], launchShell: "/bin/zsh"))
    }

    @Test func flagOnlyArgumentsAreBare() {
        #expect(TerminalBareShellForeground.isBareShell(executableName: "zsh", argv: ["/bin/zsh", "-i", "-l"], launchShell: "/bin/zsh"))
    }

    @Test func emptyArgvWithMatchingShellIsBare() {
        #expect(TerminalBareShellForeground.isBareShell(executableName: "zsh", argv: [], launchShell: "/bin/zsh"))
        #expect(TerminalBareShellForeground.isBareShell(executableName: "zsh", argv: nil, launchShell: "/bin/zsh"))
    }

    @Test func shellRunningAScriptIsNotBare() {
        #expect(!TerminalBareShellForeground.isBareShell(executableName: "zsh", argv: ["/bin/zsh", "build.sh"], launchShell: "/bin/zsh"))
    }

    @Test func shellRunningACommandIsNotBare() {
        #expect(!TerminalBareShellForeground.isBareShell(executableName: "zsh", argv: ["/bin/zsh", "-c", "npm run dev"], launchShell: "/bin/zsh"))
    }

    @Test func differentShellThanTheSessionLaunchedIsNotBare() {
        #expect(!TerminalBareShellForeground.isBareShell(executableName: "bash", argv: ["bash"], launchShell: "/bin/zsh"))
    }

    @Test func missingForegroundSampleIsNotBare() {
        #expect(!TerminalBareShellForeground.isBareShell(executableName: nil, argv: nil, launchShell: "/bin/zsh"))
        #expect(!TerminalBareShellForeground.isBareShell(executableName: "  ", argv: nil, launchShell: "/bin/zsh"))
    }

    @Test func realProgramIsNotBare() {
        #expect(!TerminalBareShellForeground.isBareShell(executableName: "vim", argv: ["vim", "notes.md"], launchShell: "/bin/zsh"))
    }
}
