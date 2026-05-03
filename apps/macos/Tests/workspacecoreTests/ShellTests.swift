import Foundation
import XCTest

@testable import systembridge

final class ShellTests: XCTestCase {
    // Tests run returns exit status by arranging representative inputs and asserting the expected result.
    func testRunReturnsExitStatus() throws {
        let status = try Shell.run(["sh", "-lc", "exit 7"])
        XCTAssertEqual(status, 7)
    }

    // Tests run uses working directory by arranging representative inputs and asserting the expected result.
    func testRunUsesWorkingDirectory() throws {
        let directory = try makeTempDirectory()
        let output = try Shell.runAndCapture(["pwd"], cwd: directory.path)
        let reported = URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
        let expected = directory.resolvingSymlinksInPath().path
        XCTAssertEqual(reported, expected)
    }

    // Tests run and capture returns stdout by arranging representative inputs and asserting the expected result.
    func testRunAndCaptureReturnsStdout() throws {
        let output = try Shell.runAndCapture(["sh", "-lc", "printf 'hello'"])
        XCTAssertEqual(output, "hello")
    }

    func testRunAndCaptureResolvesCommandUsingLoginShellPath() throws {
        let root = try makeTempDirectory()
        let commandDirectory = root.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: true)

        let commandFile = commandDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'resolved-via-login-shell'\n".write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              printf '\n__SPACES_PATH__%s' "\(commandDirectory.path):/usr/bin:/bin"
              exit 0
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
        }

        let output = try Shell.runAndCapture(["mockcmd"])
        XCTAssertEqual(output, "resolved-via-login-shell")
    }

    func testRunAndCaptureUsesAbsolutePrintenvWhenLoginShellPathOmitsUsrBin() throws {
        let root = try makeTempDirectory()
        let commandDirectory = root.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: true)

        let commandFile = commandDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'resolved-with-absolute-printenv'\n".write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              export PATH="\(commandDirectory.path)"
              exec /bin/sh -c "$3"
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "", 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
        }

        let output = try Shell.runAndCapture(["mockcmd"])
        XCTAssertEqual(output, "resolved-with-absolute-printenv")
    }

    func testResolvedLoginShellExecutablePathFallsBackToCurrentUserShellWhenEnvironmentOmitsShell() {
        let accountInfo = currentUserAccountInfo()
        guard let shellPath = accountInfo?.shellPath, !shellPath.isEmpty else {
            XCTFail("Expected current user account info to include a login shell")
            return
        }

        XCTAssertEqual(Shell.resolvedLoginShellExecutablePath(environment: [:]), shellPath)
    }

    func testRunAndCaptureSeedsLoginShellProbeWithSystemPathWhenInheritedPathIsEmpty() throws {
        let root = try makeTempDirectory()
        let commandDirectory = root.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: true)

        let commandFile = commandDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'resolved-with-system-seed'\n".write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              uname >/dev/null 2>&1 || exit 17
              export PATH="\(commandDirectory.path):$PATH"
              exec /bin/sh -c "$3"
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "", 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
        }

        let output = try Shell.runAndCapture(["mockcmd"])
        XCTAssertEqual(output, "resolved-with-system-seed")
    }

    func testRunAndCaptureUsesShellAgnosticPathProbe() throws {
        let root = try makeTempDirectory()
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)

        let commandFile = firstDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'fish-safe-path'\n".write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              case "$3" in
                *'/usr/bin/printenv PATH'*)
                  printf '\n__SPACES_PATH__'
                  /usr/bin/printenv PATH
                  ;;
                *)
                  printf '\n__SPACES_PATH__%s__SPACES_PATH__%s' "\(firstDirectory.path)" "\(secondDirectory.path)"
                  ;;
              esac
              exit 0
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "\(firstDirectory.path):\(secondDirectory.path):/usr/bin:/bin", 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
        }

        let output = try Shell.runAndCapture(["mockcmd"])
        XCTAssertEqual(output, "fish-safe-path")
    }

    func testRunAndCaptureIgnoresTrailingStdoutNoiseAfterLoginShellPathLine() throws {
        let root = try makeTempDirectory()
        let commandDirectory = root.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: true)

        let commandFile = commandDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'path-with-trailing-noise'\n".write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              printf '\n__SPACES_PATH__%s\n' "\(commandDirectory.path):/usr/bin:/bin"
              printf 'startup-noise-after-path\n'
              exit 0
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
        }

        let output = try Shell.runAndCapture(["mockcmd"])
        XCTAssertEqual(output, "path-with-trailing-noise")
    }

    func testRunAndCapturePreservesPathEntriesContainingMarkerText() throws {
        let root = try makeTempDirectory()
        let commandDirectory = root.appendingPathComponent("__SPACES_PATH__-commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: true)

        let commandFile = commandDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'marker-entry-path'\n".write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              printf '\n__SPACES_PATH__%s' "\(commandDirectory.path):/usr/bin:/bin"
              exit 0
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
        }

        let output = try Shell.runAndCapture(["mockcmd"])
        XCTAssertEqual(output, "marker-entry-path")
    }

    func testRunAndCapturePreservesInheritedPathOrderOverLoginShellDuplicates() throws {
        let root = try makeTempDirectory()
        let inheritedDirectory = root.appendingPathComponent("inherited", isDirectory: true)
        let loginDirectory = root.appendingPathComponent("login", isDirectory: true)
        try FileManager.default.createDirectory(at: inheritedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: loginDirectory, withIntermediateDirectories: true)

        let inheritedCommand = inheritedDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'inherited-copy'\n".write(to: inheritedCommand, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inheritedCommand.path)

        let loginCommand = loginDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'login-copy'\n".write(to: loginCommand, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loginCommand.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              printf '\n__SPACES_PATH__%s' "\(loginDirectory.path):\(inheritedDirectory.path):/usr/bin:/bin"
              exit 0
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "\(inheritedDirectory.path):/usr/bin:/bin", 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
        }

        let output = try Shell.runAndCapture(["mockcmd"])
        XCTAssertEqual(output, "inherited-copy")
    }

    func testRunAndCapturePreservesInheritedEmptyPathSegmentForCurrentDirectoryLookup() throws {
        let root = try makeTempDirectory()
        let workingDirectory = root.appendingPathComponent("cwd", isDirectory: true)
        let loginDirectory = root.appendingPathComponent("login", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: loginDirectory, withIntermediateDirectories: true)

        let commandFile = workingDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'cwd-copy'\n".write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              printf '\n__SPACES_PATH__%s' "\(loginDirectory.path):/usr/bin:/bin"
              exit 0
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", ":/usr/bin:/bin", 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
        }

        let output = try Shell.runAndCapture(["mockcmd"], cwd: workingDirectory.path)
        XCTAssertEqual(output, "cwd-copy")
    }

    func testRunAndCaptureCachesResolvedLoginShellPath() throws {
        let root = try makeTempDirectory()
        let commandDirectory = root.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: true)

        let commandFile = commandDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'cached-login-shell'\n".write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let counterFile = root.appendingPathComponent("shell-invocations.txt")
        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              count=0
              if [ -f "\(counterFile.path)" ]; then
                count=$(cat "\(counterFile.path)")
              fi
              count=$((count + 1))
              printf '%s' "$count" > "\(counterFile.path)"
              printf '\n__SPACES_PATH__%s' "\(commandDirectory.path):/usr/bin:/bin"
              exit 0
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let originalHome = ProcessInfo.processInfo.environment["HOME"] ?? ""
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        setenv("HOME", root.path, 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
            setenv("HOME", originalHome, 1)
        }

        XCTAssertEqual(try Shell.runAndCapture(["mockcmd"]), "cached-login-shell")
        XCTAssertEqual(try Shell.runAndCapture(["mockcmd"]), "cached-login-shell")
        let invocationCount = try String(contentsOf: counterFile, encoding: .utf8)
        XCTAssertEqual(invocationCount, "1")
    }

    func testRunAndCaptureRefreshesCachedLoginShellPathWhenInheritedPathChanges() throws {
        let root = try makeTempDirectory()
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)

        let firstCommand = firstDirectory.appendingPathComponent("firstcmd")
        try "#!/bin/sh\nprintf 'first-path'\n".write(to: firstCommand, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: firstCommand.path)

        let secondCommand = secondDirectory.appendingPathComponent("secondcmd")
        try "#!/bin/sh\nprintf 'second-path'\n".write(to: secondCommand, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secondCommand.path)

        let counterFile = root.appendingPathComponent("shell-invocations.txt")
        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              count=0
              if [ -f "\(counterFile.path)" ]; then
                count=$(cat "\(counterFile.path)")
              fi
              count=$((count + 1))
              printf '%s' "$count" > "\(counterFile.path)"
              printf '\n__SPACES_PATH__'
              /usr/bin/printenv PATH
              exit 0
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let originalHome = ProcessInfo.processInfo.environment["HOME"] ?? ""
        setenv("SHELL", shellFile.path, 1)
        setenv("HOME", root.path, 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
            setenv("HOME", originalHome, 1)
        }

        setenv("PATH", "\(firstDirectory.path):/usr/bin:/bin", 1)
        XCTAssertEqual(try Shell.runAndCapture(["firstcmd"]), "first-path")

        setenv("PATH", "\(secondDirectory.path):/usr/bin:/bin", 1)
        XCTAssertEqual(try Shell.runAndCapture(["secondcmd"]), "second-path")

        let invocationCount = try String(contentsOf: counterFile, encoding: .utf8)
        XCTAssertEqual(invocationCount, "2")
    }

    func testRunAndCapturePassesShellConfigEnvironmentIntoLoginProbe() throws {
        let root = try makeTempDirectory()
        let commandDirectory = root.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: true)

        let commandFile = commandDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'config-env-path'\n".write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              [ "$ZDOTDIR" = "\(root.path)/zdotdir" ] || exit 17
              [ "$XDG_CONFIG_HOME" = "\(root.path)/xdg-home" ] || exit 18
              [ "$XDG_CONFIG_DIRS" = "\(root.path)/xdg-dirs" ] || exit 19
              printf '\n__SPACES_PATH__%s' "\(commandDirectory.path):/usr/bin:/bin"
              exit 0
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let originalZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"]
        let originalXdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let originalXdgConfigDirs = ProcessInfo.processInfo.environment["XDG_CONFIG_DIRS"]
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        setenv("ZDOTDIR", "\(root.path)/zdotdir", 1)
        setenv("XDG_CONFIG_HOME", "\(root.path)/xdg-home", 1)
        setenv("XDG_CONFIG_DIRS", "\(root.path)/xdg-dirs", 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
            if let originalZdotdir { setenv("ZDOTDIR", originalZdotdir, 1) } else { unsetenv("ZDOTDIR") }
            if let originalXdgConfigHome { setenv("XDG_CONFIG_HOME", originalXdgConfigHome, 1) } else { unsetenv("XDG_CONFIG_HOME") }
            if let originalXdgConfigDirs { setenv("XDG_CONFIG_DIRS", originalXdgConfigDirs, 1) } else { unsetenv("XDG_CONFIG_DIRS") }
        }

        let output = try Shell.runAndCapture(["mockcmd"])
        XCTAssertEqual(output, "config-env-path")
    }

    func testRunAndCaptureDrainsNoisyLoginShellStderr() throws {
        let root = try makeTempDirectory()
        let commandDirectory = root.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: true)

        let commandFile = commandDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'stderr-drained'\n".write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              i=0
              while [ "$i" -lt 4096 ]; do
                printf 'stderr-noise-%04d\\n' "$i" >&2
                i=$((i + 1))
              done
              printf '\n__SPACES_PATH__%s' "\(commandDirectory.path):/usr/bin:/bin"
              exit 0
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let originalHome = ProcessInfo.processInfo.environment["HOME"] ?? ""
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        setenv("HOME", root.path, 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
            setenv("HOME", originalHome, 1)
        }

        XCTAssertEqual(try Shell.runAndCapture(["mockcmd"]), "stderr-drained")
    }

    func testRunAndCaptureFallsBackWhenLoginShellPathProbeTimesOut() throws {
        let root = try makeTempDirectory()
        let commandDirectory = root.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: true)

        let commandFile = commandDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'fallback-path'\n".write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              sleep 5
              exit 0
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let originalTimeout = ProcessInfo.processInfo.environment["SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS"]
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "\(commandDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin", 1)
        setenv("SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS", "0.05", 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
            if let originalTimeout {
                setenv("SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS", originalTimeout, 1)
            } else {
                unsetenv("SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS")
            }
        }

        let startedAt = Date()
        let output = try Shell.runAndCapture(["mockcmd"])
        XCTAssertEqual(output, "fallback-path")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2.0)
    }

    func testRunAndCaptureReapsTimedOutLoginShellProbe() throws {
        let root = try makeTempDirectory()
        let commandDirectory = root.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: true)

        let commandFile = commandDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'reaped-timeout'\n".write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              trap '' INT TERM
              while :; do sleep 1; done
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let originalTimeout = ProcessInfo.processInfo.environment["SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS"]
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "\(commandDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin", 1)
        setenv("SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS", "0.05", 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
            if let originalTimeout {
                setenv("SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS", originalTimeout, 1)
            } else {
                unsetenv("SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS")
            }
        }

        let output = try Shell.runAndCapture(["mockcmd"])
        XCTAssertEqual(output, "reaped-timeout")
        XCTAssertFalse(processListContains(argumentFragment: shellFile.path), "Timed-out login-shell probe should be reaped")
    }

    func testRunAndCaptureFallsBackWhenTimedOutShellLeavesInheritedPipesOpen() throws {
        let root = try makeTempDirectory()
        let commandDirectory = root.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: true)

        let commandFile = commandDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'fallback-with-open-pipes'\n".write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              /bin/sh -c "sleep 5 >&1 & sleep 5 >&2 & sleep 5"
              exit 0
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let originalTimeout = ProcessInfo.processInfo.environment["SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS"]
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "\(commandDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin", 1)
        setenv("SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS", "0.05", 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
            if let originalTimeout {
                setenv("SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS", originalTimeout, 1)
            } else {
                unsetenv("SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS")
            }
        }

        let startedAt = Date()
        let output = try Shell.runAndCapture(["mockcmd"])
        XCTAssertEqual(output, "fallback-with-open-pipes")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2.0)
    }

    func testRunAndCaptureUsesSingleDrainBudgetAfterShellExit() throws {
        let root = try makeTempDirectory()
        let commandDirectory = root.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: true)

        let commandFile = commandDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'single-drain-budget'\n".write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              /bin/sh -c "sleep 5 >&2" &
              exit 0
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let originalTimeout = ProcessInfo.processInfo.environment["SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS"]
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "\(commandDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin", 1)
        setenv("SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS", "2.0", 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
            if let originalTimeout {
                setenv("SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS", originalTimeout, 1)
            } else {
                unsetenv("SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS")
            }
        }

        let startedAt = Date()
        let output = try Shell.runAndCapture(["mockcmd"])
        XCTAssertEqual(output, "single-drain-budget")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3.5)
    }

    func testRunAndCaptureRefreshesCachedLoginShellPathWhenZdotdirChanges() throws {
        let root = try makeTempDirectory()
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)

        let firstCommand = firstDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'zdotdir-first'\n".write(to: firstCommand, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: firstCommand.path)

        let secondCommand = secondDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'zdotdir-second'\n".write(to: secondCommand, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secondCommand.path)

        let counterFile = root.appendingPathComponent("shell-invocations.txt")
        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              count=0
              if [ -f "\(counterFile.path)" ]; then
                count=$(cat "\(counterFile.path)")
              fi
              count=$((count + 1))
              printf '%s' "$count" > "\(counterFile.path)"
              case "$ZDOTDIR" in
                "\(root.path)/zdotdir-a") printf '\n__SPACES_PATH__%s' "\(firstDirectory.path):/usr/bin:/bin" ;;
                "\(root.path)/zdotdir-b") printf '\n__SPACES_PATH__%s' "\(secondDirectory.path):/usr/bin:/bin" ;;
                *) exit 9 ;;
              esac
              exit 0
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let originalHome = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let originalZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"]
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        setenv("HOME", root.path, 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
            setenv("HOME", originalHome, 1)
            if let originalZdotdir { setenv("ZDOTDIR", originalZdotdir, 1) } else { unsetenv("ZDOTDIR") }
        }

        setenv("ZDOTDIR", "\(root.path)/zdotdir-a", 1)
        XCTAssertEqual(try Shell.runAndCapture(["mockcmd"]), "zdotdir-first")

        setenv("ZDOTDIR", "\(root.path)/zdotdir-b", 1)
        XCTAssertEqual(try Shell.runAndCapture(["mockcmd"]), "zdotdir-second")

        let invocationCount = try String(contentsOf: counterFile, encoding: .utf8)
        XCTAssertEqual(invocationCount, "2")
    }

    func testRunAndCaptureDropsUnsetShellConfigEnvironmentFromLoginProbe() throws {
        let root = try makeTempDirectory()
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)

        let firstCommand = firstDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'with-zdotdir'\n".write(to: firstCommand, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: firstCommand.path)

        let secondCommand = secondDirectory.appendingPathComponent("mockcmd")
        try "#!/bin/sh\nprintf 'without-zdotdir'\n".write(to: secondCommand, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secondCommand.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        let shellScript = """
            #!/bin/sh
            if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
              case "${ZDOTDIR-__UNSET__}" in
                "\(root.path)/zdotdir") printf '\n__SPACES_PATH__%s' "\(firstDirectory.path):/usr/bin:/bin" ;;
                "__UNSET__") printf '\n__SPACES_PATH__%s' "\(secondDirectory.path):/usr/bin:/bin" ;;
                *) exit 23 ;;
              esac
              exit 0
            fi
            exec /bin/sh "$@"
            """
        try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let originalHome = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let originalZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"]
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        setenv("HOME", root.path, 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
            setenv("HOME", originalHome, 1)
            if let originalZdotdir { setenv("ZDOTDIR", originalZdotdir, 1) } else { unsetenv("ZDOTDIR") }
        }

        setenv("ZDOTDIR", "\(root.path)/zdotdir", 1)
        XCTAssertEqual(try Shell.runAndCapture(["mockcmd"]), "with-zdotdir")

        unsetenv("ZDOTDIR")
        XCTAssertEqual(try Shell.runAndCapture(["mockcmd"]), "without-zdotdir")
    }

    // Tests run and capture throws with stderr on failure by arranging representative inputs and asserting the expected result.
    func testRunAndCaptureThrowsWithStderrOnFailure() throws {
        XCTAssertThrowsError(try Shell.runAndCapture(["sh", "-lc", "echo boom >&2; exit 9"])) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "spaces.shell")
            XCTAssertEqual(nsError.code, 9)
            XCTAssertTrue((nsError.localizedDescription).contains("boom"))
        }
    }

    // Tests run throws for empty command by arranging representative inputs and asserting the expected result.
    func testRunThrowsForEmptyCommand() {
        XCTAssertThrowsError(try Shell.run([])) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "spaces.shell")
        }
    }

    // Tests runAndCapture throws for empty command by arranging representative inputs and asserting the expected result.
    func testRunAndCaptureThrowsForEmptyCommand() {
        XCTAssertThrowsError(try Shell.runAndCapture([])) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "spaces.shell")
        }
    }

    // Tests AppleScript.run fails fast in XCTest when the test has not installed an osascript mock.
    func testAppleScriptRunRequiresMockDuringTests() {
        XCTAssertThrowsError(try AppleScript.run("return \"hello\"")) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "spaces.applescript")
            XCTAssertTrue(nsError.localizedDescription.contains("Unmocked AppleScript call during tests"))
        }
    }

    // Tests run(lines:) joins lines with newlines and executes the resulting script.
    func testAppleScriptRunJoinsLines() throws {
        try withMockCommands(["osascript": "#!/bin/bash\necho 'hello'\n"]) {
            let result = try AppleScript.run(lines: ["return \"hello\""])
            XCTAssertEqual(result, "hello")
        }
    }

    func testAppleScriptRunUsesMockedCommandEvenWithLoginShellPathProbe() throws {
        try withMockCommands(["osascript": "#!/bin/sh\nprintf 'mocked-osascript'\n"]) {
            let result = try AppleScript.run("return 1")
            XCTAssertEqual(result, "mocked-osascript")
        }
    }
}

private func currentUserAccountInfo() -> (shellPath: String, homePath: String)? {
    let uid = getuid()
    let rawSize = sysconf(_SC_GETPW_R_SIZE_MAX)
    let bufferSize = rawSize > 0 ? Int(rawSize) : 16_384
    var buffer = [CChar](repeating: 0, count: bufferSize)
    var record = passwd()
    var result: UnsafeMutablePointer<passwd>?
    let status = getpwuid_r(uid, &record, &buffer, buffer.count, &result)
    guard status == 0, let entry = result else { return nil }
    return (shellPath: String(cString: entry.pointee.pw_shell), homePath: String(cString: entry.pointee.pw_dir))
}

private func processListContains(argumentFragment: String) -> Bool {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", argumentFragment]
    process.standardOutput = output
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}
